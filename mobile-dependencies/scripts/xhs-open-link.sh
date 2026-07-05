#!/usr/bin/env zsh
# xhs-open-link.sh <url>
#
# Open a Xiaohongshu link (xhslink.com short link, full xhs:// scheme,
# or https://www.xiaohongshu.com/...) on the BlueStacks emulator and
# hand off to the xhs app.
#
# Hard-learned context (2026-05-06):
#   BlueStacks Air ships with `bst.enable_adb_access="0"` in
#   /Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf.
#   While ADB access is OFF, only `dumpsys` / `getprop` / `exec-out screencap`
#   work — `am start`, `input`, `pm`, even `echo` all return "error: closed".
#   The fix is to flip both flags to "1" and restart BlueStacks. With ADB
#   enabled, `am start -a VIEW -d <url>` works normally.
#
# Flow:
#   1. Health check ADB shell. If unhealthy, hint at the BlueStacks config fix.
#   2. Fire `am start -a VIEW -d <url>`. This is what tapping a link in any
#      normal app does — Chrome opens, follows redirects, and (if the chain
#      ends in xhs://) hands off to the xhs app.
#   3. Poll foreground for xhs.
#   4. If Chrome lands on xhs's "must open in app" gateway page instead of
#      auto-handing off, find and tap the "打开 APP / Open in App" button.
#   5. Poll again, then either succeed or report what we landed on.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
URL="${1:-}"
TIMEOUT_INITIAL="${XHS_OPEN_TIMEOUT_INITIAL:-8}"
TIMEOUT_AFTER_TAP="${XHS_OPEN_TIMEOUT_AFTER_TAP:-10}"

if [ -z "$URL" ]; then
  echo "Usage: $0 <url>" >&2
  echo "  Supports xhslink.com short links, https://www.xiaohongshu.com/...," >&2
  echo "  and direct xhs:// scheme URLs." >&2
  exit 1
fi

log() { echo "[xhs-open] $*" >&2; }

# Resolve UDID via the standard mobile workspace helper.
if [ -x "$SCRIPT_DIR/device-connect.sh" ]; then
  UDID="$("$SCRIPT_DIR/device-connect.sh")"
else
  UDID="${ANDROID_SERIAL:-127.0.0.1:5555}"
  "$ADB" connect "$UDID" >/dev/null 2>&1 || true
fi

if [ -z "$UDID" ]; then
  log "Could not resolve a connected device. Run device-connect.sh first."
  exit 2
fi

# Sanity check: shell must be able to spawn processes.
probe="$("$ADB" -s "$UDID" shell echo openclaw_probe 2>&1)"
if [ "$probe" != "openclaw_probe" ]; then
  log "ADB shell unhealthy. Got: $probe"
  log "Most common cause on BlueStacks Air: bst.enable_adb_access=\"0\"."
  log "Fix: edit /Users/Shared/Library/Application\\ Support/BlueStacks/bluestacks.conf"
  log "     set bst.enable_adb_access and bst.enable_adb_remote_access to \"1\""
  log "     then quit + relaunch BlueStacks."
  exit 3
fi

current_focus() {
  "$ADB" -s "$UDID" shell dumpsys window 2>/dev/null \
    | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r'
}

xhs_foreground() {
  current_focus | grep -q 'com.xingin.xhs'
}

# Wait up to N seconds for xhs to take foreground. Returns 0 on success.
# After foreground, also wait for the activity to settle (no Activity
# changes for SETTLE seconds) so callers don't fire input into a
# mid-transition screen — that's how we ended up on a random profile on
# 2026-05-06: carousel swipes hit while xhs was still animating in.
SETTLE_SECONDS="${XHS_OPEN_SETTLE_SECONDS:-2}"
wait_for_xhs() {
  local secs="$1"
  for i in $(seq 1 "$secs"); do
    sleep 1
    if xhs_foreground; then
      log "XHS is foreground after ${i}s; waiting ${SETTLE_SECONDS}s for animation"
      sleep "$SETTLE_SECONDS"
      log "✅ Settled on:"
      current_focus
      return 0
    fi
  done
  return 1
}

# Try to find xhs's "Open in App" button on the gateway page and tap it.
# Returns 0 if a button was tapped.
try_tap_open_in_app() {
  "$ADB" -s "$UDID" shell uiautomator dump /sdcard/_xhs_open.xml >/dev/null 2>&1 || return 1
  "$ADB" -s "$UDID" pull /sdcard/_xhs_open.xml /tmp/_xhs_open.xml >/dev/null 2>&1 || return 1

  # Extract bounds for any node whose text contains "打开" or "Open in App".
  local coord
  coord="$(python3 - <<'PYEOF'
import re, sys
try:
    with open('/tmp/_xhs_open.xml') as f:
        xml = f.read()
except FileNotFoundError:
    sys.exit(1)

candidates = []
for node in re.findall(r'<node[^>]*?/?>', xml):
    text = re.search(r'text="([^"]*)"', node)
    desc = re.search(r'content-desc="([^"]*)"', node)
    label = (text.group(1) if text else '') + ' ' + (desc.group(1) if desc else '')
    label = label.strip()
    if not label:
        continue
    # Match common variants of the gateway button.
    if any(kw in label for kw in ('Open in App', '打开 APP', '打开APP', '在小红书 APP 内打开', '在 APP 中打开', '小红书 App')):
        bounds = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
        if not bounds:
            continue
        x1, y1, x2, y2 = map(int, bounds.groups())
        # Prefer larger primary buttons.
        area = (x2 - x1) * (y2 - y1)
        candidates.append((area, (x1+x2)//2, (y1+y2)//2, label))

if not candidates:
    sys.exit(2)
candidates.sort(reverse=True)  # biggest first
_, cx, cy, label = candidates[0]
print(f'{cx} {cy} {label}')
PYEOF
)"
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$coord" ]; then
    return 1
  fi
  local cx cy label
  cx="$(echo "$coord" | awk '{print $1}')"
  cy="$(echo "$coord" | awk '{print $2}')"
  label="$(echo "$coord" | cut -d' ' -f3-)"
  log "Found gateway button '${label}' at ($cx, $cy). Tapping."
  "$ADB" -s "$UDID" shell input tap "$cx" "$cy" >/dev/null 2>&1
  return 0
}

before_focus="$(current_focus)"
log "Pre-launch focus: $before_focus"
log "Opening: $URL"

# Fire the VIEW intent.
out="$("$ADB" -s "$UDID" shell am start -a android.intent.action.VIEW -d "$URL" 2>&1)"
echo "$out" | head -3 >&2

if echo "$out" | grep -qi 'error\|unable to resolve'; then
  log "am start reported an error. Bailing."
  exit 4
fi

# Layer 1: maybe the redirect chain auto-hands off to xhs.
log "Waiting up to ${TIMEOUT_INITIAL}s for redirect handoff..."
if wait_for_xhs "$TIMEOUT_INITIAL"; then
  exit 0
fi

# Layer 2: Chrome likely landed on xhs's "Open in App" gateway. Try to tap it.
log "Browser still in front. Looking for 'Open in App' gateway button..."
if try_tap_open_in_app; then
  log "Tapped gateway button. Waiting up to ${TIMEOUT_AFTER_TAP}s for xhs..."
  if wait_for_xhs "$TIMEOUT_AFTER_TAP"; then
    exit 0
  fi
fi

# Didn't reach xhs. Save a screenshot for the caller to inspect.
SHOT="/tmp/xhs_open_failed_$(date +%s).png"
"$ADB" -s "$UDID" exec-out screencap -p > "$SHOT" 2>/dev/null
log "Did not reach xhs. Final focus:"
current_focus >&2
log "Screenshot: $SHOT"
exit 5

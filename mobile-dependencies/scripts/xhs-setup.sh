#!/usr/bin/env zsh
# xhs-setup.sh
# 一键自检 + onboarding for xhs-research-conductor
# 用法: ./xhs-setup.sh
#
# 检查 (按依赖顺序):
#   1. ADB 装了
#   2. tesseract + chi_sim 装了
#   3. Android 模拟器 / 真机 connected
#   4. XHS app 安装在设备
#   5. XHS app 是登录态 (不是 splash / login screen)
#
# 任一失败 → 给清晰修复指导, exit 1
# 全过 → 输出 device serial 给用户确认

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  ✅ $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  ❌ $1"; echo "     → $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo "  ℹ️  $1"; }

echo "=================================================="
echo "  xhs-research-conductor — Setup Check"
echo "=================================================="
echo

# --- 1. ADB ---
echo "[1/5] ADB (Android Debug Bridge)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB:-$SDK/platform-tools/adb}"
if [ -x "$ADB" ]; then
  pass "ADB found at $ADB"
else
  ADB="$(command -v adb || true)"
  if [ -n "$ADB" ]; then
    pass "ADB found at $ADB (system PATH)"
  else
    fail "ADB not found" "Install: brew install --cask android-platform-tools (Mac) / apt install adb (Linux)"
  fi
fi
echo

# --- 2. tesseract ---
echo "[2/5] tesseract OCR + chi_sim"
TESS="$(command -v tesseract || true)"
if [ -n "$TESS" ]; then
  pass "tesseract found at $TESS"
  LANGS="$(tesseract --list-langs 2>&1 | tail -n +2)"
  if echo "$LANGS" | grep -q "^chi_sim$"; then
    pass "chi_sim language pack installed"
  else
    fail "chi_sim language pack missing" "Install: brew install tesseract-lang (Mac) / apt install tesseract-ocr-chi-sim (Linux)"
  fi
else
  fail "tesseract not found" "Install: brew install tesseract tesseract-lang (Mac) / apt install tesseract-ocr tesseract-ocr-chi-sim (Linux)"
fi
echo

# --- 3. 模拟器 / 真机 (v0.14: 加 self-heal) ---
echo "[3/5] Android emulator / device"
try_detect() {
  if [ -x "$SCRIPT_DIR/detect-emulator.sh" ]; then
    UDID="$("$SCRIPT_DIR/detect-emulator.sh" 2>&1)"
    return $?
  fi
  return 1
}

if try_detect; then
  pass "device connected: $UDID"
  export ANDROID_SERIAL="$UDID"
else
  # v0.14 self-heal: 5/20 真踩 BlueStacks ADB 离线导致 setup 卡 20+ min
  info "device not found, attempting self-heal..."

  # Step A: restart ADB server (clears stale state from earlier session)
  "$ADB" kill-server >/dev/null 2>&1 || true
  sleep 1
  "$ADB" start-server >/dev/null 2>&1 || true

  # Step B: if BlueStacks not running, try to launch it
  if ! pgrep -f "BlueStacks.app/Contents/MacOS/BlueStacks" >/dev/null 2>&1; then
    info "BlueStacks process not found, launching..."
    open -a BlueStacks 2>/dev/null || open -a "BlueStacks Air" 2>/dev/null || true
    # Give it 20s to come up
    for _ in $(seq 1 20); do
      sleep 1
      "$ADB" connect 127.0.0.1:5555 >/dev/null 2>&1 || true
      if try_detect; then
        pass "device connected after BlueStacks launch: $UDID"
        export ANDROID_SERIAL="$UDID"
        break
      fi
    done
  else
    info "BlueStacks running but ADB unreachable, retrying connect..."
    # ADB connect can hang on stale tcp connection; force reconnect
    for _ in 1 2 3; do
      "$ADB" connect 127.0.0.1:5555 >/dev/null 2>&1 || true
      sleep 2
      if try_detect; then
        pass "device connected after ADB reconnect: $UDID"
        export ANDROID_SERIAL="$UDID"
        break
      fi
    done
  fi

  # Still not found? Give clear remediation
  if [ -z "${ANDROID_SERIAL:-}" ]; then
    fail "no device after self-heal" "BlueStacks 可能卡死。建议:
       1. 右键 BlueStacks 窗口 → Quit
       2. 等 5 秒, 重新打开 BlueStacks
       3. 等 XHS feed 加载 (~30s)
       4. 重跑 xhs-setup.sh"
  fi
fi
echo

# --- 4. XHS app 安装 ---
echo "[4/5] XHS app (com.xingin.xhs) installed"
if [ -n "${ANDROID_SERIAL:-}" ]; then
  if "$ADB" -s "$ANDROID_SERIAL" shell pm list packages 2>/dev/null | grep -q "com.xingin.xhs"; then
    VER="$("$ADB" -s "$ANDROID_SERIAL" shell dumpsys package com.xingin.xhs 2>/dev/null | awk -F= '/versionName=/{print $2; exit}' | tr -d '\r')"
    pass "XHS app installed (version $VER)"
  else
    fail "XHS app not installed on $ANDROID_SERIAL" "
       Mac BlueStacks: open BlueStacks → Play Store → 搜 \"小红书\" → install
       Or sideload APK: adb -s $ANDROID_SERIAL install path/to/xhs.apk"
  fi
else
  info "Skipping — no device connected"
fi
echo

# --- 5. XHS 登录态 (v0.14: 加 launch self-heal) ---
echo "[5/5] XHS app login state"
launch_xhs() {
  # Try 3 methods in order, return 0 on first success
  # Method 1: monkey (preferred when working)
  "$ADB" -s "$ANDROID_SERIAL" shell monkey -p com.xingin.xhs -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 3
  FOCUS="$("$ADB" -s "$ANDROID_SERIAL" shell dumpsys window 2>/dev/null | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')"
  case "$FOCUS" in *xingin.xhs*) return 0 ;; esac

  # Method 2: explicit am start with resolved activity name (5/20 真踩: monkey 偶发 closed)
  ACT="$("$ADB" -s "$ANDROID_SERIAL" shell cmd package resolve-activity --brief com.xingin.xhs 2>/dev/null | tail -1 | tr -d '\r')"
  if [ -n "$ACT" ]; then
    "$ADB" -s "$ANDROID_SERIAL" shell am start -W -n "$ACT" >/dev/null 2>&1
    sleep 3
    FOCUS="$("$ADB" -s "$ANDROID_SERIAL" shell dumpsys window 2>/dev/null | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')"
    case "$FOCUS" in *xingin.xhs*) return 0 ;; esac
  fi

  # Method 3: VIEW intent on deep link (rarely needed but doesn't hurt)
  "$ADB" -s "$ANDROID_SERIAL" shell am start -W -a android.intent.action.VIEW -d 'xhsdiscover://feed' com.xingin.xhs >/dev/null 2>&1
  sleep 3
  FOCUS="$("$ADB" -s "$ANDROID_SERIAL" shell dumpsys window 2>/dev/null | awk '/mCurrentFocus=/{print; exit}' | tr -d '\r')"
  case "$FOCUS" in *xingin.xhs*) return 0 ;; esac

  return 1
}

if [ -n "${ANDROID_SERIAL:-}" ] && "$ADB" -s "$ANDROID_SERIAL" shell pm list packages 2>/dev/null | grep -q "com.xingin.xhs"; then
  if launch_xhs; then
    # check if landing on login/splash
    DUMP=/tmp/_xhs_setup_check.xml
    "$ADB" -s "$ANDROID_SERIAL" shell uiautomator dump /sdcard/_xhs_setup.xml >/dev/null 2>&1
    "$ADB" -s "$ANDROID_SERIAL" pull /sdcard/_xhs_setup.xml "$DUMP" >/dev/null 2>&1
    if grep -qi "login\|登录\|sign in\|手机号" "$DUMP" 2>/dev/null; then
      fail "XHS app on login screen" "Open BlueStacks → XHS app → 用手机号登录 + 验证码 (推荐) 或微信 / 微博登录"
    else
      pass "XHS app launches into feed (logged in)"
    fi
    rm -f "$DUMP"
  else
    fail "XHS app didn't launch after 3 methods" "BlueStacks 可能卡死。试: Quit BlueStacks → 重开 → 等 30s → 重跑 setup"
  fi
else
  info "Skipping — XHS app not installed"
fi
echo

# --- summary ---
echo "=================================================="
echo "  Result: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "=================================================="

if [ $FAIL_COUNT -eq 0 ]; then
  echo ""
  echo "  🎉 Setup complete! conductor ready to use."
  echo ""
  echo "  Next: in Claude Code / OpenClaw, say:"
  echo "    \"调研一下 X\"  or  \"看看小红书 X 怎么样\""
  echo ""
  echo "  device: $ANDROID_SERIAL"
  exit 0
else
  echo ""
  echo "  ⚠️  Fix the above and re-run xhs-setup.sh"
  echo ""
  exit 1
fi

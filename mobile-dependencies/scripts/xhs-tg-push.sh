#!/usr/bin/env zsh
# xhs-tg-push.sh — optional Telegram push channel for real-time feedback
#
# usage:
#   ./xhs-tg-push.sh "✅ bundle done: <title> (<N>p)"
#   ./xhs-tg-push.sh "🚨 STUCK" "$(cat STUCK.md)"
#
# Required env vars (skill skips silently if missing):
#   TELEGRAM_BOT_TOKEN — bot token from @BotFather
#   XHS_TG_CHAT_ID     — your chat_id (from @userinfobot)
#
# Optional:
#   XHS_TG_ENV_FILE    — override env file path (default: ~/.claude/channels/telegram/.env)
#   XHS_TG_PREFIX      — message prefix (default: [xhs-research])
#
# This script is OPTIONAL — if env vars not set, the conductor still works,
# you just won't get TG push notifications. STUCK.md and _retro.md still land on disk.

set -u  # NOTE: no -e, push failure must not crash the caller

ENV_FILE="${XHS_TG_ENV_FILE:-$HOME/.claude/channels/telegram/.env}"
TOPIC_PREFIX="${XHS_TG_PREFIX:-[xhs-research]}"

[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null
CHAT_ID="${XHS_TG_CHAT_ID:-}"

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || { echo "tg-push: TELEGRAM_BOT_TOKEN not set, skip" >&2; exit 0; }
[ -n "$CHAT_ID" ] || { echo "tg-push: XHS_TG_CHAT_ID not set, skip" >&2; exit 0; }

TITLE="${1:-(no title)}"
BODY="${2:-}"

if [ -n "$BODY" ]; then
  MSG="$TOPIC_PREFIX $TITLE

$BODY"
else
  MSG="$TOPIC_PREFIX $TITLE"
fi

# Telegram has 4096 char limit
MSG_TRIMMED=$(echo "$MSG" | head -c 3900)

# fire and forget, 5s timeout, no body parsing
curl -s --max-time 5 \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${MSG_TRIMMED}" \
  > /dev/null 2>&1 || true

exit 0

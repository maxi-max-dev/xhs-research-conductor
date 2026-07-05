#!/usr/bin/env zsh
# device-connect.sh — backward-compatible wrapper
# 旧 script (xhs-capture-*) 调用 device-connect.sh 拿 ADB UDID. 现在 delegate 到 detect-emulator.sh
# 让 multi-emulator detection 跨整个 xhs pipeline 生效.
# 2026-05-16: rewritten 为 wrapper, 真正 detection 走 detect-emulator.sh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
exec "$SCRIPT_DIR/detect-emulator.sh"

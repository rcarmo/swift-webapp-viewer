#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="WebAppViewer"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$MODE" in
  run)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    make -C "$ROOT_DIR" run
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    make -C "$ROOT_DIR" CONFIG=debug
    open -n "$ROOT_DIR/.build/$APP_NAME.app"
    for _ in {1..50}; do
      PID="$(pgrep -n -x "$APP_NAME" || true)"
      if [[ -n "$PID" ]]; then
        exec lldb -p "$PID"
      fi
      sleep 0.1
    done
    echo "Failed to find running $APP_NAME after launching the app bundle" >&2
    exit 1
    ;;
  --logs|logs)
    make -C "$ROOT_DIR" run
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    make -C "$ROOT_DIR" run
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.example.WebAppViewer\""
    ;;
  --verify|verify)
    make -C "$ROOT_DIR" verify
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

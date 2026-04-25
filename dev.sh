#!/bin/bash
set -e

APP="MacPEQ"

case "${1:-rebuild}" in
  rebuild)
    ./build.sh
    ;;
  
  run|launch)
    echo "Launching $APP..."
    open "$APP.app"
    ;;
  
  relaunch)
    echo "Kill and relaunch (no rebuild)..."
    pkill -f "$APP" || true
    open "$APP.app"
    ;;
  
  kill|stop)
    echo "Stopping $APP..."
    pkill -f "$APP" || true
    ;;
  
  clean)
    echo "Clean build..."
    swift package clean
    rm -rf .build
    rm -rf "$APP.app"
    ;;
  
  logs)
    if [ -f "/tmp/macpeq.log" ]; then
      tail -f /tmp/macpeq.log
    else
      echo "No log file found at /tmp/macpeq.log"
      exit 1
    fi
    ;;
  
  *)
    echo "Usage: $0 [rebuild|run|relaunch|kill|clean|logs]"
    echo ""
    echo "  rebuild    Build the app"
    echo "  run        Launch the app"
    echo "  relaunch   Kill and relaunch existing build"
    echo "  kill       Stop the app"
    echo "  clean      Deep clean all build artifacts"
    echo "  logs       Stream app logs from /tmp/macpeq.log"
    echo ""
    echo "Quick commands:"
    echo "  ./dev.sh rebuild && ./dev.sh run"
    echo "  ./dev.sh kill && ./dev.sh rebuild && ./dev.sh run"
    exit 1
    ;;
esac
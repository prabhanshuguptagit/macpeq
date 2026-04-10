#!/bin/bash
set -e

echo "Building MacPEQ..."
swift build

echo ""
echo "Build complete. To run:"
echo "  swift run MacPEQ"
echo ""
echo "Note: First run will prompt for 'System Audio Recording' permission."
echo "If no prompt appears, the app may need to be run from Terminal.app (not iTerm/VSCode)."

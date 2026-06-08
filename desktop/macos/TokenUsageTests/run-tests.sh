#!/bin/bash
#
# Standalone tests for the Foundation-only token parsing + aggregation logic.
# Compiles the real client sources (no Xcode test target) plus TestMain.swift
# with swiftc and runs the assertions.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/../share-my-status-client"
OUT="/tmp/tokentests"

echo "Compiling token tests..."
swiftc -O \
  "$CLIENT_DIR/Models/Domain/TokenModels.swift" \
  "$CLIENT_DIR/Models/API/StateModels.swift" \
  "$CLIENT_DIR/Models/API/APIModels.swift" \
  "$CLIENT_DIR/Services/TokenParsers/TokenLogParser.swift" \
  "$CLIENT_DIR/Services/TokenParsers/ClaudeCodeParser.swift" \
  "$CLIENT_DIR/Services/TokenParsers/CodexParser.swift" \
  "$CLIENT_DIR/Services/TokenParsers/GeminiParser.swift" \
  "$CLIENT_DIR/Services/TokenParsers/CursorParser.swift" \
  "$SCRIPT_DIR/main.swift" \
  -lsqlite3 \
  -o "$OUT"

echo "Running..."
"$OUT"

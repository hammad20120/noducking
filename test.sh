#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos14.4 Sources/ProtectionSession.swift Sources/AudioProcesses.swift Tests/main.swift -o build/noducking-tests -framework AppKit -framework CoreAudio
build/noducking-tests

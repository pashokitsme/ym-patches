#!/bin/bash
# Build universal TelemostTweaks.dylib against Homebrew Qt headers.
# Symbols resolve at runtime against Telemost's bundled Qt 6.8 (-undefined dynamic_lookup).
set -euo pipefail
cd "$(dirname "$0")"
QT=/opt/homebrew/lib
mkdir -p build
xxd -i tweaks.js > build/tweaks_js.h
clang++ -std=c++17 -fobjc-arc -dynamiclib -O2 -DQT_NO_VERSION_TAGGING \
	-arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
	-F "$QT" -I "$QT/QtCore.framework/Headers" -I "$QT/QtWebEngineCore.framework/Headers" \
	-iframework "$QT" -Ibuild \
	-framework Cocoa -undefined dynamic_lookup \
	-install_name @executable_path/../Frameworks/TelemostTweaks.dylib \
	-o build/TelemostTweaks.dylib tweaks.mm
echo "built build/TelemostTweaks.dylib"

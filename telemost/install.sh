#!/bin/bash
# Install TelemostTweaks to ~/Library/Application Support/TelemostTweaks, patch Telemost now,
# and register a LaunchAgent that re-patches whenever an update replaces the binary.
#   install.sh             install / update
#   install.sh --uninstall remove the agent and restore the original Telemost
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/TelemostTweaks"
LABEL=local.telemost-tweaks
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP=/Applications/Yandex.Telemost.app

if [ "${1:-}" = "--uninstall" ]; then
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	"$DEST/patch.sh" --restore
	exit 0
fi

"$SRC/build.sh"
"$SRC/make-identity.sh" # stable signature, so privacy grants survive re-patching
mkdir -p "$DEST/build"
cp -f "$SRC"/{tweaks.js,tweaks.mm,build.sh,patch.sh,insert_dylib.py,install.sh,make-identity.sh} "$DEST/"
cp -f "$SRC/build/tweaks_js.h" "$DEST/build/"
# new inode for the Mach-O, see patch.sh
cp -f "$SRC/build/TelemostTweaks.dylib" "$DEST/build/TelemostTweaks.dylib.tt-tmp"
mv -f "$DEST/build/TelemostTweaks.dylib.tt-tmp" "$DEST/build/TelemostTweaks.dylib"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>$DEST/patch.sh</string></array>
	<key>WatchPaths</key>
	<array>
		<string>$APP/Contents/MacOS/Yandex.Telemost</string>
		<string>$APP/Contents/Info.plist</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/TelemostTweaks.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/TelemostTweaks.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $DEST, agent $LABEL"

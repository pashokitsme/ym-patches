#!/bin/bash
# Patch Yandex.Telemost with TelemostTweaks.dylib.
#   patch.sh            patch if not patched yet (safe to run repeatedly)
#   patch.sh --force    re-copy the dylib and re-sign even if already patched
#   patch.sh --restore  put back the original binary and signature for the installed version
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${TELEMOST_APP:-/Applications/Yandex.Telemost.app}"
BIN="$APP/Contents/MacOS/Yandex.Telemost"
DYLIB_NAME=TelemostTweaks.dylib
INSTALL_NAME="@executable_path/../Frameworks/$DYLIB_NAME"
STATE="$HOME/Library/Application Support/TelemostTweaks"
LOG="$HOME/Library/Logs/TelemostTweaks.log"
# Local self-signed code signing identity (see README). With it the designated
# requirement is "identifier + this certificate", stable across re-signs, so macOS
# privacy grants (screen recording, camera, mic) survive re-patching and updates.
# Without it we fall back to ad-hoc, whose requirement is the binary's cdhash and
# changes on every re-sign, silently invalidating those grants.
SIGN_ID="${TT_SIGN_IDENTITY:-TelemostTweaks Local Signing}"

# one patcher at a time: the LaunchAgent and a manual run can overlap
if [ -z "${TT_LOCKED:-}" ]; then
	mkdir -p "$STATE"
	TT_LOCKED=1 exec /usr/bin/lockf -k "$STATE/.lock" /bin/bash "$0" "$@"
fi

# under launchd stdout already goes to $LOG
log() {
	local line="$(date '+%F %T') patch: $*"
	if [ -t 1 ]; then echo "$line" | tee -a "$LOG"; else echo "$line"; fi
}
notify() { osascript -e "display notification \"$1\" with title \"TelemostTweaks\"" >/dev/null 2>&1 || true; }

[ -f "$BIN" ] || { log "no $BIN"; exit 0; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
BACKUP="$STATE/backup/$VERSION"

# grep -q would close the pipe early; with pipefail otool's SIGPIPE then reads as "not patched"
is_patched() { otool -l "$BIN" | grep -F "$INSTALL_NAME" >/dev/null; }
# the bundle copy differs from build/ after a rebuild of the tweaks
sha() { [ -f "$1" ] && shasum -a 256 <"$1" | cut -d' ' -f1; }
dylib_current() { [ "$(sha "$HERE/build/$DYLIB_NAME")" = "$(sha "$APP/Contents/Frameworks/$DYLIB_NAME")" ]; }
have_identity() { security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; }
signed_as_wanted() { ! have_identity || codesign -dvv "$APP" 2>&1 | grep -F "Authority=$SIGN_ID" >/dev/null; }

if [ "${1:-}" = "--restore" ]; then
	[ -d "$BACKUP" ] || { log "no backup for $VERSION"; exit 1; }
	cp -p "$BACKUP/Yandex.Telemost" "$BIN.tt-tmp" && mv -f "$BIN.tt-tmp" "$BIN"
	rm -rf "$APP/Contents/_CodeSignature" && cp -Rp "$BACKUP/_CodeSignature" "$APP/Contents/"
	rm -f "$APP/Contents/Frameworks/$DYLIB_NAME"
	codesign --verify --deep --strict "$APP" && log "restored original $VERSION (Yandex signature valid)"
	exit 0
fi

if is_patched && dylib_current && signed_as_wanted && [ "${1:-}" != "--force" ]; then
	exit 0
fi

# the updater may still be writing the new bundle
for _ in $(seq 30); do
	codesign --verify "$APP" >/dev/null 2>&1 && break
	is_patched && break
	sleep 2
done

log "patching $APP ($VERSION)"
if ! is_patched && [ ! -d "$BACKUP" ]; then
	mkdir -p "$BACKUP"
	cp -p "$BIN" "$BACKUP/"
	cp -Rp "$APP/Contents/_CodeSignature" "$BACKUP/"
	log "backup -> $BACKUP"
fi

DYLIB="$HERE/build/$DYLIB_NAME"
[ -f "$DYLIB" ] || "$HERE/build.sh"
# Never overwrite a signed Mach-O in place: the kernel caches its code signature per
# vnode, and the next launch is killed with "Code Signature Invalid" while dyld maps it.
# Copy to a new file and rename it over the old one so it gets a fresh inode.
cp -f "$DYLIB" "$APP/Contents/Frameworks/$DYLIB_NAME.tt-tmp" # already ad-hoc signed by build.sh
mv -f "$APP/Contents/Frameworks/$DYLIB_NAME.tt-tmp" "$APP/Contents/Frameworks/$DYLIB_NAME"

# Patch a copy and rename it into place: a running Telemost keeps its old inode.
cp -p "$BIN" "$BIN.tt-tmp"
python3 -I "$HERE/insert_dylib.py" "$BIN.tt-tmp" "$INSTALL_NAME" | while read -r l; do log "$l"; done
mv -f "$BIN.tt-tmp" "$BIN"

# Modified binary => Yandex signature is invalid and arm64 refuses to run it unsigned.
# Re-sign WITHOUT hardened runtime: with it, library validation would reject the
# Yandex-signed Qt frameworks next to a main executable signed by anyone else.
SIGN=-
have_identity && SIGN="$SIGN_ID"
ENT="$(mktemp -t tt-ent).plist"
codesign -d --entitlements :- "$BACKUP/Yandex.Telemost" >"$ENT" 2>/dev/null || true
if [ -s "$ENT" ]; then
	codesign --force --sign "$SIGN" --entitlements "$ENT" "$APP"
else
	codesign --force --sign "$SIGN" "$APP"
fi
rm -f "$ENT"
codesign --verify --strict "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
if [ "$SIGN" = - ]; then
	log "done: $VERSION patched and ad-hoc signed (no '$SIGN_ID' identity: privacy grants reset on every re-sign)"
else
	log "done: $VERSION patched and signed by '$SIGN_ID'"
fi

if pgrep -xq "Yandex.Telemost"; then
	notify "Телемост $VERSION пропатчен. Изменения применятся после перезапуска."
fi

#!/bin/sh
# Builds ReFile.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
APP=build/ReFile.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ReFile" Sources/*.swift
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
# ad-hoc, known by its identifier rather than by this build's hash
codesign --force -s - -r='designated => identifier "com.artursavytskyi.refile"' "$APP"
if [ "$1" = "--install" ]; then
	DEST=/Applications/ReSpace
	[ -d "$DEST" ] || DEST=/Applications
	osascript -e 'quit app id "com.artursavytskyi.refile"' 2>/dev/null || true
	sleep 1
	rm -rf "$DEST/ReFile.app"
	cp -R "$APP" "$DEST/"
fi

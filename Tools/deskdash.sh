#!/bin/bash
# Build, test and run DeskDash.
# Build files go to ~/Library/Developer/DeskDash, never inside the project folder.
#
#   Tools/deskdash.sh build     build DeskDash.app
#   Tools/deskdash.sh run       build, then open it (quits a running copy first)
#   Tools/deskdash.sh test      run the tests
#   Tools/deskdash.sh install   build an optimized copy into /Applications and open it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HOME/Library/Developer/DeskDash"
# Some installs point the Mac at the command line tools instead of Xcode. Use Xcode when it's there.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* \
      && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Builds the program and wraps it into an app: make_app <debug|release> <where the .app goes>
make_app() {
    local config="$1" app="$2"
    swift build --package-path "$ROOT" --scratch-path "$OUT/build" -c "$config"
    local bin
    bin="$(swift build --package-path "$ROOT" --scratch-path "$OUT/build" -c "$config" --show-bin-path)"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin/DeskDash" "$app/Contents/MacOS/DeskDash"
    cp "$ROOT/Resources/Info.plist" "$app/Contents/Info.plist"
    # Sign with Troy's Apple Development certificate when it's there (needed later for saving API keys in the
    # Keychain); otherwise a local-only signature so macOS will open it.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
        codesign --force --sign "Apple Development" "$app"
    else
        codesign --force --sign - "$app"
    fi
    echo "Built $app"
}

case "${1:-build}" in
    build)
        make_app debug "$OUT/DeskDash.app"
        ;;
    run)
        make_app debug "$OUT/DeskDash.app"
        pkill -x DeskDash 2>/dev/null || true
        open "$OUT/DeskDash.app"
        ;;
    test)
        swift test --package-path "$ROOT" --scratch-path "$OUT/build"
        ;;
    install)
        make_app release "$OUT/Release/DeskDash.app"
        pkill -x DeskDash 2>/dev/null || true
        rm -rf /Applications/DeskDash.app
        cp -R "$OUT/Release/DeskDash.app" /Applications/DeskDash.app
        open /Applications/DeskDash.app
        ;;
    *)
        echo "Usage: Tools/deskdash.sh build|run|test|install" >&2
        exit 1
        ;;
esac

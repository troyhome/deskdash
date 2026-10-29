#!/bin/bash
# Build, test and run DeskDash.
# Build files go to ~/Library/Developer/DeskDash, never inside the project folder.
#
#   Tools/deskdash.sh build     build DeskDash.app
#   Tools/deskdash.sh run       build, then open it (quits a running copy first)
#   Tools/deskdash.sh test      run the tests
#   Tools/deskdash.sh install   build an optimized, notarized copy into /Applications and open it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HOME/Library/Developer/DeskDash"
# Some installs point the Mac at the command line tools instead of Xcode. Use Xcode when it's there.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* \
      && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Signs the app with Troy's certificates so macOS trusts it: "Developer ID Application" (the one Apple accepts for
# apps given out outside the App Store, with the hardened runtime that notarizing needs) when it's there, else
# "Apple Development", else a local-only signature so macOS will at least open it on this Mac.
# Certificates are picked by fingerprint, because the same one can be in the Keychain twice (an old revoked copy
# next to the current one). Revoked ones are skipped: macOS won't open an app signed with them.
sign_app() {
    local app="$1" identities identity
    identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED || true)"
    identity="$(awk '/Developer ID Application/ {print $2; exit}' <<<"$identities")"
    if [[ -n "$identity" ]]; then
        codesign --force --options runtime --timestamp --sign "$identity" "$app"
        return
    fi
    identity="$(awk '/Apple Development/ {print $2; exit}' <<<"$identities")"
    codesign --force --sign "${identity:--}" "$app"
}

# Sends the app to Apple to be checked (notarized), then attaches Apple's OK to it, so macOS never warns about it.
# Needs a saved login, made once per Mac (see README): xcrun notarytool store-credentials DeskDash ...
notarize_app() {
    local app="$1" zip="$OUT/DeskDash-notarize.zip"
    if ! xcrun notarytool history --keychain-profile DeskDash >/dev/null 2>&1; then
        echo "Not notarized: no saved Apple login named DeskDash yet (see README, \"Notarizing\")."
        return
    fi
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile DeskDash --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
}

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
    sign_app "$app"
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
        notarize_app "$OUT/Release/DeskDash.app"
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

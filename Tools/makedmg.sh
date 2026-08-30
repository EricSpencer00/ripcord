#!/bin/bash
# Packages a built Ripcord.app into a disk image, and notarises it when credentials are present.
#
# Usage: Tools/makedmg.sh <Ripcord.app> <output.dmg>
#   SIGN            Developer ID Application identity. Default "-", which is ad-hoc: the image is
#                   then unsigned and Gatekeeper refuses it.
#   NOTARY_PROFILE  A notarytool keychain profile. Or set APPLE_ID, TEAM_ID and APPLE_PASSWORD.
set -euo pipefail

app=$1
dmg=$2
name=$(basename "$app" .app)
SIGN=${SIGN:--}

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"

mkdir -p "$(dirname "$dmg")"
rm -f "$dmg"
hdiutil create -quiet -volname "$name" -srcfolder "$staging" -ov -format UDZO "$dmg"

if [ "$SIGN" = "-" ]; then
    echo "makedmg: SIGN is unset, so the image is ad-hoc signed and Gatekeeper refuses it." >&2
    echo "→ $dmg"
    exit 0
fi

# The app is signed by the app rule; check it before wrapping a broken signature in an image.
codesign --verify --strict --verbose=1 "$app"
codesign --force --sign "$SIGN" --timestamp "$dmg"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    credentials=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ]; then
    credentials=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APPLE_PASSWORD")
else
    echo "makedmg: signed, but there are no notary credentials, so it is not notarised." >&2
    echo "→ $dmg"
    exit 0
fi

xcrun notarytool submit "$dmg" "${credentials[@]}" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
# The check a first launch makes. It fails if the ticket did not staple.
spctl --assess --type open --context context:primary-signature -v "$dmg"
echo "→ $dmg"

#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and create a GitHub release for AgentGlance.
#
# Usage:
#   ./scripts/release.sh              # build only (no upload)
#   ./scripts/release.sh --upload     # build + create GitHub release
#
# Prerequisites:
#   - Xcode with "Developer ID Application" certificate
#     (Xcode creates one automatically if you have a paid developer account)
#   - For notarization: APPLE_ID and APPLE_TEAM_ID env vars, or pass interactively
#   - For GitHub release: gh CLI authenticated
#
# The script will:
#   1. Read version from Xcode project
#   2. Archive the app
#   3. Export with Developer ID signing
#   4. Notarize (if credentials available)
#   5. Create a zip
#   6. Optionally upload as a GitHub release

SCHEME="AgentGlance"
PROJECT="AgentGlance.xcodeproj"
BUILD_DIR="build/release"
ARCHIVE_PATH="$BUILD_DIR/AgentGlance.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_NAME="AgentGlance.app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[release]${NC} $1"; }
warn()  { echo -e "${YELLOW}[release]${NC} $1"; }
error() { echo -e "${RED}[release]${NC} $1" >&2; exit 1; }

# Parse args
UPLOAD=false
for arg in "$@"; do
    case $arg in
        --upload) UPLOAD=true ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

# Get version from Xcode project
VERSION=$(xcodebuild -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | grep MARKETING_VERSION | head -1 | awk '{print $3}')
BUILD=$(xcodebuild -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | grep CURRENT_PROJECT_VERSION | head -1 | awk '{print $3}')

if [ -z "$VERSION" ]; then
    VERSION="0.1.0"
fi
if [ -z "$BUILD" ]; then
    BUILD="1"
fi

info "Building AgentGlance v$VERSION ($BUILD)"

# Clean build dir
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Create export options plist for Developer ID
cat > "$BUILD_DIR/ExportOptions.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

# Step 1: Archive
info "Archiving..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    || error "Archive failed"

info "Archive created at $ARCHIVE_PATH"

# Step 2: Export with Developer ID signing
info "Exporting with Developer ID signing..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_PATH" \
    -quiet \
    || error "Export failed. Do you have a Developer ID certificate? Try: Xcode > Settings > Accounts > Manage Certificates"

info "Exported to $EXPORT_PATH/$APP_NAME"

# Step 3: Notarize (if credentials available)
if command -v xcrun &>/dev/null; then
    # Try keychain profile first (set up via: xcrun notarytool store-credentials)
    if xcrun notarytool history --keychain-profile "AgentGlance" &>/dev/null 2>&1; then
        info "Notarizing with keychain profile..."
        ZIP_FOR_NOTARY="$BUILD_DIR/notarize.zip"
        ditto -c -k --keepParent "$EXPORT_PATH/$APP_NAME" "$ZIP_FOR_NOTARY"
        xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --keychain-profile "AgentGlance" \
            --wait \
            || warn "Notarization failed — distributing without notarization"
        xcrun stapler staple "$EXPORT_PATH/$APP_NAME" 2>/dev/null || true
        rm -f "$ZIP_FOR_NOTARY"
        info "Notarization complete"
    else
        warn "No notarization credentials found. To set up:"
        warn "  xcrun notarytool store-credentials AgentGlance \\"
        warn "    --apple-id YOUR_EMAIL \\"
        warn "    --team-id YOUR_TEAM_ID \\"
        warn "    --password YOUR_APP_SPECIFIC_PASSWORD"
        warn "Skipping notarization."
    fi
fi

# Step 4: Create release zip
RELEASE_ZIP="$BUILD_DIR/AgentGlance-v${VERSION}.zip"
info "Creating release zip..."
cd "$EXPORT_PATH"
ditto -c -k --keepParent "$APP_NAME" "../$(basename "$RELEASE_ZIP")"
cd - > /dev/null

info "Release zip: $RELEASE_ZIP"

# Step 5: Upload to GitHub (if --upload)
if $UPLOAD; then
    if ! command -v gh &>/dev/null; then
        error "gh CLI not found. Install with: brew install gh"
    fi

    TAG="v$VERSION"
    info "Creating GitHub release $TAG..."

    gh release create "$TAG" \
        "$RELEASE_ZIP" \
        --title "AgentGlance $TAG" \
        --generate-notes \
        || error "GitHub release failed. Is gh authenticated?"

    info "Release published: https://github.com/hezi/AgentGlance/releases/tag/$TAG"
else
    info "Done. Run with --upload to create a GitHub release."
fi

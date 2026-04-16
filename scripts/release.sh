#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and create a GitHub release for AgentGlance.
#
# Usage:
#   ./scripts/release.sh                      # build only (no upload)
#   ./scripts/release.sh --bump patch         # bump 1.0.0 → 1.0.1, then build
#   ./scripts/release.sh --bump minor         # bump 1.0.0 → 1.1.0, then build
#   ./scripts/release.sh --bump major         # bump 1.0.0 → 2.0.0, then build
#   ./scripts/release.sh --bump patch --upload  # bump + build + GitHub release
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
BUMP=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --upload) UPLOAD=true; shift ;;
        --bump)
            BUMP="$2"
            if [[ "$BUMP" != "patch" && "$BUMP" != "minor" && "$BUMP" != "major" ]]; then
                error "Invalid bump type: $BUMP (use patch, minor, or major)"
            fi
            shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

# Get current version from Xcode project
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

# Bump version if requested
if [ -n "$BUMP" ]; then
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
    case $BUMP in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac
    VERSION="$MAJOR.$MINOR.$PATCH"
    BUILD=$((BUILD + 1))

    info "Bumping version to $VERSION (build $BUILD)"

    # Update in pbxproj
    PBXPROJ="$PROJECT/project.pbxproj"
    sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/" "$PBXPROJ"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $BUILD/" "$PBXPROJ"

    # Commit the version bump
    git add "$PBXPROJ"
    git commit -m "Bump version to $VERSION (build $BUILD)"
    info "Version bump committed"
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

# Step 2: Export — try Developer ID signing, fall back to unsigned
mkdir -p "$EXPORT_PATH"
info "Exporting with Developer ID signing..."
if xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_PATH" \
    -quiet 2>/dev/null; then
    info "Exported with Developer ID signing"
    SIGNED=true
else
    warn "Developer ID export failed — shipping unsigned"
    warn "Users will need to right-click > Open on first launch"
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$EXPORT_PATH/$APP_NAME"
    SIGNED=false
fi

info "App at $EXPORT_PATH/$APP_NAME"

# Step 3: Notarize (if signed and credentials available)
if [ "$SIGNED" = true ] && command -v xcrun &>/dev/null; then
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

# Step 5: Sign for Sparkle updates
SPARKLE_SIGN=""
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
if [ -z "$SPARKLE_BIN" ]; then
    # Also check SourcePackages build artifacts
    SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/artifacts/*" -type f 2>/dev/null | head -1)
fi

if [ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN" ]; then
    info "Signing zip for Sparkle updates..."
    SPARKLE_SIGN=$("$SPARKLE_BIN" "$RELEASE_ZIP" 2>/dev/null || true)
    if [ -n "$SPARKLE_SIGN" ]; then
        info "Sparkle signature generated"
    else
        warn "Sparkle signing failed — appcast will need manual signature"
    fi
else
    warn "Sparkle sign_update not found — skipping Sparkle signing"
    warn "Build the project first so SPM downloads the Sparkle binary"
fi

# Step 6: Update appcast.xml for Sparkle
APPCAST_PATH="docs/appcast.xml"
if [ -f "$APPCAST_PATH" ]; then
    RELEASE_SIZE=$(stat -f%z "$RELEASE_ZIP" 2>/dev/null || stat --printf='%s' "$RELEASE_ZIP" 2>/dev/null || echo "0")
    DOWNLOAD_URL="https://github.com/hezi/AgentGlance/releases/download/v${VERSION}/AgentGlance-v${VERSION}.zip"
    PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

    # Extract edSignature from Sparkle output (format: sparkle:edSignature="..." length="...")
    ED_SIG=""
    if [ -n "$SPARKLE_SIGN" ]; then
        ED_SIG=$(echo "$SPARKLE_SIGN" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//' | sed 's/"$//' || true)
    fi

    # Build the new item XML in a temp file
    ITEM_TMP="$BUILD_DIR/sparkle-item.xml"
    cat > "$ITEM_TMP" << ITEMEOF

        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:releaseNotesLink>https://agentglance.app/releasenotes/${VERSION}.html</sparkle:releaseNotesLink>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${RELEASE_SIZE}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIG}"
            />
        </item>
ITEMEOF

    # Insert after the <language>en</language> line
    sed -i '' "/<language>en<\/language>/r $ITEM_TMP" "$APPCAST_PATH"

    info "Updated $APPCAST_PATH with v${VERSION}"
    if [ -z "$ED_SIG" ]; then
        warn "No Sparkle signature — update the edSignature in appcast.xml manually"
    fi

    # Generate release notes HTML stub for Sparkle
    NOTES_DIR="docs/releasenotes"
    NOTES_FILE="$NOTES_DIR/${VERSION}.html"
    if [ ! -f "$NOTES_FILE" ]; then
        mkdir -p "$NOTES_DIR"
        cat > "$NOTES_FILE" << 'NOTESEOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px; color: #222; padding: 16px; max-width: 480px; }
  h2 { font-size: 15px; margin: 16px 0 8px; }
  h2:first-child { margin-top: 0; }
  ul { padding-left: 20px; margin: 4px 0; }
  li { margin: 4px 0; line-height: 1.4; }
  strong { font-weight: 600; }
  code { background: #f0f0f0; padding: 1px 4px; border-radius: 3px; font-size: 12px; }
  @media (prefers-color-scheme: dark) {
    body { color: #ddd; background: #1a1a1a; }
    code { background: #333; }
  }
</style>
</head>
<body>
<h2>What's New</h2>
<ul>
  <li>TODO: Add release notes here</li>
</ul>
</body>
</html>
NOTESEOF
        info "Created release notes stub at $NOTES_FILE — edit before pushing!"
    fi
else
    warn "appcast.xml not found at $APPCAST_PATH — skipping Sparkle appcast update"
fi

# Step 7: Update download link on website
WEBSITE_PATH="docs/index.html"
if [ -f "$WEBSITE_PATH" ]; then
    sed -i '' "s|https://github.com/hezi/AgentGlance/releases/download/v[^\"]*|https://github.com/hezi/AgentGlance/releases/download/v${VERSION}/AgentGlance-v${VERSION}.zip|" "$WEBSITE_PATH"
    info "Updated download link in $WEBSITE_PATH to v${VERSION}"
fi

# Step 8: Upload to GitHub (if --upload)
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

    # Commit and push the updated appcast + release notes
    git add "$APPCAST_PATH" "docs/releasenotes/" "$WEBSITE_PATH" 2>/dev/null
    if ! git diff --cached --quiet 2>/dev/null; then
        info "Committing appcast and release notes..."
        git commit -m "Update appcast and release notes for v${VERSION}"
        git push
        info "Appcast and release notes pushed to GitHub Pages"
    fi
else
    info "Done. Run with --upload to create a GitHub release."
fi

#!/usr/bin/env bash
set -euo pipefail

SCHEME="OpenParsec"
PROJECT="OpenParsec.xcodeproj"
CONFIGURATION="Release"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/archive"
IPA_DIR="$BUILD_DIR/ipa"
APP_PATH="$ARCHIVE_PATH.xcarchive/Products/Applications/$SCHEME.app"
FAKESIGN=0

usage() {
  cat <<'EOF'
Build a local IPA for OpenParsec testing.

Usage:
  scripts/build_ipa.sh [--fakesign]

Options:
  --fakesign   Apply ldid fake-signatures (optional).

Output:
  build/ipa/OpenParsec.ipa
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fakesign)
      FAKESIGN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Try local Xcode override first so users don't need system-wide xcode-select.
if ! xcodebuild -version >/dev/null 2>&1; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    echo "Using Xcode from: $DEVELOPER_DIR"
  fi
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is unavailable with current developer directory:"
  xcode-select -p || true
  echo
  echo "Fix options:"
  echo "1) Run once (recommended):"
  echo "   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  echo "2) Or keep system unchanged and run this script with:"
  echo "   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build_ipa.sh --fakesign"
  exit 1
fi

if ! xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos"; then
  echo "Missing iOS platform in this Xcode installation."
  echo "Install it from Xcode > Settings > Components (iOS platform)."
  echo
  echo "Optional CLI attempt (may take a while):"
  echo "  xcodebuild -downloadPlatform iOS"
  exit 1
fi

if [[ ! -d "Frameworks/ParsecSDK.framework" ]]; then
  echo "Missing Frameworks/ParsecSDK.framework"
  echo "Add the legacy Parsec SDK framework before building."
  exit 1
fi

if [[ ! -f "Frameworks/ParsecSDK.framework/ParsecSDK" ]]; then
  echo "Invalid Frameworks/ParsecSDK.framework: missing binary Frameworks/ParsecSDK.framework/ParsecSDK"
  echo "Your current framework folder looks empty."
  echo "Copy a real iOS ParsecSDK.framework (with binary + Modules) into Frameworks/."
  exit 1
fi

if [[ ! -f "Frameworks/ParsecSDK.framework/Modules/module.modulemap" && ! -f "Frameworks/ParsecSDK.framework/Modules/ParsecSDK.swiftmodule/arm64-apple-ios.swiftmodule" ]]; then
  echo "Invalid Frameworks/ParsecSDK.framework: missing module metadata"
  echo "Expected either module.modulemap or swiftmodule files under Frameworks/ParsecSDK.framework/Modules"
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$IPA_DIR"

echo "[1/4] Archiving app (no code signing)..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  -sdk iphoneos \
  -configuration "$CONFIGURATION" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive failed: app bundle not found at $APP_PATH"
  exit 1
fi

if [[ "$FAKESIGN" -eq 1 ]]; then
  echo "[2/4] Fake-signing app with ldid..."

  if ! command -v ldid >/dev/null 2>&1; then
    echo "ldid not found. Install with: brew install ldid"
    exit 1
  fi

  if [[ -d "$APP_PATH/Frameworks" ]]; then
    find "$APP_PATH/Frameworks" -type d -name "*.framework" -exec ldid -S {} \;
  fi
  ldid -S "$APP_PATH"
else
  echo "[2/4] Skipping fake-sign step."
fi

echo "[3/4] Packaging IPA..."
PAYLOAD_DIR="$IPA_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"
(
  cd "$IPA_DIR"
  zip -qry "$SCHEME.ipa" Payload -x "._*" -x ".DS_Store" -x "__MACOSX"
)

echo "[4/4] Done"
echo "IPA: $IPA_DIR/$SCHEME.ipa"
echo "\nInstall note: iOS devices still require signing at install time."
echo "Use AltStore or Sideloadly to re-sign this IPA with your Apple ID."

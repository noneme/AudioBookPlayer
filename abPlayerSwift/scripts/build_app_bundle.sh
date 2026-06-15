#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="abPlayerApp"
CONFIGURATION="debug"

APP_BUNDLE_ID="${APP_BUNDLE_ID:-A1B2C3D4E5.com.ABPlay.myClone}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Audio Book Player}"
APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-1}"
APP_CATEGORY="${APP_CATEGORY:-public.app-category.entertainment}"
APP_COPYRIGHT="${APP_COPYRIGHT:-Copyright © 2026 pashka}"
APP_ICON_FILE="abPlayerApp.icns"

if [[ "${1:-}" == "--release" ]]; then
  CONFIGURATION="release"
fi

echo "Building $APP_NAME ($CONFIGURATION)..."
SPM_CACHE_DIR="$ROOT_DIR/.build/spm-cache"
SPM_CONFIG_DIR="$ROOT_DIR/.build/spm-config"
SPM_SECURITY_DIR="$ROOT_DIR/.build/spm-security"
CLANG_CACHE_DIR="$ROOT_DIR/.build/clang-module-cache"
mkdir -p "$SPM_CACHE_DIR" "$SPM_CONFIG_DIR" "$SPM_SECURITY_DIR" "$CLANG_CACHE_DIR"

export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR"

SWIFT_BUILD_ARGS=(
  --disable-sandbox
  --cache-path "$SPM_CACHE_DIR"
  --config-path "$SPM_CONFIG_DIR"
  --security-path "$SPM_SECURITY_DIR"
  --scratch-path "$ROOT_DIR/.build"
)

if [[ "$CONFIGURATION" == "release" ]]; then
  (cd "$ROOT_DIR" && swift build -c release "${SWIFT_BUILD_ARGS[@]}")
else
  (cd "$ROOT_DIR" && swift build "${SWIFT_BUILD_ARGS[@]}")
fi

BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION"
ARTIFACTS_DIR="$ROOT_DIR/.build/artifacts/ffmpeg-kit-spm"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
  echo "error: binary not found at $BUILD_DIR/$APP_NAME"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# SwiftPM resource bundles used by Bundle.module.
for bundle in "$BUILD_DIR"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$RESOURCES_DIR/"
  fi
done

ICON_SOURCE="$ROOT_DIR/$APP_ICON_FILE"
if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/$APP_ICON_FILE"
else
  echo "warning: icon file not found at $ICON_SOURCE"
fi

copy_ffmpeg_framework() {
  local name="$1"
  local fw="$name.framework"

  # 1) Preferred: already materialized by swift build into platform build dir.
  if [[ -d "$BUILD_DIR/$fw" ]]; then
    cp -R "$BUILD_DIR/$fw" "$FRAMEWORKS_DIR/"
    return 0
  fi

  # 2) Fallback: binary artifact cache (xcframework slice).
  local slice
  for slice in "macos-arm64" "macos-x86_64" "macos-arm64_x86_64"; do
    local candidate="$ARTIFACTS_DIR/$name/$name.xcframework/$slice/$fw"
    if [[ -d "$candidate" ]]; then
      cp -R "$candidate" "$FRAMEWORKS_DIR/"
      return 0
    fi
  done

  echo "warning: missing framework $fw in build and artifacts dirs"
  return 1
}

# Dynamic frameworks required by ffmpeg-kit runtime.
MISSING_FW=0
for fw_name in \
  ffmpegkit \
  libavcodec \
  libavdevice \
  libavfilter \
  libavformat \
  libavutil \
  libswresample \
  libswscale
do
  if ! copy_ffmpeg_framework "$fw_name"; then
    MISSING_FW=1
  fi
done

if [[ "$MISSING_FW" -ne 0 ]]; then
  echo "error: required ffmpeg frameworks are missing"
  exit 1
fi

add_rpath_if_missing() {
  local bin="$1"
  local rpath="$2"
  if ! otool -l "$bin" | grep -F "path $rpath " >/dev/null 2>&1; then
    install_name_tool -add_rpath "$rpath" "$bin"
  fi
}

# Ensure the app can resolve embedded frameworks from Contents/Frameworks.
add_rpath_if_missing "$MACOS_DIR/$APP_NAME" "@executable_path/../Frameworks"

# Ensure ffmpeg frameworks can resolve each other via @rpath.
for fw_bin in \
  "$FRAMEWORKS_DIR/ffmpegkit.framework/ffmpegkit" \
  "$FRAMEWORKS_DIR/libavcodec.framework/libavcodec" \
  "$FRAMEWORKS_DIR/libavdevice.framework/libavdevice" \
  "$FRAMEWORKS_DIR/libavfilter.framework/libavfilter" \
  "$FRAMEWORKS_DIR/libavformat.framework/libavformat" \
  "$FRAMEWORKS_DIR/libavutil.framework/libavutil" \
  "$FRAMEWORKS_DIR/libswresample.framework/libswresample" \
  "$FRAMEWORKS_DIR/libswscale.framework/libswscale"
do
  if [[ -f "$fw_bin" ]]; then
    add_rpath_if_missing "$fw_bin" "@loader_path/.."
  fi
done

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_FILE</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSApplicationCategoryType</key>
  <string>$APP_CATEGORY</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>$APP_COPYRIGHT</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign to avoid runtime loading issues for embedded frameworks on newer macOS.
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null

echo "Built app bundle: $APP_DIR"

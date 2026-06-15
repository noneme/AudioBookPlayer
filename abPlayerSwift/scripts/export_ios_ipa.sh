#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/ios/abPlayerApp.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/ios/export}"
EXPORT_METHOD="${EXPORT_METHOD:-debugging}"
EXPORT_TEAM_ID="${EXPORT_TEAM_ID:-${IOS_TEAM_ID:-}}"
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-automatic}"

EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-$ROOT_DIR/build/ios/ExportOptions.plist}"

resolve_archive_path() {
  local requested_path="$1"

  if [[ -d "$requested_path" ]]; then
    printf '%s\n' "$requested_path"
    return 0
  fi

  # When ARCHIVE_PATH is not explicitly provided, discover the latest archive.
  if [[ -z "${ARCHIVE_PATH:-}" || "$ARCHIVE_PATH" == "$ROOT_DIR/build/ios/abPlayerApp.xcarchive" ]]; then
    local -a candidates=()
    local archive

    while IFS= read -r archive; do
      candidates+=("$archive")
    done < <(find "$ROOT_DIR/build/ios" -maxdepth 2 -type d -name '*.xcarchive' 2>/dev/null)

    while IFS= read -r archive; do
      candidates+=("$archive")
    done < <(find "$HOME/Library/Developer/Xcode/Archives" -maxdepth 3 -type d -name '*.xcarchive' 2>/dev/null)

    if [[ ${#candidates[@]} -gt 0 ]]; then
      local latest
      latest="$({
        for archive in "${candidates[@]}"; do
          printf '%s\n' "$archive"
        done
      } | while IFS= read -r archive; do
        [[ -d "$archive" ]] || continue
        printf '%s\t%s\n' "$(stat -f '%m' "$archive")" "$archive"
      done | sort -nr | head -n 1 | cut -f2-)"

      if [[ -n "$latest" ]]; then
        printf '%s\n' "$latest"
        return 0
      fi
    fi
  fi

  return 1
}

usage() {
  cat <<'USAGE'
Export an IPA from an existing iOS .xcarchive.

Environment variables:
  ARCHIVE_PATH          Path to .xcarchive
  EXPORT_PATH           Output folder for exported IPA
  EXPORT_METHOD         debugging|release-testing|app-store-connect|enterprise
  EXPORT_TEAM_ID        Team ID for export signing
  EXPORT_SIGNING_STYLE  automatic|manual
  EXPORT_OPTIONS_PLIST  Output path for generated ExportOptions.plist

Example:
  EXPORT_TEAM_ID=ABCDE12345 \
  EXPORT_METHOD=debugging \
  abPlayerSwift/scripts/export_ios_ipa.sh
USAGE
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

RESOLVED_ARCHIVE_PATH="$(resolve_archive_path "$ARCHIVE_PATH" || true)"

if [[ -z "$RESOLVED_ARCHIVE_PATH" || ! -d "$RESOLVED_ARCHIVE_PATH" ]]; then
  echo "error: archive not found at $ARCHIVE_PATH"
  echo "hint: set ARCHIVE_PATH explicitly or ensure an .xcarchive exists in:"
  echo "  - $ROOT_DIR/build/ios"
  echo "  - $HOME/Library/Developer/Xcode/Archives"
  exit 1
fi

ARCHIVE_PATH="$RESOLVED_ARCHIVE_PATH"

APP_BUNDLE_PATH=""
if [[ -d "$ARCHIVE_PATH/Products/Applications" ]]; then
  APP_BUNDLE_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name "*.app" | head -n 1 || true)"
fi

if [[ -z "$APP_BUNDLE_PATH" ]]; then
  echo "error: archive is not exportable to IPA"
  echo "reason: no .app found under $ARCHIVE_PATH/Products/Applications"
  echo "details: current archive layout appears to be a SwiftPM executable (Products/usr/local/bin)"
  echo "next step: create an Xcode iOS app target that wraps abPlayerCore, then archive/export that target"
  exit 2
fi

mkdir -p "$(dirname "$EXPORT_OPTIONS_PLIST")" "$EXPORT_PATH"

cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>$EXPORT_METHOD</string>
  <key>signingStyle</key>
  <string>$EXPORT_SIGNING_STYLE</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "$EXPORT_TEAM_ID" ]]; then
  /usr/libexec/PlistBuddy -c "Add :teamID string $EXPORT_TEAM_ID" "$EXPORT_OPTIONS_PLIST" >/dev/null
fi

echo "Exporting IPA..."
echo "  archive: $ARCHIVE_PATH"
echo "  export:  $EXPORT_PATH"
echo "  method:  $EXPORT_METHOD"

(cd "$ROOT_DIR" && xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTIONS_PLIST")

echo "Export completed: $EXPORT_PATH"

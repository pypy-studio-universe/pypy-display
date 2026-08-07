#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
APP_NAME="PypyDisplay"
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/build"
APP_PATH="${BUILD_DIRECTORY}/${APP_NAME}.app"
MODULE_CACHE_DIRECTORY="${PROJECT_DIRECTORY}/.build/module-cache"
LOCALIZATION_BUNDLE_NAME="PypyDisplay_PypyDisplay.bundle"
ASSET_CATALOG="${PROJECT_DIRECTORY}/Assets/BrandAssets.xcassets"
ASSET_INFO_PLIST="${PROJECT_DIRECTORY}/.build/PypyDisplay-AssetInfo.plist"

cd "${PROJECT_DIRECTORY}"
mkdir -p "${MODULE_CACHE_DIRECTORY}"
export SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE_DIRECTORY}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIRECTORY}"

swift build -c release --disable-sandbox
SWIFT_BINARY_DIRECTORY="$(swift build -c release --disable-sandbox --show-bin-path)"

if [[ -d "${APP_PATH}" ]]; then
    rm -rf "${APP_PATH}"
fi

install -d "${APP_PATH}/Contents/MacOS"
install -d "${APP_PATH}/Contents/Resources"
install -m 755 "${SWIFT_BINARY_DIRECTORY}/${APP_NAME}" "${APP_PATH}/Contents/MacOS/${APP_NAME}"
install -m 644 "${PROJECT_DIRECTORY}/Packaging/Info.plist" "${APP_PATH}/Contents/Info.plist"
ditto \
    "${SWIFT_BINARY_DIRECTORY}/${LOCALIZATION_BUNDLE_NAME}" \
    "${APP_PATH}/Contents/Resources/${LOCALIZATION_BUNDLE_NAME}"

xcrun actool "${ASSET_CATALOG}" \
    --compile "${APP_PATH}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "${ASSET_INFO_PLIST}"

codesign --force --deep --sign - "${APP_PATH}"

echo "Built ${APP_PATH}"

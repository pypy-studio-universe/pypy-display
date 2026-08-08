#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
APP_NAME="PypyDisplay"
VERSION="0.9.2"
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/build"
APP_PATH="${BUILD_DIRECTORY}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIRECTORY}/${APP_NAME}-${VERSION}-arm64.dmg"
STAGING_DIRECTORY="${PROJECT_DIRECTORY}/.build/dmg-root"

bash "${SCRIPT_DIRECTORY}/build-app.sh"

if [[ -d "${STAGING_DIRECTORY}" ]]; then
    rm -rf "${STAGING_DIRECTORY}"
fi

mkdir -p "${STAGING_DIRECTORY}"
ditto "${APP_PATH}" "${STAGING_DIRECTORY}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIRECTORY}/Applications"

if [[ -f "${DMG_PATH}" ]]; then
    rm -f "${DMG_PATH}"
fi

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIRECTORY}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGING_DIRECTORY}"

hdiutil verify "${DMG_PATH}"
shasum -a 256 "${DMG_PATH}"

echo "Built ${DMG_PATH}"

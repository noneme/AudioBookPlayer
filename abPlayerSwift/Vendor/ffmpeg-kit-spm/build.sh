#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/scripts/build/ffmpeg-kit-build.sh"

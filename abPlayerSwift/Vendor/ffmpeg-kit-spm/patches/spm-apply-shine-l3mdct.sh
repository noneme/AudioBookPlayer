#!/usr/bin/env bash
# Deprecated name: forwards to spm-apply-after-download.sh (keeps older ios.sh hooks working).
set -euo pipefail
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_HERE}/spm-apply-after-download.sh"

# Patches

Applied automatically after ffmpeg-kit downloads sources (`spm-apply-after-download.sh`) or at checkout (`ffmpeg-kit-x265-cmake.patch` and `ffmpeg-kit-ffmpeg-sh-gnutls-openssl.patch` via `scripts/build/ffmpeg-kit-build.sh`).

| File | Purpose |
|------|---------|
| `ffmpeg-kit-chromaprint-cmake.patch` | CMake 4.x: raise `cmake_minimum_required` |
| `ffmpeg-kit-jpeg-cmake.patch` | CMake 4.x: libjpeg-turbo root `CMakeLists.txt` |
| `ffmpeg-kit-libpng-cmake.patch` | CMake 4.x: libpng |
| `ffmpeg-kit-libpng-pngpriv-fp-h.patch` | Apple SDK: drop `TARGET_OS_MAC` path that includes `<fp.h>` in `pngpriv.h` |
| `ffmpeg-kit-libsamplerate-cmake.patch` | CMake 4.x: lower bound in `3.x..3.y` range |
| `ffmpeg-kit-libsndfile-cmake.patch` | CMake 4.x: same pattern as libsamplerate |
| `ffmpeg-kit-libvidstab-cmake.patch` | CMake 4.x: vid.stab |
| `ffmpeg-kit-ffmpeg-sh-gnutls-openssl.patch` | FFmpeg configure: drop `--enable-openssl` when `--enable-gnutls` (mutual exclusion; libsrt still uses OpenSSL via deps) |
| `ffmpeg-kit-gnutls-configure-ac-gettext.patch` | gettext/autopoint: duplicate `AM_GNU_GETTEXT_REQUIRE_VERSION` in gnutls `configure.ac` |
| `ffmpeg-kit-sdl-cmake.patch` | CMake 4.x: SDL (alternate CMake path) |
| `ffmpeg-kit-shine-l3mdct-h.patch` | GNU C23: shine `l3mdct.h` prototype |
| `ffmpeg-kit-snappy-cmake.patch` | CMake 4.x: snappy |
| `ffmpeg-kit-srt-cmake.patch` | CMake 4.x: libsrt (SRT) root `CMakeLists.txt` |
| `ffmpeg-kit-soxr-cmake.patch` | CMake 4.x: soxr |
| `ffmpeg-kit-tiff-cmake.patch` | CMake 4.x: libtiff |
| `ffmpeg-kit-x265-cmake.patch` | CMake 4.x: vendored x265 in `tools/patch/cmake/x265/` |
| `ffmpeg-kit-xvid-encoder-h-c23-bool.patch` | C23: `typedef int bool` vs `bool` in xvid `encoder.h` |
| `spm-apply-after-download.sh` | Runs all post-download applies (patch + fallbacks) |
| `spm-apply-shine-l3mdct.sh` | Legacy entry; execs `spm-apply-after-download.sh` |

# Scripts

[`build/ffmpeg-kit-build.sh`](build/ffmpeg-kit-build.sh) clones and checks out ffmpeg-kit, injects hooks, installs Homebrew dependencies, runs `ios.sh`, `tvos.sh`, `macos.sh`, and `apple.sh`, refreshes `Package.swift`, then optionally runs `gh` for a release—or with `SPM_ACTION_RELEASE=1`, stops after `git push` so CI can publish via [softprops/action-gh-release](https://github.com/softprops/action-gh-release). Root [`build.sh`](../build.sh) sources it; do not run this file directly (it expects `PACKAGE_ROOT`).

Common environment: `PACKAGE_ROOT` (set by `build.sh`), `WORK_DIR` (default `.tmp/ffmpeg-kit`), `SPM_PATCH_ROOT` (repo root for `patches/`), `SPM_SKIP_RELEASE=1` to skip git and gh after building, `SPM_ACTION_RELEASE=1` to skip `gh` only (after push), `FFMPEG_KIT_GIT_REF` and `FFMPEG_KIT_TAG`.

For the GitHub Actions workflow that runs the same path, see "Publishing via GitHub Actions" in the root [`README.md`](../README.md).

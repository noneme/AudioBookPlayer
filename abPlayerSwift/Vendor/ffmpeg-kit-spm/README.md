# FFmpegKit SPM

Swift Package that ships [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) as binary XCFrameworks (full GPL-style dependency set) for iOS, macOS, and tvOS. `Package.swift` points at zipped `.xcframework` assets attached to [GitHub Releases](https://github.com/codewithtamim/ffmpeg-kit-spm/releases).

## Requirements (maintainers / local builds)

- macOS with Xcode (command-line tools and SDKs for the platforms you build)
- [Homebrew](https://brew.sh/) (the build installs toolchain deps such as `cmake`, `nasm`, `gh`, and related packages)
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated with `gh auth login` when you want releases created or uploads
- Enough disk space and time for a full ffmpeg-kit Apple build

## Installation (app or package)

Add the dependency in Xcode or in `Package.swift`:

```
https://github.com/codewithtamim/ffmpeg-kit-spm
```

```swift
.package(url: "https://github.com/codewithtamim/ffmpeg-kit-spm", .upToNextMajor(from: "1.0.0"))
```

Pick the version range to match a [release tag](https://github.com/codewithtamim/ffmpeg-kit-spm/releases) that contains the XCFramework zips you need.

## Usage

- High-level API: `import ffmpegkit`
- Direct libav usage: `import FFmpeg` (and individual `libav*` products as needed)

Integration details: [FFmpegKit Apple README](https://github.com/arthenica/ffmpeg-kit/tree/main/apple#3-using). libav usage: [FFmpeg wiki](https://trac.ffmpeg.org/wiki/Using%20libav*).

## Building locally

From the repo root:

```bash
./build.sh
```

This runs [`scripts/build/ffmpeg-kit-build.sh`](scripts/build/ffmpeg-kit-build.sh) (sourced by [`build.sh`](build.sh)). It clones [arthenica/ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit), applies this repo’s [`patches/`](patches/), builds iOS, tvOS, and macOS, merges XCFrameworks, recomputes SHA-256 checksums in [`Package.swift`](Package.swift), copies `LICENSE`, then unless you skip that phase it commits, tags, pushes, and creates a GitHub release with the `.zip` binaries.

Build without publishing (no `git commit`, `git push`, or `gh release`; updates trees and `Package.swift` only):

```bash
SPM_SKIP_RELEASE=1 ./build.sh
```

Environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `FFMPEG_KIT_TAG` | `v1.0.0` | Git tag and release name; also written into `Package.swift` as `release` |
| `FFMPEG_KIT_GIT_REF` | `main` | Branch, tag, or SHA to check out in arthenica/ffmpeg-kit |
| `FFMPEG_KIT_REPO` | `https://github.com/arthenica/ffmpeg-kit` | Clone URL for ffmpeg-kit |
| `WORK_DIR` | `<repo>/.tmp/ffmpeg-kit` | Clone and build tree |
| `SPM_SKIP_RELEASE` | unset | Set to `1` to skip git and gh release steps after a successful build |
| `SPM_ACTION_RELEASE` | unset | Set to `1` to stop after `git push` and skip the `gh` CLI (used by the GitHub Actions workflow so [softprops/action-gh-release](https://github.com/softprops/action-gh-release) can create the release and upload zips) |
| `SPM_DISABLE_INTEL_SIM` | `1` when `CI=true`, else unset | Adds `--disable-x86-64` for **iOS** and **tvOS** (Intel simulator) and **macOS** (Intel) to avoid common `x265`/pkg-config failures on x86_64 CI builds. Set to `0` for a full multi-arch build (including macOS universal). |

More detail: [`scripts/README.md`](scripts/README.md). Patch index: [`patches/README.md`](patches/README.md).

## Publishing via GitHub Actions

The workflow [`.github/workflows/build-spm-release.yml`](.github/workflows/build-spm-release.yml) runs on `workflow_dispatch` (manual). It checks out this repo, caches Homebrew where possible, installs the same dependency set as local builds, then runs `./build.sh` with `SPM_ACTION_RELEASE=1` (commit, tag, push only). A follow-up step uses [softprops/action-gh-release](https://github.com/softprops/action-gh-release) to create the GitHub release and attach the XCFramework `.zip` files from `.tmp/ffmpeg-kit/prebuilt/bundle-apple-xcframework/`.

### How to run it

1. Open the Actions tab, select "Build and Publish SPM Release", then Run workflow.
2. tag: SPM and GitHub release tag (for example `v1.0.0`). This becomes `FFMPEG_KIT_TAG` and should match what you want consumers to depend on.
3. ffmpeg_kit_ref: Git ref on arthenica/ffmpeg-kit to build (for example `main` or a tag such as `full-gpl.v5.1.2.6`).

The job sets `CI=true`, `FFMPEG_KIT_TAG`, and `FFMPEG_KIT_GIT_REF`, then runs `./build.sh`. On failure it prints the last 100 lines of `.tmp/ffmpeg-kit/build.log`.

Permissions: the job uses `contents: write` and the default `GITHUB_TOKEN` so the checkout can push commits and tags, and the release action can create the release and upload assets. Local full publishes still use `gh release` after authentication.

Forks: ensure Actions are enabled. If the default token cannot push to your default branch, configure a personal access token or repository rules as your organization requires.

## Layout

| Path | Role |
|------|------|
| [`build.sh`](build.sh) | Entrypoint; sets `PACKAGE_ROOT`, sources `scripts/build/ffmpeg-kit-build.sh` |
| [`scripts/build/ffmpeg-kit-build.sh`](scripts/build/ffmpeg-kit-build.sh) | Full build and release orchestration |
| [`patches/`](patches/) | ffmpeg-kit source fixes (CMake 4.x, C23, libpng, and similar) applied after download |

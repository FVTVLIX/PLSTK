# Building PLSTK

## Requirements

Use a Mac running macOS 14 or newer with Xcode and Swift 6 or newer. The current workflow is developed on Apple silicon. Intel builds have not been verified.

Install FFmpeg and ffprobe with libx264 and AAC support. With Homebrew already installed:

```sh
brew install ffmpeg
```

The media worker checks the standard Homebrew locations and the executable search path. The tools remain separate from the app bundle.

## Build the desktop app

From the repository root:

```sh
bash scripts/build-app.sh
open "Build/PLSTK.app"
```

For a release configuration build:

```sh
bash scripts/build-app.sh release
```

The script packages the Swift executable into an app bundle and applies an ad hoc signature. It does not create a universal binary, sign with a Developer ID, notarize the app, or bundle FFmpeg.

## Run verification

```sh
swift test
python3 scripts/smoke-test.py
```

The tests exercise native macOS media services and an isolated AppKit and SwiftUI view hierarchy. Use a macOS desktop session for the native editor tests. Run them in a normal local developer session rather than an environment that blocks those services.

The smoke test generates its own footage and stores results under `TestOutput/`. It does not require personal media. It may replace earlier generated fixtures in that directory.

## Use the command line tool

The Swift package also builds the `local-video` executable. It currently supports media probing, project creation, validation, and rendering.

```sh
.build/debug/local-video probe /path/to/source.mp4
.build/debug/local-video create /path/to/edit.localvideo /path/to/source.mp4
.build/debug/local-video validate /path/to/edit.localvideo
.build/debug/local-video render /path/to/edit.localvideo /path/to/output.mp4
```

Project files reference original assets. Keep those assets available when moving a project between computers.

## Distribution status

The repository provides source and a local build workflow. A self contained downloadable app needs additional packaging work, media tool licensing review, platform signing, and notarization.

Do not publish a locally generated app bundle as a verified production release without completing those steps and testing it on another Mac.

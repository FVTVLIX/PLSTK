# Third party notices

PLSTK contains an independently maintained Swift implementation. Its original source, tests, scripts, and documentation are covered by the license described in COPYRIGHT and LICENSE.

## FFmpeg and ffprobe

PLSTK discovers FFmpeg and ffprobe as local executables and invokes them through command line arguments. Their source and binaries are not included in this repository or copied into the app by the current build script.

The export workflow requires libx264 and AAC support. FFmpeg licensing depends on the exact build configuration. Builds with GPL components such as libx264 carry GPL obligations, and the development environment has used a build reporting GNU GPL version 3 or later.

Installing a system copy and redistributing a binary inside a future app package are different distribution arrangements. Before publishing a package that includes media tools, review the exact binaries and linked libraries, preserve their required notices, and provide the corresponding source and build information required by their licenses. Do not describe an entire FFmpeg build as LGPL without checking its configuration.

Run the following command to inspect the selected executable:

```sh
ffmpeg -L
```

Official project resources:

1. [FFmpeg licensing information](https://ffmpeg.org/legal.html)
2. [FFmpeg source code](https://ffmpeg.org/download.html)
3. [x264 project](https://www.videolan.org/developers/x264.html)

Copyright licenses do not by themselves resolve every patent or distribution issue associated with media codecs.

## Apple platform resources

SwiftUI, AppKit, AVFoundation, CoreGraphics, CoreText, CoreImage, ImageIO, and other system frameworks are supplied by the Apple development tools and operating system. PLSTK does not relicense those frameworks.

Titles use system typography through Core Text. Font files are not copied into the repository or app bundle.

System icons are referenced through SF Symbols names at runtime. Apple platform resources remain subject to their applicable terms.

## Reference and development material

Local investigation archives, extracted third party source, original application screenshots, and personal test projects are excluded from the public source tree. They are not part of the GPL grant for PLSTK.

Public documentation screenshots show PLSTK using synthetic media. Their presence does not grant rights to any external application, brand, or operating system resource shown within an image.

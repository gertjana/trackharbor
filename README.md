# TrackHarbor

TrackHarbor is a small native macOS app for turning Spotify playlist and album
URLs into tagged MP3 files for copying to an iPod or other MP3 player.

It provides a friendly SwiftUI interface around
[spotDL](https://github.com/spotDL/spotify-downloader), which finds the audio
on YouTube Music and uses FFmpeg to convert and tag the files.

## How it works

1. TrackHarbor validates the Spotify URL.
2. It extracts the playlist or album track metadata with spotDL.
3. It displays the complete track list before downloading.
4. It runs spotDL with the managed FFmpeg binary and streams progress into the
   song table.
5. Failed jobs are retried automatically. Existing successful files are not
   downloaded again.

Enable the folder organization option to save playlists in a folder named after
the playlist and albums under `Artist/Album/`. With the option off, songs are
saved directly in the chosen download folder.

The app stores its managed runtime outside the app bundle:

```text
~/Library/Application Support/TrackHarbor/runtime/
  python/       Portable Python runtime
  venv/         spotDL virtual environment
  .spotdl/      FFmpeg, Deno, and spotDL data
```

No system Python, FFmpeg, Deno, or spotDL installation is required. The first
launch needs an internet connection to download the portable runtime and
dependencies.

## Installation

Download or build `TrackHarbor.app`, then drag it to the Applications folder.
For a locally built app:

```sh
open TrackHarbor.app
```

This repository currently produces an ad-hoc signed app. macOS may show a
Gatekeeper warning the first time. Open the app from Finder using
**Control-click → Open**.

The app needs internet access on first launch and whenever spotDL or its
managed dependencies are installed or updated.

## Building from source

Requirements:

- macOS 13 or later
- Swift 5.9 or later
- Xcode or Apple Command Line Tools

Build the universal app:

```sh
./build-app.sh
```

The script builds both `arm64` and `x86_64` slices, combines them with `lipo`,
creates the `.icns` app icon, signs the app ad hoc, and outputs:

```text
TrackHarbor.app
```

The build currently emits linker warnings on some Command Line Tools
installations because Apple does not ship every Intel Swift compatibility
library there. The Intel slice is still produced and verified.

## Testing

The tests use Swift Testing and require a Swift 6 toolchain. Run them with:

```sh
swift test --disable-xctest
```

If the Command Line Tools fail to find `TestingMacros`, explicitly load the
installed plugin:

```sh
swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

## Publishing a release

Update `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, commit
and push the change, then push a matching version tag. For example:

```sh
git tag v1.1
git push origin v1.1
```

GitHub Actions runs the tests, builds the universal app, and publishes a GitHub
Release with `TrackHarbor.zip`. The tag must match the app's version. Regular
branch and pull-request builds upload an Actions artifact without publishing a
release.

## Credits and licensing

TrackHarbor is an independent wrapper and is not affiliated with Spotify,
YouTube, spotDL, or FFmpeg. It uses those projects as external components.
See [LICENSE](LICENSE) for the TrackHarbor license.

Use the app only for content you are authorized to download, and follow the
terms of the services and content providers involved.

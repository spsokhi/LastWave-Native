# LastWave for iOS

A native SwiftUI port of LastWave's core experience for iPhone and iPad (iOS 16+).
It talks to the same YouTube Music (InnerTube) endpoints as the Android app, using the
same no-cipher player clients (VISIONOS, ANDROID_VR) that return AAC audio AVPlayer can stream.

## Features

- YouTube Music song search
- Streaming with background audio, lock screen / Control Center / AirPods controls
- Tap a song to start a radio: the queue fills with YouTube Music's own mix and keeps going (autoplay)
- Up next queue: play next, add to queue, remove, jump
- Real-time synced lyrics from LRCLIB (tap a line to seek)
- Liked songs and listening history (stored on device)
- Last.fm scrobbling (uses your own Last.fm API key)

Not ported yet: downloads, YouTube Music account sync, AutoDJ, EQ, social feed, widgets,
playlist import.

## Building

You don't need a Mac. GitHub Actions builds it on a macOS runner.

1. Push this repo to your own GitHub repository (fork or new repo).
2. Open the **Actions** tab. If workflows are disabled on your fork, enable them.
3. Run **Build LastWave iOS** (it also runs on every push that touches `ios/`).
4. When it finishes, download the `LastWave-iOS-unsigned` artifact and unzip it to get `LastWave-unsigned.ipa`.

With a Mac: `brew install xcodegen`, then `cd ios && xcodegen generate && open LastWave.xcodeproj`,
pick your team under Signing & Capabilities, and run on your iPhone.

## Installing on an iPhone

The IPA is unsigned, and an app like this can't go on the App Store, so you sideload it
with your Apple ID:

- **Sideloadly** (Windows/macOS, sideloadly.io): connect the iPhone by USB, drag in the IPA,
  enter your Apple ID and start. With a free Apple ID the app expires after 7 days and must
  be re-signed; a paid developer account lasts 1 year.
- **AltStore** (altstore.io): same idea, and it can auto-refresh over Wi-Fi.

On the iPhone, enable **Settings → Privacy & Security → Developer Mode** (iOS 16+), then trust
your Apple ID under **Settings → General → VPN & Device Management**.

## Last.fm

Create an API account at https://www.last.fm/api/account/create. Enter the API key and shared
secret in Settings → Last.fm, then sign in with your Last.fm username and password. The secret
and session key are kept in the iOS Keychain; your password is not stored.

## Layout

```
ios/
  project.yml                 XcodeGen spec (the .xcodeproj is generated)
  LastWave/
    LastWaveApp.swift         App entry, theme
    Models/                   Track, Library (liked + history)
    Services/                 InnerTube (search, radio, stream resolution), Lyrics (LRCLIB), LastFm
    Player/PlayerManager.swift  AVPlayer queue, now-playing info, remote commands, scrobble timing
    Views/                    SwiftUI screens
```

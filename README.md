# Audio Extractor

A native macOS app for extracting audio from YouTube videos — pick a URL, pick a format, get a file. Built with SwiftUI, powered by `yt-dlp` and `ffmpeg` under the hood.

Personal-use tool. Not distributed or intended for anyone outside this project.

## Features

- **Paste a YouTube URL → fetch metadata** (title, length, source bitrate/codec) before downloading anything
- **Five output formats:**
  - `Original` — no re-encode, saves exactly what YouTube served (smallest, zero processing risk)
  - `WAV` — lossless, uncompressed
  - `FLAC` — lossless, compressed
  - `MP3` — 320kbps
  - `M4A / AAC` — 256kbps, QuickTime-native
- **Live progress** — real-time status text and progress bar streamed from `yt-dlp`/`ffmpeg`, with elapsed time and an estimated-remaining calculation
- **Per-format size estimates** before you commit, color-coded on a blue→red spectrum (smallest→largest)
- **Compare Formats, before downloading** — pick any two formats and run an objective null test between them (cross-correlation-based time alignment via Accelerate, then measures the loudness of the leftover "difference signal" in dB) using temporary files, so nothing lands in your Downloads folder until you actually decide
- **Blind ABX test** — the real answer to "can I actually hear a difference." Play hidden randomized clips, guess which is which, and get a statistical significance result (binomial p-value) over multiple trials
- **Custom animated app icon and gradient UI**, color-coded throughout (file size, bitrate quality, processing speed, live status)

## Requirements

- macOS with Xcode
- [Homebrew](https://brew.sh)
- `yt-dlp` and `ffmpeg`:
  ```bash
  brew install yt-dlp ffmpeg
  ```
- **App Sandbox must be disabled** in the target's Signing & Capabilities — the app shells out to `yt-dlp`/`ffmpeg` as external processes, which a sandboxed app can't do without a lot of extra entitlement work.

## Project structure

```
Audio Extractor/
├── Audio Extractor.xcodeproj/
├── code/
        ├── Audio_ExtractorApp.swift      # @main app entry point
        ├── ContentView.swift              # All UI: URL input, format picker,
        │                                  # progress, results, compare panel
        ├── Models.swift                   # AudioFormat, VideoInfo, DownloadResult,
        │                                  # ComparisonResult, AppError
        ├── YTDLPService.swift             # Shells out to yt-dlp/ffmpeg:
        │                                  # metadata fetch, download+convert,
        │                                  # null-test comparison
        ├── AudioAligner.swift             # Cross-correlation-based audio
        │                                  # alignment (Accelerate framework)
        ├── ABXTestView.swift              # Blind ABX listening test +
        │                                  # binomial significance calculation
        └── Assets.xcassets/
            └── AppIcon.appiconset/
                ├── Contents.json
                ├── icon_16x16.png
                ├── icon_16x16@2x.png
                ├── icon_32x32.png
                ├── icon_32x32@2x.png
                ├── icon_128x128.png
                ├── icon_128x128@2x.png
                ├── icon_256x256.png
                ├── icon_256x256@2x.png
                ├── icon_512x512.png
                └── icon_512x512@2x.png
```

> Note: rename `Audio_ExtractorApp.swift` above to whatever your actual `@main` entry file is called in Xcode — file naming can drift slightly from what's shown here depending on how the project was created.

## How it works, briefly

1. **Fetch Info** runs `yt-dlp -J <url>` to pull JSON metadata without downloading — title, duration, and the best available audio-only stream's bitrate/codec.
2. **Compare Formats** (optional, before downloading) downloads any two chosen formats into a temporary directory, detects any timing offset between them via cross-correlation, aligns them, and runs an `ffmpeg astats` null test on the difference signal. Closing the comparison deletes the temp directory and both files.
3. **Blind ABX Test** uses `AVAudioPlayer` to play randomized hidden clips from the two compared files and computes whether your hit rate over N trials is statistically distinguishable from chance guessing.
4. **Download & Convert** runs `yt-dlp -f bestaudio` to grab the highest-quality audio stream, then (unless `Original` is selected) pipes it through `ffmpeg` to your chosen format — saved permanently to Downloads.

## Known limitations

- The null test's dB reading is diagnostic, not authoritative — trust the ABX test over the number for a real answer on audibility.
- `Original` format files may download in `.webm` (Opus) or other containers that don't play natively in Music.app/QuickTime — use VLC or similar if needed.
- If the app is force-quit mid-comparison (rather than closed normally via "Close Comparison"), its temp directory can be orphaned — macOS periodically clears `/tmp` on its own, but it's not an immediate guarantee.

## License
 
MIT License

Copyright (c) 2026 Sharan Ravula

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

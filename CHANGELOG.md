# Changelog

## 1.0

First release.

- **Drop and convert**: drop files or whole folders on the window or the Dock icon. Each kind of file gets its own group (Video, Audio, Images) with its own template; ▶ converts a group, **Convert All** (⌘↩) every group with its template.
- **Formats**. Audio: MP3, M4A (AAC or Apple Lossless), AAC, WAV, FLAC, OGG Vorbis, Opus. Video: MP4, HEVC, MKV, MOV, WebM, GIF. Images: JPEG, PNG, HEIC, HEIF, WebP, AVIF, TIFF, BMP. Video files can also take an audio template: the sound is extracted.
- **Same as source**: every parameter starts there, read from the file itself (bitrate, sample rate, channels, bit depth, codec, resolution, frame rate, JPEG quality). It is adapted only when the format can't hold it, and the file's row says so.
- **Templates**: create, edit, duplicate and delete them in Settings › Templates; the everyday parameters first, the technical ones under **Advanced settings**. A group's changes can be saved into its template or as a new one.
- **Images**: resize by long side, short side, megapixels or percentage; metadata kept, without location, or removed.
- **CPU usage** in Settings: Low, Balanced, Maximum (files at a time, threads per file, priority).
- **Move originals to the Trash** after a successful conversion: off by default, never on failure or Stop.
- **Export and import** the settings and templates as one file.
- An existing file is never replaced; a stopped conversion leaves no half-written file behind.

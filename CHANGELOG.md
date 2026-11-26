# Changelog

## Unreleased

- New icon, redrawn with the rest of the suite from one shared design (same glass parts, light, shadows and safe area on every icon).
- In each group's header the X comes before Play (X left, Play right).
- The title bar's clear button is now **Clear Finished**, with an eraser symbol: it removes the files that have been through a conversion (converted, failed or stopped) and is enabled only when there are some. Files not yet converted stay.
- Settings: switching tabs resizes the window around its centre, so the tab buttons stay put.
- No scroll bars in lists (with "Always show" they took space and changed the lists' width).
- The icon next to the title turns clockwise while converting, easing in at the start and out at the end.
- Templates: the +, duplicate and − buttons are the same size, aligned and evenly spaced; the "Advanced settings" title opens and closes the group too.
- No folder button in the title bar: where files go and whether originals go to the Trash are chosen only in Settings › General.
- Undo after a conversion: a button rises into the status bar; it deletes the new files and puts back the originals from the Trash.
- Video quality "Custom bitrate": a slider in kbps, with a range that follows the resolution, frame rate and codec (and labels from small file to very high quality).
- The "HEVC (MP4)" format is gone: MP4 with the HEVC codec does the same. Saved HEVC templates become MP4 + HEVC; the unchanged built-in one is removed.
- Templates: + , duplicate and − only. − deletes any template, built-in ones too, at once; ⌘Z puts it back.

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

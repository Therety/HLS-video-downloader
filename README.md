## HTTP Live Streaming video downloader

This PowerShell script downloads **HLS streams** (video and audio tracks) from `.m3u8` playlists and merges them into a single `.mp4` file.

What it does:
- Downloads **video and audio HLS playlists**
- Fetches all segment files in parallel (with retries)
- Handles `EXT-X-MAP` init segments
- Rebuilds local `.m3u8` playlists
- Automatically runs `ffmpeg` to mux video + audio into one MP4
- Skips already downloaded segments (segments sometimes fail to download, you can just run the script again)

You only need to run the script **once** — no manual ffmpeg commands needed.

### Requirements
- PowerShell 5+ (Windows)
- `ffmpeg` available in PATH (or set the path in the script)

**Download FFmpeg:**  
https://www.ffmpeg.org/download.html

### Output
- `video/` – downloaded video segments
- `audio/` – downloaded audio segments
- `final_with_audio.mp4` – finished file

## Disclaimer

This tool is provided for educational and testing purposes only.

Only use it on streams that you own or have explicit permission to download.
The author is not responsible for misuse or copyright violations.

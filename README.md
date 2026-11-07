# Tape

A minimal Loom-style screen recorder for macOS, written in native Swift. Recordings stay on this Mac in `~/Movies/Tape`.

## What works (v0.1)
- Menu bar app: **Record Full Screen** or **Record Area…** (drag a rectangle, Esc cancels)
- Pick the screen, camera, microphone and quality (720p / 1080p / native)
- A round camera bubble you can drag, captured as part of the screen recording
- A red outline around the recorded area and a 3-2-1 countdown (neither appears in the video)
- Choose the camera shape: circle or rounded rectangle
- Click the menu bar icon to stop. The recording then opens in a window.
- **Captions (v0.2):** Parakeet v3 runs on this Mac, using the same model files as Murmur. The transcript sits beside the video: click a word to jump to it, and the current word is highlighted. Captions appear on top of the video. Each transcript is saved as `<name>.transcript.json` next to its video.
- **Editing (v0.4):** select words in the transcript and press Delete to cut them. Cut words disappear from the transcript, leaving a ✂︎ you can click to bring them back. **Remove Fillers** cuts every "um", "uh" or "euh" in one click, along with the pause around it. Double-click a word to select it, then press Delete to cut it. Press Return (or right-click) to fix the caption text without touching the video. On the trim bar, drag the yellow handles to trim the ends, or drag across the strip to select a section in the middle and press Delete to cut it. Click a red section to select it and restore it. Captions follow the edits. Nothing touches the original file: the edits are saved in `<name>.edits.json`.
- **Studio Sound:** one checkbox cleans up the voice, all on this Mac with audio units built into macOS (nothing added to the app). Apple's voice isolation removes background noise and room echo, an EQ removes rumble and adds presence, a compressor and gentle gate even things out, and the result is leveled to about -16 LUFS. The processed audio is cached as `<name>.studio.m4a` and used for playback and export.
- **Export (⌘E):** an H.264 MP4 with the edits applied and the captions burned in (optional), plus `.srt` and `.txt` transcripts.
- Command line: `Tape --transcribe <video>` prints the transcript; `Tape --export <video> <out.mp4>` renders with the saved edits and captions.

## Privacy and size
- Everything runs on this Mac. Tape's own code never touches the network. The only network access is the one-time Parakeet model download, and that only happens when you click **Download Model** (it's skipped if Murmur already downloaded the model).
- Hardened runtime. The only entitlements are camera and microphone; screen recording goes through the standard macOS permission.
- The app is about 5 MB. The speech model (about 480 MB) lives in `~/Library/Application Support/FluidAudio/Models`, shared with Murmur.

## Build
```
./build.sh --install && open -a Tape
```
Each install resets Tape's Camera, Microphone and Screen Recording permissions, because ad-hoc builds look like a new app to macOS. Grant them again on the first recording. Screen Recording needs Tape to be relaunched after you grant it.

## Next
1. Playback and export speed
2. Sharing: hosted link with a transcript download

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
- Testing: `.build/debug/Tape --transcribe <video>` prints the transcript.

## Build
```
./build.sh --install && open -a Tape
```
Each install resets Tape's Camera, Microphone and Screen Recording permissions, because ad-hoc builds look like a new app to macOS. Grant them again on the first recording. Screen Recording needs Tape to be relaunched after you grant it.

## Next
1. Cutting and trimming (including deleting words in the transcript)
2. Studio Sound (voice cleanup, like Descript's)
3. Filler word removal
4. Playback and export speed

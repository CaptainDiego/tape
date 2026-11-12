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
- **Editing (v0.4):** select words in the transcript and press Delete to cut them. Cut words disappear from the transcript, leaving a ✂︎ you can click to bring them back. **Remove Fillers** cuts every "um", "uh" or "euh" in one click, along with the pause around it. Double-click a word to select it, then press Delete to cut it. To rewrite words in the captions, select them and start typing (or click Rewrite…); the video isn't changed. On the trim bar, drag the yellow handles to trim the ends, or drag across the strip to select a section in the middle and press Delete to cut it. Click a red section to select it and restore it. Captions follow the edits. Nothing touches the original file: the edits are saved in `<name>.edits.json`.
- **Speed:** select a section on the trim bar and pick 1.25× to 3× from the Speed menu (with nothing selected it applies to the whole video). Sped-up sections show in blue; the voice keeps its natural pitch and the captions stay in sync.
- **Studio Sound:** one checkbox in the editor. Apple's voice isolation (the model behind FaceTime's Voice Isolation) removes keyboard clicks, background noise and room echo; then a warm podcast tone and gentle compression ([CrispVoice](https://github.com/Francium-Tech/CrispVoice)'s mastering settings) and podcast loudness (-19 LUFS). It all runs on this Mac with audio units built into macOS, so it adds nothing to the app, and takes about a second per minute of audio. The result is cached as `<name>.studio-sound.m4a` and used for playback, export and sharing. `Tape --studio <video>` makes it from the command line.
- **Export (⌘E):** an H.264 MP4 with the edits applied and the captions burned in (optional), plus `.srt` and `.txt` transcripts.
- **Sharing (optional, off by default):** **Share…** (⇧⌘S) uploads the edited video and transcript to *your own* Cloudflare Worker (`server/`) and copies a link. Anyone with the link sees the video with captions, the transcript beside it (click a line to jump there), and can copy or download it as Markdown, `.txt`, `.srt` or `.vtt`. The **Shared ▾** menu shows the view count and lets you copy the link, update it with new edits, or stop sharing (deletes the copy on the server). Each person deploys their own server, and there's no default one. Setup: `server/README.md`, or ask Claude Code to "deploy the share server" (the skill is in `.claude/skills/`). On the page, viewers can pick a speed (1× to 2×) and show or hide the transcript.
- Command line: `Tape --transcribe <video>` prints the transcript; `Tape --export <video> <out.mp4>` renders with the saved edits and captions.

## Privacy and size
- Everything runs on this Mac, and recordings stay there. Tape only touches the network in two cases, both started by you: the one-time Parakeet model download (when you click **Download Model**; skipped if Murmur already has the model), and **Share…**, which does nothing until you've entered your own server and token, and asks before every upload. The token is kept in the Keychain.
- Hardened runtime. The only entitlements are camera and microphone; screen recording goes through the standard macOS permission.
- The app is about 5 MB. The speech model (about 480 MB) lives in `~/Library/Application Support/FluidAudio/Models`, shared with Murmur.

## Build
```
./build.sh --install && open -a Tape
```
Each install resets Tape's Camera, Microphone and Screen Recording permissions, because ad-hoc builds look like a new app to macOS. Grant them again on the first recording. Screen Recording needs Tape to be relaunched after you grant it.

## Next
1. Sharing: embed code, a thumbnail for link previews, unique-viewer counts

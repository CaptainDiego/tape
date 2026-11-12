# Tape

A small, private screen recorder for macOS, in native Swift. Record your screen with a camera bubble, get captions from an on-device speech model, edit the video by editing its transcript, clean up your voice, and export or share a link. Recordings stay on your Mac in `~/Movies/Tape`.

The app is about 4 MB. It needs macOS 15 or later on an Apple silicon Mac.

## Features
- **Recording:** lives in the menu bar. **Record Full Screen** or **Record Area…** (drag a rectangle; Esc cancels). Pick the screen, camera (or No Camera), microphone and quality (720p, 1080p or native). The camera bubble is a circle or a rounded square you can drag, and it's recorded as part of the screen. A red outline marks the recorded area and a 3-2-1 countdown starts it; neither appears in the video. Click the menu bar icon to stop, and the recording opens in the editor.
- **Captions:** [Parakeet v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) runs on your Mac through [FluidAudio](https://github.com/FluidInference/FluidAudio). The transcript sits beside the video: click a word to jump to it, and the current word is highlighted. Captions show on top of the video.
- **Edit by text:** select words and press Delete to cut them from the video; click ✂︎ to bring them back. **Remove Fillers** cuts every "um", "uh" and "euh" in one click. To fix a caption, select the words and start typing (or click **Rewrite…**); the video isn't changed.
- **Trim bar:** drag the yellow handles to trim the ends, or drag across the strip to select a section and press Delete to cut it. Click a cut (red) section to restore it.
- **Speed:** select a section and pick 1.25× to 3× (with nothing selected it applies to the whole video). The voice keeps its natural pitch and the captions stay in sync.
- **Studio Sound:** one checkbox. Apple's voice isolation (the model behind FaceTime's Voice Isolation) removes keyboard clicks, background noise and room echo, then a warm podcast tone, gentle compression and podcast loudness (-19 LUFS). It uses audio units built into macOS, so it adds nothing to the app, and takes about a second per minute of audio.
- **Export (⌘E):** an H.264 MP4 with the edits applied, captions burned in or not, plus `.srt` and `.txt` transcripts.
- **Share (optional, ⇧⌘S):** uploads the edited video and transcript to **your own** Cloudflare Worker and copies a link. The page plays the video with captions viewers can turn on or off, shows the transcript (click a line to jump there), offers speed control and transcript downloads (Markdown, `.txt`, `.srt`, `.vtt`), and gives a preview image in Messenger, X and iMessage. **Shared ▾** shows the view count and lets you copy the link, update it with new edits, or stop sharing. See [Sharing](#sharing).
- **Move to Trash (⌘⌫):** moves a recording and its transcript, edits and Studio Sound to the Trash, and can delete its shared link.
- Nothing touches the original recording. Transcripts, edits and processed audio are saved next to it (`<name>.transcript.json`, `<name>.edits.json`, `<name>.studio-sound.m4a`).

## Privacy
- Recording, transcription, editing, Studio Sound and export all run on your Mac.
- Tape connects to the internet in only two cases, both started by you:
  1. **Download Model:** the one-time Parakeet download (about 480 MB, from Hugging Face), the first time you transcribe. It's skipped if the model is already in `~/Library/Application Support/FluidAudio/Models`.
  2. **Share…:** only to the server you set up, only after you've entered its address and token, and only after you confirm each upload. The token is kept in the Keychain.
- No analytics, no accounts, no default server.
- Hardened runtime; the only entitlements are camera and microphone. Screen recording uses the standard macOS permission.

## Install
Download the DMG from [Releases](../../releases), open it and drag Tape to Applications. It isn't notarized, so the first time: open Tape, click **Done**, then go to System Settings → Privacy & Security and click **Open Anyway**. Allow camera, microphone and screen recording, then quit and reopen Tape once.

Or build it yourself (Swift 6.2, from Xcode or the Command Line Tools):
```sh
./build.sh --install && open -a Tape   # builds, installs to /Applications
./build.sh --dmg                        # builds dist/Tape-<version>.dmg
```
Each `--install` resets Tape's camera, microphone and screen recording permissions, because ad-hoc builds look like a new app to macOS. macOS may also ask once to let Tape read its sharing token from the Keychain; click **Always Allow**.

## Sharing
Sharing is self-hosted: you deploy `server/` (one Cloudflare Worker, a private R2 bucket and a small D1 database) to your own Cloudflare account. It fits in the free tier for personal use, and R2 has no fees for viewers watching.

- **With Claude Code:** open this repo and ask it to "set up sharing". The [`deploy-share-server`](.claude/skills/deploy-share-server/SKILL.md) skill creates the bucket and database, deploys the Worker and connects Tape. Your links look like `https://tape.<your-subdomain>.workers.dev/recordings/<id>`.
- **By hand:** see [`server/README.md`](server/README.md).

## Command line
`/Applications/Tape.app/Contents/MacOS/Tape` also takes:
- `--transcribe <video>`: prints the transcript.
- `--export <video> <out.mp4>`: renders with the saved edits and burned-in captions.
- `--studio <video>`: makes the Studio Sound audio.
- `--share <video>`: uploads like the Share button (`TAPE_SERVER` and `TAPE_TOKEN` in the environment).
- `--configure-sharing`: saves `TAPE_SERVER` and `TAPE_TOKEN` as Tape's sharing settings.

## License
[MIT](LICENSE). FluidAudio is Apache-2.0; the Parakeet model is CC-BY-4.0 (NVIDIA).

# LocalFlow — Team Install Guide

Local, private voice dictation for macOS (Apple Silicon). Hold a hotkey,
speak, and the text is typed into whatever app has focus. Nothing leaves
your Mac.

You do **not** need Homebrew, whisper-cpp, or any developer tools — the
speech engine is inside the app, and the speech model downloads itself on
first run.

## 1. Install

1. Download `LocalFlow-<version>.dmg` (link shared internally).
2. Open the DMG and drag **LocalFlow** onto the **Applications** shortcut.
3. Eject the DMG.

## 2. First launch — get past the security warning

LocalFlow is an internal tool, not distributed through the App Store and not
notarized by Apple (that requires a paid Apple Developer account). macOS
therefore shows an "Apple could not verify…" / "unidentified developer"
warning on first open. This is expected — it means Apple hasn't scanned the
app, not that anything is wrong with it. You only have to do this once.

**macOS 15 (Sequoia) or newer:**

1. Double-click LocalFlow in Applications. A dialog says *"LocalFlow" Not
   Opened — Apple could not verify "LocalFlow" is free of malware*. Click
   **Done** (not "Move to Trash").
2. Open **System Settings → Privacy & Security**, scroll to the bottom
   **Security** section. You'll see *"LocalFlow" was blocked to protect
   your Mac* — click **Open Anyway**.
3. Authenticate (Touch ID / password) and confirm **Open Anyway** in the
   final dialog.

**macOS 14 (Sonoma) or older:**

1. In Applications, **right-click (or Control-click) LocalFlow → Open**.
2. The warning dialog now has an **Open** button — click it.
   (Plain double-click only offers "Move to Trash"; the right-click route
   is the one that unlocks the Open button.)

## 3. Grant permissions (one-time)

- **Microphone** — a standard prompt appears on first dictation; click
  **Allow**.
- **Accessibility** — needed for the global hotkey and for pasting text
  into other apps. When prompted (or if the hotkey does nothing):
  1. Open **System Settings → Privacy & Security → Accessibility**.
  2. Enable the **LocalFlow** toggle (click **+** and pick
     /Applications/LocalFlow.app if it isn't listed).
  3. **Quit and relaunch LocalFlow** — the permission is only read at
     startup. (Menu-bar mic icon → Quit.)

## 4. First run: model download

On first launch LocalFlow downloads its speech model (~600 MB) from
Hugging Face — the menu-bar icon's menu shows the progress. On office
Wi-Fi this takes a few minutes; dictation is unavailable until it
finishes. The model is stored in
`~/Library/Application Support/LocalFlow/models/` and never re-downloaded.

## 5. Optional: AI cleanup (Ollama)

Out of the box you get raw transcripts. If you also want automatic cleanup
(fillers stripped, punctuation fixed) and voice-editing of selected text,
install [Ollama](https://ollama.com/download) (or `brew install ollama`),
then:

```bash
ollama pull llama3.2:3b   # ~2 GB, one-time
```

and enable **AI Cleanup via Ollama** in the LocalFlow menu. Everything
still runs locally. Without Ollama the app works fine — you just get the
raw transcript.

## Hotkeys

| Action | How |
| --- | --- |
| Dictate (push-to-talk) | **Hold right-⌥**, speak, release |
| Dictate hands-free | **Tap right-⌥** — stops by itself after ~1 s of silence (tap again to stop early) |
| Edit selected text by voice | Select text, **hold Shift + right-⌥**, speak the instruction ("make this formal") — needs Ollama |
| Settings / everything else | Click the **mic icon in the menu bar** |

## Troubleshooting

- **"Whisper: failed" in the menu / dictation never becomes ready** — the
  app may be looking for the speech engine in the wrong place. Run this
  once in Terminal, then relaunch LocalFlow:

  ```bash
  defaults write com.shubham.localflow whisperServerBinary \
      /Applications/LocalFlow.app/Contents/Resources/bin/whisper-server
  ```

- **Transcripts miss words / mic level looks low** — the floating pill
  shows a live mic level while recording. If it barely moves, check
  **System Settings → Sound → Input**: pick the right microphone (the
  MacBook mic, not e.g. AirPods in the drawer) and raise the input volume.
- **Can't see the menu-bar icon** — on notched MacBooks it can be hidden
  under the notch when many icons are present. The floating pill at the
  bottom of the screen still shows recording state; to reach the menu,
  remove some other menu-bar icons (Cmd-drag them off) or use an app like
  Bartender/Ice.
- **Pasting fails in terminals (SSH/tmux)** — some terminals block
  synthetic paste. The transcript is still on your clipboard; paste
  manually, or use menu → **Paste Last Transcript**.
- **Hotkey does nothing** — Accessibility isn't granted (or the app wasn't
  relaunched after granting). See step 3.
- **"LocalFlow is damaged and can't be opened"** — a stricter Gatekeeper
  variant of the step-2 warning. Fix in Terminal, then open normally:

  ```bash
  xattr -d com.apple.quarantine /Applications/LocalFlow.app
  ```

- **Logs** — menu → **Open Logs Folder**
  (`~/Library/Application Support/LocalFlow/`): `localflow.log` (app) and
  `whisper-server.log` (speech engine).

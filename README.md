# LocalFlow

Fully-local voice dictation for macOS (Apple Silicon): hold a hotkey, speak,
and the transcribed text is pasted into whatever app has focus. No cloud, no
API keys — transcription runs on-device via Parakeet (CoreML) for English
and whisper.cpp (Metal) for Hindi/Hinglish/other languages.

**Distributing to your team?** See [TEAM_INSTALL.md](TEAM_INSTALL.md) — the
DMG is self-contained (bundled whisper-server, models auto-download on
first run).

## v0.3.0 highlights

- **Dual engine**: Parakeet-tdt-0.6b-v3 (CoreML/ANE, ~29% fewer errors on
  casual speech) for English; whisper large-v3-turbo for Hindi/Hinglish/auto.
  Automatic fallback to whisper if Parakeet fails.
- **Context awareness**: the frontmost app picks the cleanup tone — formal
  in Mail, casual in Slack/iMessage, and raw (no LLM cleanup) in
  terminals/editors. Menu → Edit App Categories…
- **Snippets**: spoken trigger phrases expand to canned text ("my email
  signature" → your signature). Menu → Edit Snippets…
- **History**: menu → History… shows raw vs AI-cleaned for the last 50
  dictations with copy buttons — any cleanup mistake is recoverable.
- **Auto-learned dictionary**: words you type over after a dictation are
  detected (accessibility diff) and promoted into the glossary after two
  sightings. Menu → Review Learned Words…
- **Chunked cleanup**: long dictations are cleaned in sentence windows so
  the local LLM edits faithfully instead of restructuring.
- **Zero-setup first run**: whisper + VAD models auto-download with
  progress in the menu; Parakeet models auto-download on first English use.

## Architecture

```
hold/tap right-⌥ ──► AVAudioEngine (16 kHz mono) + live endpointing
release / VAD    ──► WAV ──► whisper-server /inference
                             (large-v3-turbo, Metal, Silero VAD, glossary prompt)
                     └──► transcript ──► [optional Ollama cleanup]
                                     └──► clipboard-paste inject (Cmd+V + restore)
```

- **Hotkey** (switchable to **Fn** from the menu; for Fn set System
  Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** first):
  - **Hold** right-⌥ = push-to-talk: release to transcribe.
  - **Tap** right-⌥ = hands-free: recording stops itself after ~1 s of
    trailing silence (tap again to stop early). Toggleable in the menu.
  - **Shift + right-⌥ (hold)** = command mode: select text first, hold and
    speak an instruction ("make this formal", "turn into bullets") — the
    LLM edit replaces the selection. Requires Ollama.
- **STT**: whisper.cpp `whisper-server` (spawned/managed by the app, kept
  warm) with `ggml-large-v3-turbo-q5_0` + **Silero VAD** (suppresses
  silence hallucinations like "Thank you.").
- **AI cleanup (optional, menu toggle)**: transcripts ≥50 chars are piped
  through Ollama (`llama3.2:3b`) to strip fillers, fix punctuation, resolve
  self-corrections. Any failure falls back to the raw transcript; the menu
  offers **Paste Raw Transcript** whenever cleanup changed the text.
- **Glossary** (menu → Edit Glossary…): one term per line; biases whisper
  decoding (initial prompt) and the cleanup LLM toward exact spellings.
- **Injection**: clipboard paste with snapshot/restore of the previous
  clipboard. If paste fails (terminals over SSH/tmux), the transcript stays
  on the clipboard and the menu has **Paste Last Transcript** as an escape
  hatch.
- **URL triggers** (Raycast/Alfred/BTT/shell): `open localflow://start`,
  `localflow://stop`, `localflow://toggle`, `localflow://paste-last`,
  `localflow://paste-raw`. Start/toggle run hands-free with VAD auto-stop.
- **Overlay HUD**: a floating pill (bottom of the active screen) shows
  recording/transcribing/cleaning state, elapsed time, and live mic level —
  visible even when the menu-bar icon is hidden under the notch.
- **Voice Profile** (menu → Voice Profile…): fully-local usage stats —
  words dictated, average WPM, filler ratio, top words, time saved vs
  typing, 7-day chart. Data never leaves `~/Library/Application
  Support/LocalFlow/stats.jsonl`.
- **Language** (menu): Auto-detect, English, Hindi (Devanagari), or
  **Hinglish (Roman mix)** — decodes as English with a romanized-Hindi
  seed prompt so code-switched Hindi stays in Latin script instead of
  being mistranslated ("kal meeting hai" stays "kal meeting hai").
- **Graceful stop**: releasing the key waits for your actual pause (up to
  1.5 s) before cutting the recording, so a key released mid-word doesn't
  clip the utterance.

### Ollama setup (optional, for AI cleanup + command mode)

```bash
brew install ollama
ollama serve &          # or run the Ollama.app
ollama pull llama3.2:3b # ~2 GB
```
Then enable "AI Cleanup via Ollama" in the menu.

## Setup

```bash
./scripts/setup.sh      # installs whisper-cpp (brew), downloads the model (~574 MB)
./scripts/make_app.sh   # builds dist/LocalFlow.app
open dist/LocalFlow.app
```

### Permissions (one-time)

1. **Accessibility** — prompted on first launch (needed for the global hotkey
   monitor and synthetic Cmd+V). System Settings → Privacy & Security →
   Accessibility → enable LocalFlow.
2. **Microphone** — prompted on first launch.

After granting Accessibility, **quit and relaunch** the app (the grant is
read at monitor-install time). Note: rebuilding the app re-signs it, which
may require re-granting Accessibility.

## Testing checklist (v0)

1. Launch → mic icon appears in the menu bar; menu shows "Whisper: ready".
2. Focus any text field (Notes, Slack, browser).
3. Hold right-⌥, speak a sentence, release.
4. Icon: mic → mic.fill (recording) → waveform (transcribing) → mic.
5. Text appears at the cursor within ~1–2 s.
6. Copy something, dictate, then Cmd+V — your original clipboard is back.
7. Menu → Paste Last Transcript re-inserts the last dictation.

Logs: `~/Library/Application Support/LocalFlow/localflow.log` (app) and
`whisper-server.log` (STT server). Menu → Open Logs Folder.

## Roadmap

- v1: Silero VAD auto-endpointing (stop on silence, not just key release)
- v2: optional Ollama cleanup pass (fillers, punctuation, lists)
- v3: custom dictionary/glossary
- v4: command mode (select text + speak an instruction)

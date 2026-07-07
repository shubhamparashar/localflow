# LocalFlow → Wispr Flow parity plan (Opus-executable)

**For the implementing agent:** This plan is self-contained — do not re-research Wispr Flow. Work the phases in order; each has explicit exit criteria. Do not mark a phase done without its verification evidence pasted in your report. Keep diffs minimal — this codebase is small and working; do not refactor untouched code. Anything requiring live audio or clicking the real UI is a **USER-GATE**: prepare it, then stop and hand the user a one-screen checklist instead of claiming it verified.

## Context (current truth, 2026-07-07)

- Repo: `~/repo/localflow` — Swift/AppKit menu-bar dictation app, SwiftPM. Build: `scripts/setup.sh` then `scripts/make_app.sh` (signs with the "LocalFlow Dev" cert — always build via this script, ad-hoc rebuilds break TCC grants). State doc: `~/repo/shubham/context/okf/second-brain/projects/localflow-dictation.md` — read it first, update it (and its TODO list) at the end of every phase.
- Working today: dual STT (Parakeet-tdt-0.6b-v3 CoreML ~0.17s English; whisper large-v3-turbo via app-managed whisper-server for Hindi/Hinglish/auto, auto-fallback), right-⌥ push-to-talk + tap-for-VAD + Shift+⌥ command mode, clipboard-inject with restore, opt-in Ollama llama3.2:3b cleanup with length/overlap guards (~1.5s warm), app→category→tone context (code apps skip cleanup), auto-learned glossary from AX correction-watching, snippets, history window, scratchpad + Improve Writing, settings, onboarding, Flow-Bar pill HUD.
- Key files: `AppDelegate.swift` (pipeline state machine), `HotkeyMonitor.swift`, `AudioRecorder.swift`, `TranscriptionRouter.swift`, `ParakeetTranscriber.swift`, `WhisperServerManager.swift`, `Transcriber.swift`, `OllamaCleaner.swift`, `AppContext.swift`, `Glossary.swift`, `CorrectionWatcher.swift`, `TextInjector.swift`, `OverlayHUD.swift`, `SettingsController.swift`, `Config.swift`.
- Unpushed commit `595e9e1` on master — push it before starting (or confirm with user).
- No test target exists. No automated tests.

## Ground rules

1. Build after every phase via `scripts/make_app.sh`; a phase isn't done if the app doesn't build and launch.
2. Never regress raw-dictation latency (~0.17s Parakeet path). Any new work in the hot path must be async/off it.
3. Cleanup/LLM features stay **opt-in** and guarded (existing length + word-overlap guards are load-bearing — reuse, don't bypass).
4. No new dependencies without strong justification; prefer AppKit/AX/existing deps.
5. Report per phase: what changed (files), proof (test output / log lines / screenshot), and what's USER-GATED.

---

## Phase 0 — Stabilize what's built (do first, smallest)

**0a. Fix the improve/dictation race.** `improveSelectedText`'s async LLM call doesn't hold the pipeline — a hotkey press mid-improve can interleave two injections. Fix: set the pipeline state to busy (or a guard flag) in `AppDelegate.swift` for the duration of the async call; ignore or queue hotkey events while busy; always clear the flag in a defer.
- **Exit:** a rapid-fire scripted sequence (trigger improve, immediately trigger dictation via the URL trigger) produces exactly one injection and one log line saying the second trigger was rejected. Paste the log.

**0b. Test target.** Add a SwiftPM test target covering pure logic only (no audio): snippet expansion, glossary promotion (2-sightings rule), cleanup guards (length/word-overlap accept/reject cases), long-take chunker boundaries.
- **Exit:** `swift test` passes with ≥12 assertions across those 4 units. Paste the pass summary.

**0c. USER-GATE: Flow-Bar pill live click-test.** Prepare the checklist from the state doc (idle pill click-to-dictate, hover hint, right-click menu, start ping, dead-mic warning, multi-monitor drag/clamp). Hand it to the user; do not check these off yourself.

## Phase 1 — Cleanup levels + user-pickable styles (Wispr "Styles")

Add `cleanupLevel: none|light|medium|high` and an optional per-app style override (formal/casual/code) to `Config.swift`. Map levels to prompt variants in `OllamaCleaner.swift` (light = punctuation+fillers only; medium = current behavior; high = grammar+tone rewrite, same guards). Expose a global default in `SettingsController.swift` and a per-app override column in the existing app-categories editor (`AppContext.swift`).
- **Exit:** unit tests assert the 4 levels produce 4 distinct prompts and that `none` bypasses Ollama entirely; settings round-trip persists across relaunch (log or defaults read as proof). USER-GATE: one dictation per level for feel.

## Phase 2 — 100+ languages (UI-only unlock)

whisper large-v3-turbo already handles ~100 languages; the 4-item Language menu is the only gap. Replace it with a searchable language picker (full whisper language list, constant table in `Config.swift`) + a true "Auto" that passes auto-detect to whisper. Route in `TranscriptionRouter.swift`: English → Parakeet fast path (unchanged); everything else / Auto → whisper with the language code (or none for auto).
- **Exit:** unit test on the routing function (en→parakeet, hi→whisper+`hi`, auto→whisper+nil, fr→whisper+`fr`); picker persists selection. USER-GATE: one real dictation in a non-Hindi second language.

## Phase 3 — Live captions in the Flow-Bar (perceived-latency win)

Stream partial transcripts into `OverlayHUD.swift`'s recording state — HUD-only, never inject partials. Approach: tap a rolling buffer in `AudioRecorder.swift` (e.g. every ~1s of accumulated audio), run Parakeet on the accumulated snapshot off the main thread, replace (not append) the HUD caption text. Skip partials entirely when whisper-server is the active engine if chunked partials prove awkward — Parakeet-only captions are acceptable v1. Final injected text still comes from the existing full-take path (single source of truth).
- **Exit:** logs show ≥2 partial updates during a 5s synthetic-audio take with final text matching the existing path byte-for-byte; hot-path latency measurement before/after shows no regression (paste both numbers). USER-GATE: visual check that captions feel live.

## Phase 4 — AX nearby-text context (the "magic" gap)

Read the focused field's existing text via AX (`AXFocusedUIElement` → value/selected-range, cap ~500 chars around the caret) in a small helper extending `AppContext.swift`. Feed it two places: (a) whisper initial-prompt in `Transcriber.swift` (biases proper nouns/spelling), (b) a context block in the cleanup prompt in `OllamaCleaner.swift`. Fail silently to today's behavior when AX denies (secure fields, non-AX apps); never log captured field text (privacy).
- **Exit:** unit test on the truncation/sanitization helper; manual scripted check — dictating a name that exists in a prepared TextEdit doc spells it correctly with context on and phonetically without (paste both transcripts). Confirm secure-field (password box) returns nil context via log.

## Phase 5 — Developer mode (code-aware cleanup)

Today code apps get raw transcription. Add a `code` cleanup prompt: punctuation only, preserve identifier casing/symbols verbatim, no sentence-case rewriting; optionally bias with glossary terms. Wire as the default style for the code category in `AppContext.swift` (user can still override to none per Phase 1).
- **Exit:** unit test: given a transcript containing `camelCase` and `snake_case` tokens, the code prompt instructs preservation and guards accept the cleaned output. USER-GATE: one dictation into VS Code/Cursor.

## Phase 6 — Quiet-speech (whisper-mode 80/20)

True whispered-speech ASR needs a fine-tuned model — out of scope. Ship the mitigation: a "Quiet mode" toggle (`Config.swift` + menu) that applies input auto-gain boost and a lower Silero VAD threshold profile in `AudioRecorder.swift`.
- **Exit:** toggle switches gain/VAD parameters (log proof); normal mode unchanged. USER-GATE: real quiet-speech test.

## Phase 7 — Quick language switch on the Flow-Bar pill

The pill should let you flip language without opening Settings. Add to `OverlayHUD.swift`: (a) right-click menu gains a "Language" submenu (recent 3 languages + Auto + "More…" opening the Phase-2 picker); (b) a small language badge on the idle pill (e.g. "EN"/"HI"/"A") showing the active engine language; (c) optional ⌥-scroll or click-on-badge cycles the recents. Persist per-selection in `Config.swift`. Bonus (small): **per-app language memory** — remember the last language used per frontmost app in `AppContext.swift` and auto-switch (WhatsApp→Hinglish, VS Code→EN); toggleable, off by default.
- **Exit:** badge reflects the routed engine language in logs; switching via the pill changes the next take's routing without touching Settings. USER-GATE: feel-check the badge + cycling.

## Phase 8 — Landing / dashboard window

A proper home window (shown on launch unless "open at login quietly" is set, and via menu-bar "Open LocalFlow"). One NSWindow with a sidebar (reuse the existing Settings/History/Scratchpad controllers as tabs rather than rebuilding them): **Home tab** = status card (engines loaded, Ollama up/down, mic OK), quick toggles (cleanup level, language, quiet mode), and a stats strip — words dictated today/week, average latency, estimated time saved vs typing (words ÷ 40wpm typing vs actual speaking time; the history store already has timestamps + text lengths in `History` storage). **Keep it AppKit, no SwiftUI rewrite of existing panes.**
- **Exit:** window opens from menu bar; stats computed from real history data (paste computed numbers for the current history file); all tabs are the existing controllers (no duplicated settings logic).

## Phase 9 — Speed: keep everything hot + measure it

Make the fast path reliably fast, not just peak-fast:
- **Pre-warm on wake/launch:** run a 0.5s silent-audio inference through Parakeet at launch and after system wake (CoreML first-inference is the slow one); keep whisper-server resident with a periodic no-op ping; extend Ollama keep_alive touch to fire on hotkey-down (not first use).
- **Start-of-speech head-start:** begin streaming audio into the recognizer buffer on hotkey-DOWN instead of waiting for key-up, so transcription starts with audio already buffered (it mostly does — verify and close any gap in `AudioRecorder.swift`/`AppDelegate.swift`).
- **Latency HUD + log:** measure key-up→injection per take, log it, show p50/p95 on the Phase-8 Home tab. You can't keep what you don't measure.
- **Exit:** cold-launch first-take latency before/after numbers pasted (target: first take ≈ warm take); latency log line present on every take.

## Phase 10 — Beyond Wispr (differentiators, pick-and-choose)

Ordered by productivity value for this user specifically; each is independent:

1. **"Dictate to Claude" pipe (unique, high value):** a dedicated hotkey/pill-menu item that sends the transcript to a configurable shell command instead of injecting — default `claude -p "<text>"` or an HTTP POST to cc-orchestrator — and pastes/paths the response. Turns LocalFlow into a voice front-end for Claude Code sessions. Files: `Config.swift` (command template), `AppDelegate.swift` (new route), pill menu.
2. **Semantic history search:** History window gains a search field; v1 = plain substring over raw+cleaned (trivial); v2 = optional embedding index. Wispr's history has no good search. Do v1 only unless asked.
3. **Glossary import:** one-shot importers — macOS Contacts names, `git log` author names, and identifier harvest from a chosen repo (`ctags`-style regex over source) → glossary as bias terms. Kills the proper-noun error class Wispr solves with cloud context. New small `GlossaryImporter.swift` + Settings button.
4. **Voice snippets with slots:** extend `SnippetsEngine` so a snippet can contain `{cursor}`/`{clipboard}`/`{date}` placeholders filled at injection. Small.
5. **Meeting/long-form capture mode:** pill-menu "Capture mode" — continuous VAD-chunked transcription appended to a dated Scratchpad note (speaker-agnostic, local). Uses existing chunked path; mostly plumbing + a UI state. Medium.
6. **Redaction guard (privacy edge Wispr can't have):** local regex pass before injection into non-code apps for accidental secrets (ghp_/AKIA/sk-/JWT patterns) — warn in HUD instead of injecting silently. Tiny, and directly matches this user's history of pasted-secret incidents.
- **Exit per item:** unit test where logic is pure; USER-GATE for feel. Implement 1, 2(v1), 3, 6 by default; 4–5 only if time permits or user asks.

## Phase 11 — iOS companion (LocalFlow for iPhone) — separate milestone, do LAST

**Platform reality (do not fight it):** iOS has no system-wide text injection or global hotkeys. The Wispr-style mechanism is a **custom keyboard extension** with a mic button — that's the product. Ollama does not run on iPhone, so cleanup is (a) none, (b) Apple on-device Foundation Model / NL APIs where available, or (c) optional relay to the Mac over the local network. Requires an Apple Developer account ($99 — same USER-GATE as notarization) to run on a real device; simulator has no mic parity, so everything here ends in USER-GATEs.

**11a. Restructure for code sharing.** Extract platform-neutral core (Glossary, SnippetsEngine, cleanup guards/prompts, history model, language table, chunker) into a `LocalFlowCore` SwiftPM library target consumed by both the macOS app and the iOS targets. No behavior change on macOS.
- **Exit:** macOS app builds + `swift test` green against the extracted core.

**11b. iOS app + keyboard extension.**
- **App target:** hosts model download/management, Settings (language, cleanup level), History, Scratchpad, onboarding (mic + full-access permissions walkthrough).
- **Keyboard extension:** mic button → record → on-device transcribe → insert via `textDocumentProxy`. Engine: Parakeet CoreML runs on ANE on iPhone (same model as Mac) for English; whisper.cpp (small/base multilingual, Metal) for other languages — large-v3-turbo is too heavy for a keyboard extension's memory limit (~60MB is a known gotcha for extensions; if the model can't fit the extension, run recognition in the host app via App Group + open-app handoff, or use a smaller quantized whisper).
- Long-press mic = language quick-switch (recents, mirroring Phase 7).
- **Exit:** builds for iOS; extension inserts transcribed text in a test app on device. USER-GATE: real-device dictation feel + memory stability.

**11c. Mac↔iPhone sync (what makes it "useful for the phone").** Sync glossary, snippets, language recents, and Scratchpad via iCloud (CloudKit or iCloud KV/documents — pick the simplest that fits; KV store suffices for glossary/snippets JSON). History stays per-device by default (privacy).
- **Exit:** add a glossary term on Mac → appears on iPhone (log/screenshot proof both sides).

**11d. Phone-specific wins (small, high-value):**
- **Share extension:** share any text to LocalFlow → Improve Writing / append to Scratchpad.
- **Action button / Shortcuts integration:** an App Intent "Dictate to Scratchpad" (and optionally "Dictate to Claude" hitting cc-orchestrator over Tailscale/local network) bindable to the iPhone Action button.
- **Capture mode on phone:** record a meeting/voice note → chunked local transcription into a dated Scratchpad note, synced back to the Mac.
- **Exit per item:** works on device (USER-GATE).

Scope guard: 11 is a milestone, not a weekend. Ship 11a+11b first (a working local keyboard = the core value), then 11c, then 11d items in order. Do not start Phase 11 until Phases 0–9 are done and user-gated.

## Explicitly out of scope (don't build)

Android, team shared dictionaries/dashboards, Cursor file-tagging, true whispered-speech model. Apple Developer account purchase + notarization = USER-GATE (user decision; required for iOS device installs and Mac distribution).

## Done criteria for the whole plan

All phases built + unit-tested, state doc + TODO updated per phase, a final report listing every USER-GATE checklist outstanding, and `swift test` green. Estimated honest parity after Phases 0–6: engine ~95%, UI/UX ~70% of Wispr; Phases 7–10 take UI/UX to ~90% and add capabilities Wispr doesn't have (local privacy, Claude pipe, redaction guard, repo-aware glossary). Phase 11 (iOS) is a separate milestone gated on 0–9 being done and on the Apple Developer account.

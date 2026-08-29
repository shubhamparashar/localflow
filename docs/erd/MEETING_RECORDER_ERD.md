# Meeting Recorder v2 - ERD

## 1. Requirements (from user, 2026-08-29)

- R1: A meeting toggle available directly on the docked overlay pill's hover stack (4th button), not only in the right-click menu.
- R2: Recording covers the whole meeting: the user's mic AND the other participants (system audio).
- R3: Transcription happens in chunks DURING the meeting, never one giant pass at the end.
- R4: Sessions of at least 1 hour must work; target 3 hours.
- R5: After the meeting, produce meeting notes: what was talked about (summary, decisions, action items), generated locally.
- R6 (bug): dictation/capture chunks must stop getting random speaker-name prefixes.

## 2. Current state (verified in code)

| Requirement | Status | Where |
|---|---|---|
| R2 mic + system audio | DONE | `MeetingSession.swift` (mic via capture loop, system via `SystemAudioRecorder`) |
| R3 chunked live transcription | DONE | `MeetingAudioChunker` energy-based boundaries + capture-mode chunk loop |
| R4 long sessions | DONE by construction | chunks are transcribed and released; nothing accumulates but Scratchpad text |
| R1 pill button | MISSING | hover stack has globe/mic/notes only |
| R5 meeting notes | MISSING | `MeetingSession.finish()` just appends a closing line |
| R6 name bug | BUG | `AppDelegate.appendCaptureChunk` diarizes MIC chunks and prefixes profile names; mic is always the user |

## 3. Data flow (new parts)

1. Hover stack click on record button -> `onToggleMeeting` -> existing `toggleMeetingMode()`.
2. `MeetingSession.start()` remembers the Scratchpad offset where the meeting begins.
3. `MeetingSession.finish()` -> collect the meeting's transcript slice -> `MeetingNotesGenerator.generate(transcript)` -> Ollama `/api/chat` (general model, NOT s1-mini) -> append "## Meeting notes" section to Scratchpad.
4. Failure mode: Ollama down/timeout -> log + append "(notes unavailable)" line; transcript is already safe in the Scratchpad.

## 4. Code implementation map

- `OverlayHUD.swift`: 4th stack circle (SF `record.circle`, tooltip "Meeting notes", red tint while active) wired to `onToggleMeeting`.
- `MeetingSession.swift`: capture transcript segment during session; call notes generator in `finish()`.
- `MeetingNotesGenerator.swift` (new, ~60 lines): prompt build + Ollama chat call + response cleanup. Model from `Config.summaryModel` (default `llama3.2:3b`).
- `AppDelegate.swift`: `appendCaptureChunk` drops the diarize/name-prefix branch for mic chunks (fixes R6).
- `Config.swift`: `summaryModel` getter.

## 5. Use Cases

signed-off-by: shubham (requested via chat, 2026-08-29)

Happy:
- H1: Click record button -> meeting starts, chunks stream into Scratchpad labeled Me/Them.
- H2: Click again after N minutes -> closing line + generated notes section appended.
- H3: 1-3h meeting -> all chunks present, notes generated from full transcript.
Sad:
- S1: Ollama not running at meeting end -> transcript intact, "(notes unavailable)" appended, no crash.
- S2: System-audio permission missing -> mic-only notes (existing behavior), notes still generated.
- S3: Meeting with no speech -> no notes call (empty transcript guard).
Gibberish/edge:
- G1: Meeting shorter than one chunk -> closing line only, no notes section.
- G2: Notes model returns empty -> "(notes unavailable)".
- G3: Very long transcript (3h) -> prompt truncated to the model context (keep last ~24k chars, note the truncation in the prompt).

## 6. Testing

- Unit: `MeetingNotesGeneratorTests` - prompt building (truncation, empty guard), response cleanup.
- Unit: existing `MeetingModeTests` keep passing.
- Manual: live meeting smoke (start via pill, speak, stop, check notes).

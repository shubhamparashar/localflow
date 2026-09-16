# Meeting notebook

Open **Meeting Notebook…** from the LocalFlow menu, or open `localflow://meetings`.
Start a meeting from the notebook or the pill's meeting button. Type in **My notes**
while microphone and system-audio segments appear under **Transcript**. Stop waits
for final audio and transcription, then generates **Enhanced notes** locally with
Ollama. Generated bullets quote the source and are checked against it before saving;
this avoids fabricated prose from the small local model. You can edit either notes tab, regenerate, rename meetings, and switch among
saved meetings. The ordinary Scratchpad remains separate.

Each meeting is an atomic JSON file under
`~/Library/Application Support/LocalFlow/Meetings/`, containing the original notes,
enhanced notes, timestamped speaker segments, title, and start/end times. Edits and
new segments are saved immediately. Interrupted meetings reopen with their last
saved content. Save/load errors are shown; unreadable originals are retained.

Long transcripts are processed sequentially in bounded chunks, with rough notes
included as guidance. Results retain chronological part sections so no transcript
section is silently discarded. Repeated or evolving decisions across parts are
not globally reconciled yet. Source extraction can still omit or misclassify a
statement; review decisions and action items. A failed generation leaves existing enhanced notes
intact; changing raw notes while generation runs requires another enhancement.

## Verification

- `swift test`
- `swiftc Sources/LocalFlow/MeetingSession.swift scripts/meeting_lifecycle_smoke.swift -o /tmp/localflow-lifecycle-smoke && /tmp/localflow-lifecycle-smoke`
- Build with `CODESIGN_ID="LocalFlow Dev" ./scripts/make_app.sh`.
- Runtime: start a meeting, type notes, speak, stop, inspect both streams and enhanced
  notes, then restart and reopen it. Check a real headset call before relying on
  speaker attribution.

The notebook runtime was exercised with synthetic transcript segments and the real
local Ollama model. Save/reopen, typing, tab isolation, and generation were inspected
in the native AppKit UI. The capture drain also has a runnable asynchronous smoke
check. A real Meet/headset call remains a separate acceptance check.

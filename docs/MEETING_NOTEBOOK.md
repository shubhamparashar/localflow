# Meeting notebook

Open **Meeting Notebook…** from the LocalFlow menu, or open `localflow://meetings`.
Start a meeting from the notebook or the pill's meeting button. Type in **My notes**
while microphone and system-audio segments appear under **Transcript**. Stop waits
for final audio and transcription, then generates **Enhanced notes** locally with
Ollama. Local enhancement produces a quoted draft: selected transcript passages
under summary, decisions, and actions. The wording is copied from the transcript;
category assignments still need review. You can edit either notes tab,
regenerate, rename meetings, and switch among saved meetings. The ordinary Scratchpad remains separate.

Each meeting is an atomic JSON file under
`~/Library/Application Support/LocalFlow/Meetings/`, containing the original notes,
enhanced notes, timestamped speaker segments, title, and start/end times. Edits and
new segments are saved immediately. Interrupted meetings reopen with their last
saved content. Save/load errors are shown; unreadable originals are retained.

Long transcripts are processed in bounded batches. Their selected quotes are merged
into one result, rotating across batches so later discussion remains represented.
The final output allows at most six summary quotes, five decision quotes, and eight
action quotes. Repeated quotes and exact acknowledgements are omitted. These limits
do not establish that the model classified each quote correctly.

Exact sentence loops are removed from the summary input, and passages repeated
across microphone and system channels make speaker attribution uncertain. The
original transcript is preserved. A failed generation leaves existing enhanced
notes intact; changing raw notes while generation runs requires another enhancement.

Free-form prose generation and model-based verification were tested against a real
meeting with local 3B, 4B, and 9B models. The fast models introduced unsupported
commitments and citations; bounded reasoning runs exhausted their output budgets.
That experimental prose pipeline is not the shipped local default. Local quoted
drafts should not be treated as Granola-level meeting summaries.

Meeting microphone capture continues while completed windows are transcribed.
Windows end after a natural pause, with a 30-second maximum for both microphone
and system audio. Silence is filtered
using the existing adaptive speech threshold. Stopping drains emitted windows and
the final partial window before generating notes. Ordinary dictation retains its
existing silence endpointing. Meeting transcription does not use focused-field text
as a recognition prompt.

## Verification

- `swift test`
- `swiftc Sources/LocalFlow/MeetingSession.swift scripts/meeting_lifecycle_smoke.swift -o /tmp/localflow-lifecycle-smoke && /tmp/localflow-lifecycle-smoke`
- Build with `CODESIGN_ID="LocalFlow Dev" ./scripts/make_app.sh`.
- Runtime: start a meeting, type notes, speak, stop, inspect both streams and enhanced
  notes, then restart and reopen it. Check a real headset call before relying on
  speaker attribution.

The notebook runtime was exercised with synthetic transcript segments and the real
local Ollama model. Save/reopen, typing, tab isolation, and generation were inspected
in the native AppKit UI for the notebook milestone. The current production notebook
controller was also exercised against the real transcript in an isolated store:
end-meeting generation, overlap warning, save/reopen, and preservation of all 56 raw
entries passed. After restart, the final native UI check passed: the reviewed
meeting reopened with all 56 segments, a separate synthetic note saved and enhanced
through the UI, and the generated draft was persisted. The synthetic test still
misclassified a requested action as Summary; semantic grouping remains unresolved.
The final suite has 190 passing tests. The capture drain also has a runnable asynchronous smoke
check. A native 32-second microphone check verified pause-triggered emission while
recording continued, contiguous timestamps, and the final partial window with no
auto-stop or partial-caption callbacks. A real Meet/headset call remains a separate
acceptance check; acoustic echo cancellation has not been established.

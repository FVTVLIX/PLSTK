# Director can look before it edits

With Allow visual inspection enabled, Director can request timestamped footage samples, describe what appears in those samples, and reuse those notes during follow up requests. It can inspect ranges from any visual asset in your Library, rather than receiving only fixed samples from the first few files.

Director can also review rendered draft frames and propose one visual refinement. The app checks and renders the revised plan before showing it. You still choose Apply draft, and the entire result remains one undoable change. Progress identifies footage inspection, draft building, and layout review.

Visual sharing is optional. Without permission, no images or cached visual notes are sent. Notes stay in memory, are scoped to source identity and the chosen provider/model, and can be cleared from Director options or with New chat. Requests stop at six model calls, with bounded samples and refinement. The interface identifies incomplete reviews rather than claiming success.

All 111 tests pass. Native verification uses an isolated local fixture provider and synthetic footage to exercise source sampling, review, title refinement, cache clearing, undo, save, and MP4 export. These checks establish the workflow, not live model creative quality or a complete assessment of motion and sound.

Project format remains version 9. Transcription, deeper temporal understanding, and curated motion templates remain future work.

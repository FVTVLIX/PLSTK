# Changelog

## Unreleased

### Watch Director drafts before applying

Director proposals now include Watch draft, a separate local player for checking motion and sound before committing an edit. Native playback controls support seeking and listening volume. Back to editor returns to the proposal, while Apply draft commits the same single undoable change from either view.

Review leaves the original timeline, playhead, and undo history intact. Closing stops playback and cancels preparation; outdated results cannot replace a newer player. Unavailable media reports a retryable problem. No model calls, visual sharing permission, dependencies, or project format changes are required.

Four new tests cover picture and audio agreement with export, project isolation and undo, late preparation results, replacement races, and retry after missing media. Native verification covers playback, seeking, returning, applying, and undo.

### Director inspects footage and reviews its drafts

Director can request timestamped samples from specific source ranges anywhere in the visual Library. Short model observations are cached for follow up requests and scoped to the exact source and chosen provider/model. Changed or relinked media invalidates its notes. New chat and Forget visual notes clear the session cache.

Allow visual inspection controls both source sampling and model review of rendered drafts. The model can suggest one complete visual refinement, which is checked and rendered before presentation. Drafts identify whether the latest sampled layout review completed. Missing permission, invalid revisions, unavailable review, and exhausted budgets do not silently become successful visual checks.

Progress identifies footage inspection, draft building, and layout review. Requests allow at most six model calls, two source inspection rounds, six images per call, one validation correction, and one visual refinement. Metadata editing remains available without sharing images. Apply still commits one undoable edit.

Fifteen new tests bring the suite to 111 passing tests. Verification covers actual source colors and timestamps, later Library assets, strict tool messages, cache scope and invalidation, review revisions, repeated request limits, privacy opt out, cancellation, and atomic apply. A native local fixture check exercises inspection, review, refinement, cache clearing, undo, saving, and decoded export. Creative quality with a live model remains unverified. Project format remains version 9.

### Director with your chosen model

The assistant panel now prepares editable drafts through a user configured OpenAI compatible, Anthropic, or Ollama endpoint. Original design guidance offers Minimal, Editorial, and Energetic starting points. Optional reference frames give an image capable model sparse visual context without uploading original files or audio.

Drafts use bounded JSON operations against the current project. PLSTK validates a copied timeline, makes at most one correction request, renders local sample frames, and waits for Apply draft. Applying is one undoable change. Manual edits invalidate pending drafts. Stop cancels model and imported preview work.

Keys stay in macOS Keychain and configuration stays separate from project files. No Cardboard gateway, usage meter, subscription gate, proprietary code, artwork, or copied prompt is included. The new editing brief and CLI commands also support external assistants and checked plan import.

Twenty six new tests bring the suite to 96 passing tests. Coverage includes atomic plans, invalid operations, provider protocols, redirects, cancellation, bounded requests, context privacy, repair, local previews, conflicts, and undo. Native verification uses a local fixture provider and synthetic footage to check settings, prompt submission, optional images, review, apply, undo, saving, and decoded export. Live model creative quality remains unverified. Project format remains version 9.

### Visual fades and scene dissolves

Transitions now provides simple icon presets for visual Fade in, Fade out, and Dissolve from previous. Precise durations are available inside Fine tune. The panel follows the selected clip, and transitions also appear in the contextual clip toolbox.

Dissolves blend adjacent clips on the same track and move later clips on that track earlier by the overlap duration. Embedded sound blends with the scene change. Independent audio and other visual tracks stay in place. Visual fades alone leave sound unchanged. Remove a dissolve before changing its cut; splits outside the blend preserve the link.

Project format 9 stores fades and dissolve links, migrates earlier projects, and supports undo and recovery. Seven new tests bring the suite to 70 passing tests, including decoded preview and export comparisons for video, image layers, transparent titles, transforms, split fades, and sound blending.

### Easier navigation on longer timelines

Moving visual or audio clips and trimming visual clips now scrolls the timeline near its horizontal edges. Speed increases toward the edge, with extra working room as the draft moves beyond the current edit. Drag calculations include scroll distance so clips stay with the pointer.

Release still commits one edit. Escape, switching away from the app, hiding the timeline, and changing zoom cancel the current draft. Snapping, track placement, source limits, and collision validation remain part of the edit workflow.

Eight new tests cover navigation math and native scroll behavior, bringing the suite to 63 passing tests. Native component checks include nested SwiftUI scroll views, boundary clamping, cancellation, and starting a drag from an already scrolled viewport. Project format remains version 8.

### Editable text titles

Text now opens a visual preset panel with Simple, Statement, and Caption styles. Add a title above your footage, enter the wording, choose a color, and place it with Top, Centre, or Bottom. Edit text is also available in the viewer. Selection handles surround the title itself, while Fine tune contains exact size and alignment.

Titles use the existing visual timeline controls for duration, placement, opacity, split, duplicate, and undo. Split parts and duplicates can be edited independently. Project format 8 stores the text and style directly, supports recovery, and opens earlier projects with migration defaults. Older app versions cannot open the new format.

Shared native text rendering keeps preview and export consistent without adding a font or image dependency. Seven new tests bring the suite to 55 passing tests. Coverage includes transparent overlays, title timing, transforms, save and recovery, validation, migration, and independent editing.

### Automatic project recovery

Unsaved edits now get a separate local recovery copy after a brief pause and when PLSTK moves into the background. After an unexpected quit, a simple prompt offers Recover, Not Now, or Discard Copy. Deferred copies remain available from the File menu.

Recovered edits ask for a new save destination, keeping the original project unchanged. Saving, discarding edits, or successfully changing projects clears the current working copy. Recovery protects active editor sessions and retains unreadable copies for inspection. A small warning appears if recovery cannot be updated.

Seven new tests cover recovery persistence, active sessions, deferred copies, invalid data, missing media, and private file permissions. All 48 tests pass. Native checks verify an unexpected quit, recovery prompt, deferral, restoration, and saving a recovered edit.

### First public development checkpoint

PLSTK now has a native macOS editing workspace with a media Library, layered visual tracks, two independent audio lanes, local preview, and MP4 export.

The clip toolbox presents icons, presets, and sliders for everyday edits. Fine tune opens exact values for the selected option, while Back to Library makes it easy to return to browsing.

Viewer handles support position, proportional resize, and rotation. Visual clips support opacity and transparent image overlays. Audio clips support volume, mute, and fades that remain continuous across splits.

This checkpoint adds the GNU GPL version 3 license, public project documentation, a repository privacy review, contribution guidance, and a starting brief for the visual identity.

The existing 41 tests and rendering verification cover the current editing and media pipeline. This remains a development version with separately installed media tools.

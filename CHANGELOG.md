# Changelog

## Unreleased

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

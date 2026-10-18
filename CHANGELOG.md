# Changelog

## Unreleased

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

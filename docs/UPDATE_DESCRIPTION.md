# Keep your edit after an unexpected quit

PLSTK now keeps a local recovery copy while you work. If the app closes unexpectedly, you can recover your edit the next time it opens. Choose Not Now to return to it later through the File menu, or discard a copy you no longer need.

Recovery opens your edit as an unsaved project and asks where to save it. Your original saved project stays unchanged. Existing save backups, media relinking, and regular save prompts continue to work alongside recovery.

The recovery workflow stays out of the way during normal editing. A warning appears only if the copy cannot be updated. Copies belonging to another open editor are protected, and unreadable copies stay on disk for inspection.

This update includes seven new recovery tests, with all 48 tests passing. Native checks cover an unexpected quit, the recovery prompt, returning to a deferred copy, restoring an edit, and saving it as a project.

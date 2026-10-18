# Development

PLSTK should make ordinary editing feel approachable while keeping precise controls available when needed.

## Working on a change

1. Keep the change focused on one meaningful improvement.
2. Use synthetic media for development and verification.
3. Run checks appropriate to the change. Media behavior needs preview and export comparisons, while desktop interactions need native UI verification.
4. Review the diff and the staged file list before committing.
5. Make a commit after each completed major update. Give it a clear title and a short description of the behavior, reason, and verification.
6. Summarize user facing changes in CHANGELOG.md. Prepare the update description from the completed behavior rather than the conversation history.

Use plain language in public writing. Avoid hyphenated prose, decorative separators, and lists introduced with dash characters. Keep exact command names, URLs, and license identifiers intact where their syntax requires punctuation.

## Privacy and repository contents

The ignore rules exclude build products, generated media, projects, personal configuration, signing material, and local reference archives. Historical development notes stay local. Public documents and screenshots under `docs` must be explicitly reviewed and allowed in `.gitignore`.

An ignore file does not inspect file contents and cannot remove material from existing history. Review new files and commit metadata as well. Use a GitHub noreply address for public commits.

Never commit credentials, personal footage, third party extracted code, original third party application screenshots, or local investigation archives. Do not add real secrets to configuration examples.

## Contributions and licensing

Contribute only material you have the right to distribute under this project's license. Describe substantial changes clearly, preserve required notices, and include the relevant verification results.

The project currently has no external Swift package dependencies. Changes that introduce dependencies should document their license and distribution requirements in THIRD_PARTY_NOTICES.md.

## Source layout

`LocalVideoCore` owns project data, validation, media probing, composition preview, and export.

`LocalVideoEditor` owns the native interface and editor state.

`LocalVideoCLI` exposes the current command line operations using the same core.

Avoid creating a separate rendering interpretation in the interface. The preview and export should describe the same edit.

## Recovery verification

Recovery copies contain project data and local media paths. Keep them private. The native editor supports `PLSTK_RECOVERY_DIRECTORY` for testing with a separate local folder. Use an absolute path to a disposable folder when simulating an unexpected quit. The normal location is the PLSTK Recovery folder within the current user's Application Support directory.

Exercise recovery with synthetic projects. Verify that the original project bytes remain unchanged, that Not Now preserves the copy, that another running editor cannot consume it, and that saving or explicitly discarding an edit clears its working copy. Writes use a serial queue, a short editing delay, and atomic file replacement. Do not let a pending write recreate a cleared copy.

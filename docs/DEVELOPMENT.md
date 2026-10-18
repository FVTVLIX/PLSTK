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

## Title rendering

Editable titles live in the project as generated visual assets. They have no external media path. Core Text supplies the same transparent raster to the still preview proxy and FFmpeg preparation. Preserve that shared layout when adding typography controls.

A title edit must not change another split part or duplicate. Copy the generated source when more than one clip uses it. Include title content in thumbnail cache identity, preserve embedded data in recovery copies, and exclude generated assets from missing media and relink workflows. Verify decoded preview and export frames across title boundaries and visual transforms.

## Timeline navigation verification

Timeline gestures use a stationary viewport coordinate space. Add the scroll offset change exactly once when calculating movement or trim distance. Keep the project unchanged during a draft, then commit through the normal edit operation on release. Cancelled gestures must not restart while the same pointer gesture remains active.

The editor tests exercise native NSScrollView behavior and an isolated SwiftUI hierarchy with nested horizontal and vertical scroll views. Coverage includes scrolling bounds, progressive speed, elapsed time limits, cancellation, and starting a drag after scrolling. The app check also verifies ordinary scrolling and zoom through accessibility controls.

Physical pointer drag automation on the current verification display reports `windowNotFoundAtPosition`. The release checks therefore distinguish native component tests from a completed physical edge drag. Recheck visual move, trim, and audio move with a pointer when a compatible display is available.

## Visual transition rendering

Visual fades use source anchored envelopes so splitting a fade preserves its original shape. A dissolve belongs to the incoming clip and identifies its predecessor. Validation permits only the declared overlap on the same track and rejects overlapping blends that would involve three clips. Dissolve edits shift later clips on that track by the duration change. Moving or trimming a linked cut requires removing the dissolve first.

Preview projects with transitions use a Core Image video compositor. Apply envelope gain to alpha once, sum premultiplied source pixels within each track, then composite the tracks. Fading two independent layers over each other produces a dark dip. Core Image color matrix filters operate on unpremultiplied values, so multiplying color and alpha together applies the gain twice. The context uses an explicit sRGB working and output space.

FFmpeg export applies the same envelopes. For dissolves it prepares canvas sized premultiplied streams, adds them within a track, and composites tracks over black. Embedded audio uses complementary linear ramps. Visual fades alone do not affect sound. Independent audio keeps its existing placement and envelope.

Verify decoded frames at transition boundaries and midpoints, across split fades, and with layered images, transparent titles, opacity, and transforms. Check sound against an AVFoundation audio mix export, and exercise save, migration, recovery, and invalid linked edits. Format 9 requires migration defaults for older projects. Export with dissolves prepares full duration streams for each visual clip; performance on large projects remains an area for improvement.

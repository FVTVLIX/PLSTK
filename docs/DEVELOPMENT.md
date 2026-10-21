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

## Director contracts and providers

Keep project mutation independent of model providers. DirectorPlan is a bounded JSON contract interpreted against a copied VideoProject. Preserve stable identifiers, source versus timeline time, source limits, linked transitions, title independence, and atomic failure. Empty plans must leave even implicit legacy positions unchanged. The app checks the original project before applying the prepared candidate through one normal undo operation.

DirectorContext exposes a path free projection of assets and timing. Treat media names, project titles, previous responses, and images as untrusted data. Optional images are sparse samples, not temporal analysis. Original style instructions describe only supported capabilities. The provider bridge accepts a selected endpoint and model, rejects redirects, bounds input and output, cancels underlying transfers, and sanitizes errors.

Credentials belong to the app Keychain namespace and exact endpoint. Never serialize them into project data or preferences. Keep live provider tests distinct from protocol fixtures. Use isolated preferences, an in memory secret store, and a disposable recovery directory in editor tests. A local fixture endpoint can verify native submission and preview without transmitting footage externally or consuming paid usage.

The CLI exposes context, instructions, dry checks, and revision guarded file application. Do not claim that it automatically synchronizes an already open editor. Draft frame samples verify only selected instants, so play through motion and sound separately. See DIRECTOR.md for current capabilities and limitations.

DirectorDraftPlayer builds a separate TimelinePreview and AVPlayer for a pending proposal. Keep its player, seek position, listening volume, and lifetime independent of EditorStore. Closing must cancel preparation, detach the item, and stop sound. Generation checks reject late results even when a builder does not cooperate with cancellation. Replaced or invalidated draft identities close the review. Applying still goes through DirectorController's current project guard and normal undo path.

Verify draft picture and audio against export using synthetic footage, then check native playback, seeking, Space, Back to editor, Escape, Apply, and Undo. Review must remain available for imported plans without a provider connection or visual sharing. Playback errors must leave the proposal available for retry or dismissal.

## Inspection and visual review verification

DirectorStep accepts either a standard edit plan or bounded source inspection requests, with optional observations referencing only the exact source frames supplied. Reject unknown fields, invalid assets, out of range times, excessive samples, and invented observation references before decoding or caching. Distinguish source images from draft timeline images throughout the prompts and validation.

DirectorSceneCache is bounded in memory and keyed by source identity, asset identifier, exact endpoint, provider kind, model, and sampled frames. Check file identity before accepting observations and when reusing them. Never serialize this cache into project files, preferences, or logs. Reusing a note does not turn sparse visual evidence into temporal scene analysis. Disabled sharing must omit both images and cached notes from new model input.

The controller bounds the entire loop to six model calls, two inspection rounds, one validation repair, and one visual revision. Review replacements apply to the original project, not the previous draft. Validate and render them again. Do not attach a completed review to a revision that has not received acceptance. Preserve a checked draft when model review is unavailable, and surface the missing check. Cancellation and project changes must prevent later requests and stale draft publication.

Use synthetic media with distinct source ranges to verify decoded colors and timestamp labels. Exercise a later Library asset, cache reuse and invalidation, opt out, repeated tool requests, invalid visual revisions, refinement limits, and Stop. Native fixture checks should distinguish source sample requests from draft frame review, then exercise Apply, Undo, saving, and decoded export. Keep live model quality evaluation separate from protocol fixtures.

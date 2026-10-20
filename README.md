# PLSTK

A native video editor for macOS with prompt based editing, your choice of model, and a visual timeline you can adjust yourself.

PLSTK is pronounced like plastic. Bring in your footage, describe the edit you want, and review a proposal before applying it. You can also build an edit manually with icons, presets, and viewer handles. Exact settings stay inside contextual Fine tune controls.

PLSTK does not require an account or subscription, add watermarks, or impose export quotas. Preview and export run on your Mac. Director connects directly to the model endpoint you choose. Cloud providers may charge for usage; local models require suitable hardware.

## Project status

PLSTK is an early development version with a working editor and Director workflow. Model protocol tests and a local test provider verify the integration. Creative quality and compatibility with individual live models still need broader evaluation.

Build the app from source using the instructions below. FFmpeg and ffprobe must be installed separately. The development build uses an ad hoc signature and is not a signed and notarized public release. Development and testing currently take place on Apple silicon; Intel support has not been verified.

## Get started

### Requirements

1. macOS 14 or newer.
2. Xcode with Swift 6 or newer and an active command line toolchain.
3. FFmpeg and ffprobe with libx264 and AAC support.
4. Python 3 for the optional rendering smoke test.

No external Swift package dependencies are required. A model connection is optional for manual editing.

### Build and open

With Homebrew already installed:

```sh
brew install ffmpeg
git clone https://github.com/FVTVLIX/PLSTK.git
cd PLSTK
bash scripts/build-app.sh
open "Build/PLSTK.app"
```

See [Building PLSTK](docs/BUILDING.md) for build configurations and verification requirements.

### Make your first edit

1. Import footage with ⌘I. Files appear in the Library without being inserted automatically.
2. Preview an asset and choose Add to timeline, or let Director propose an arrangement using your imported assets.
3. To use Director, choose your model in the assistant panel. Enter the connection type, base URL, model identifier, and API key where required.
4. Describe a concrete change, such as adding a simple opening title or softening scene changes. Choose Prepare draft, inspect the proposal and preview samples, then Apply draft or Discard.
5. Adjust the result on the timeline or with the clip toolbox. Each applied draft is one undoable edit.
6. Save with ⌘S and export an MP4 with ⌘E.

## Director

Director supports OpenAI compatible providers, Anthropic, and local Ollama through its compatible `/v1` endpoint. Use a model that supports JSON responses. Sharing images also requires an image capable model.

Choose Minimal, Editorial, or Energetic as a starting direction. These guide the model's use of existing editing tools. Director can arrange source ranges, trim and split footage, add and update titles, adjust transforms and opacity, set fades and dissolves, work with independent audio, and change the canvas.

Follow up requests receive the current timeline and recent conversation. PLSTK checks proposed operations against a copied project and may request one correction if validation fails. A draft provides locally rendered samples from its beginning, middle, and end when preview preparation succeeds. Apply commits the result as one undoable change. Manual edits invalidate older drafts, and Stop cancels ongoing model or preview work.

Director options also includes Copy editing brief and Import edit plan. These let another assistant prepare a JSON proposal that PLSTK can check and preview without an integrated model connection.

See [Director setup and capabilities](docs/DIRECTOR.md) for the full workflow, supported operations, and CLI commands.

### Privacy and model costs

A Director request includes project and media names, title text, media metadata, timeline timing, selection, playhead, and recent conversation. Asset file paths, original media files, and source audio are excluded.

Share sample frames is off by default. Enabling it sends up to six small images from the first three visual assets. These are sparse samples, not a complete analysis of the footage.

API keys stay in macOS Keychain, separate from project files and app preferences. Model configuration is stored in app preferences. Conversation and pending drafts stay in memory; applied edits become normal project content. Copy editing brief places project information on the clipboard for you to share deliberately.

Requests go to your configured endpoint without a PLSTK hosted gateway. Cloud charges belong to the chosen provider. A chat subscription does not automatically provide an API key or API allowance. PLSTK does not silently switch providers.

## The editing workspace

### Timeline and visual controls

Import video, audio, PNG images, and JPEG images. The timeline supports up to 32 visual tracks and two independent audio lanes. Higher visual layers appear above lower ones. Clips can leave gaps, and audio can extend beyond the picture.

Move, trim, split, duplicate, and remove visual clips. Independent audio clips support placement, precise source trimming, splitting, and removal. Editing actions support undo and redo.

Moving clips or trimming visual edges near the horizontal viewport edges scrolls the timeline. Release commits the draft, while Escape cancels it. Snapping and source limits continue to apply.

Select a clip to open its toolbox. Use Size & position, Rotate, Opacity, Transitions, Trim & split, Sound, and Arrange as appropriate for the media. Drag in the viewer to reposition a visual, pull a corner to resize it, or use its rotation handle. Presets provide quick starting points, and Fine tune contains exact values. Back to Library returns to browsing.

Transparent PNG images and opacity support logos, overlays, and layered compositions. Still images also have duration presets.

### Editable titles

Open Text and choose Simple, Statement, or Caption. A five second title appears at the playhead above overlapping visual layers. Enter your words, choose a color, and place the title with Top, Centre, or Bottom. Edit text is also available in the viewer.

Titles are stored inside the project and support duration changes, transforms, opacity, fades, split, and duplicate. Split parts and duplicates can be edited independently. Typography uses system fonts, three color choices, and up to eight lines, with wrapping and size adjustment for longer text.

Caption is a manual title style with a contrasting plate. It does not transcribe speech or generate timed captions.

### Fades, dissolves, and sound

Visual Fade in and Fade out work with footage, images, and titles. Choose Off, Short, Medium, or Long, or enter exact durations inside Fine tune.

For a dissolve, place two clips next to each other on the same visual track. Select the second and choose Dissolve from previous. The clips overlap and blend their picture and embedded sound. Following clips on that track move earlier; other tracks and independent audio stay in place. Removing the dissolve restores the space.

Remove a dissolve before moving or trimming its cut. Splits outside the blend preserve the link. Visual fades alone leave sound unchanged, and fades stay continuous when split.

Independent audio clips support volume, mute, fade in, and fade out through presets, sliders, timeline handles, and exact duration controls. Two lanes allow overlapping music, voice, or opposing fades.

### Preview and export

Timeline playback uses a local AVFoundation composition. Seek with the ruler, step through frames, and check placement in the viewer. Playback > Render Preview provides a local FFmpeg fallback when live preview is unavailable.

Export produces an opaque MP4 with H.264 video and AAC audio at 30 frames per second. Canvas choices include landscape, portrait, and square, with landscape output sizes up to 4K. Export uses FFmpeg and preserves an existing destination if the job fails or is cancelled. Source assets cannot be overwritten by export.

## Projects and recovery

Projects use the `.localvideo` extension and store edits rather than copies of your media. Paths are relative when an asset is beneath the project folder and absolute otherwise. Keep source files available, or use Relink media in the Library if they move.

Saving an existing project keeps its previous saved contents as a backup. PLSTK prompts before discarding unsaved edits and keeps a separate local recovery copy after a brief editing pause and when the app moves into the background.

After an unexpected quit, Recover restores the edit, Not Now defers it, and Discard Copy removes it. File > Recover Unsaved Edit reopens deferred copies. Recovered projects ask for a new save destination to protect the original file. Recovery does not restore undo history or replace regular saving, and the latest changes may not have reached the recovery copy before a crash.

The current project format is version 9. Earlier versions open with migration defaults. Older app versions may not open projects saved by this version.

## Keyboard shortcuts

| Action | Shortcut |
| :--- | :--- |
| Import media | ⌘I |
| Open a project | ⌘O |
| Save | ⌘S |
| Export | ⌘E |
| Undo | ⌘Z |
| Redo | ⇧⌘Z |
| Play or pause | Space |
| Step through frames | Left or Right |
| Jump to the beginning or end | ⌘Left or ⌘Right |
| Split at the playhead | B |
| Toggle snapping | S |
| Mute the selected clip | M |
| Duplicate a visual clip | ⌘D |
| Toggle the left panel | [ |
| Toggle Director | ] |
| Toggle the timeline | Backslash |

## Current limits

Director does not transcribe speech, identify the best moments across complete footage, generate media, or autonomously judge a finished video. Preview samples cover selected instants. Play through the edit to assess motion, pacing, and sound.

Automatic captions, keyframes, advanced effects, motion templates, beat detection, audio ducking, and loudness normalization are not implemented. The Captions and Effects interface entries remain disabled. Audio fades use linear amplitude curves.

The rendering workflow targets SDR. Full HDR and color management, every codec combination, and all variable frame rate inputs have not been verified. macOS codec support determines what can play in live preview.

Only one timeline clip can be selected at a time. Vertical scrolling during a track drag, persistent media caches, bundled media tools, and a signed and notarized installer are not available yet.

## Development and verification

The desktop app and CLI share the project model, editing validation, and renderer. Source is organized into `Sources/LocalVideoCore`, `Sources/LocalVideoEditor`, and `Sources/LocalVideoCLI`.

Run verification in a macOS desktop session with the required media tools installed:

```sh
swift test
python3 scripts/smoke-test.py
```

The current suite contains 96 tests covering editing, project migration, persistence, recovery, native components, preview and export comparisons, Director plans, provider protocols, cancellation, conflicts, and undo. Provider fixtures and native checks with a local test provider verify the request and editing workflow without establishing live model creative quality.

The smoke test creates synthetic footage under `TestOutput/` and checks timing, cut boundaries, silent clips, delayed audio, rotation, variable frame rate handling, and export cancellation. Generated media, local projects, credentials, and private reference material are excluded from Git.

See [Development](docs/DEVELOPMENT.md) for contribution and verification guidance, [the changelog](CHANGELOG.md) for updates, and [the latest update description](docs/UPDATE_DESCRIPTION.md) for the current milestone.

## Design and contributions

App icon concepts, a wordmark, and presentation assets are welcome. The [brand direction](docs/BRAND_DIRECTION.md) describes the starting ideas.

For bugs, include your macOS version, reproduction steps, and the expected behavior. Use synthetic or anonymized media where possible, and keep private projects, credentials, and personal file paths out of public issues.

For larger changes, open an issue to agree on scope. Keep everyday editing approachable, preserve contextual access to precise settings, and verify the result in preview and export.

## License

PLSTK is licensed under the GNU General Public License, version 3 only. You may use, modify, and redistribute it under those terms. Distributed modifications must meet the license requirements, including the applicable source availability obligations.

Read [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT), and [third party notices](THIRD_PARTY_NOTICES.md). External media tools and operating system resources retain their own licensing terms.

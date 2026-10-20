# Director

Director turns a request into an editable proposal for the current project. It connects directly to the model endpoint you choose. PLSTK does not require an account, subscription, hosted gateway, or editing credits.

This is an early implementation. The editing workflow is functional, while creative quality depends on the selected model and the information supplied to it. Provider protocol tests use fixtures. A local test provider verifies the native workflow without making paid model requests. Those checks do not establish the quality or compatibility of every live model.

## Get started

1. Open a project or import footage.
2. Choose your model in the Director panel.
3. Select OpenAI compatible, Anthropic, or Ollama. Enter the provider base URL, model identifier, and an API key where required. The model must support JSON responses. Ollama uses its compatible `/v1` endpoint.
4. Choose Minimal, Editorial, or Energetic as a starting direction.
5. Describe the edit and choose Prepare draft.
6. Review the explanation, sampled preview frames, and any warnings. Apply draft commits the proposal as one undoable edit. Discard leaves the timeline unchanged.

Follow up requests receive the current timeline and recent conversation. With Allow visual inspection enabled, the model may request specific source ranges before preparing a plan. It can then review locally rendered draft samples and propose one replacement plan. The refined result is rendered again before presentation.

The whole request uses at most six model calls, with at most two source inspection rounds, one validation correction, and one visual refinement. If the budget cannot accommodate a final review, the proposal says that its latest visual review is incomplete. Stop cancels ongoing work. Changing the project invalidates the draft so it cannot overwrite newer manual edits.

## Privacy and costs

The default request includes project and media names, editable title text, media metadata, timeline timing, selection, playhead, and recent conversation. Asset file paths and original media files are excluded from the model context.

Allow visual inspection is off by default. Enabling it allows timestamped source samples from any requested visual asset and rendered draft images to reach the selected model. Each source inspection round requests at most six samples, and each model call receives at most six small JPEG images. No original media files or source audio are sent. Choose a model that supports images before enabling this option.

The model can request a source range and sample count. Samples span that range, while a single sample uses its midpoint. Still images yield their one source image. Labels distinguish source times from draft timeline times. The model can return short descriptions grounded in the exact source samples it received. PLSTK rejects notes referencing samples that were not supplied. Sparse observations do not establish continuous motion or complete scene content.

These model generated notes can be reused in later requests without sending the same images again. The bounded session cache is private and tied to source file identity, asset identifier, exact provider endpoint, and model. Changes to a source or relinking invalidate its notes. Disabling visual sharing excludes cached notes from new model input. Forget visual notes clears the cache; New chat also clears it. Notes are never written to a project or a persistent media index.

Keys are stored in macOS Keychain, scoped to the app and exact endpoint. They are not saved in project files, preferences, chat history, or logs. Model configuration is stored separately in app preferences. Requests reject redirects, use HTTPS for remote endpoints, and permit HTTP only for exact loopback hosts.

Cloud usage is billed by the chosen provider. A chat subscription does not automatically supply an API key or API allowance. Local inference can avoid cloud usage charges but requires suitable hardware and a capable installed model. PLSTK does not silently switch providers.

Conversation, pending drafts, and visual notes stay in memory and are cleared by New chat or closing the app. Applied edits become normal project content and participate in saving and recovery.

## Current capabilities

Director can add and arrange source ranges, trim and split visuals, remove clips, adjust transforms and opacity, set visual fades and dissolves, create and update editable titles, arrange independent audio, adjust volume and audio fades, choose canvas dimensions, and rename the project.

Plans target stable identifiers and use integral frames at 30 fps. PLSTK checks all operations on a copied project before publishing the result. The contract rejects unsupported operations, unexpected fields, invalid source ranges, unknown identifiers, collisions, and oversized requests. It cannot execute code, read arbitrary files, fetch media, or publish an export.

The original style instructions encourage clear typography, purposeful pacing, and restrained transitions. They are guidance for existing features, not additional rendering effects. Current limitations include no transcription, semantic scene search, beat detection, automatic audio ducking, motion templates, keyframes, generated media, or complete temporal scene understanding. Sparse images do not establish motion quality or speech content.

A checked draft provides samples from the beginning, middle, and end of its actual local composition. With visual permission, those frames and the checked plan go to the model for composition and readability feedback. The model can accept the draft or propose one complete replacement plan against the original project. PLSTK validates and renders that replacement before a final review, subject to the request budget. Nothing is committed until Apply draft.

The draft card distinguishes a completed sampled layout review from an incomplete review or a local preview alone. An invalid revision preserves the previous checked draft and shows a warning. Repeated refinement suggestions stop at the limit. Play through the applied edit to assess motion and sound. If preview or model review fails, a warning identifies the missing check rather than claiming visual verification.

## Use another assistant without an integrated connection

Director options includes Copy editing brief. It copies PLSTK's original instructions, edit contract, and current context. Add your request in an assistant of your choice and save its JSON plan. Import edit plan checks and previews the result through the same workflow.

Copying the brief writes project information to the clipboard. Sharing it with an external assistant is a separate action you control. Import evaluates the plan against the current project; it cannot prove which snapshot an external assistant used. Review the proposal before applying it.

Developers can use the local CLI:

```sh
.build/debug/local-video director-context edit.localvideo
.build/debug/local-video director-contract
.build/debug/local-video check-plan edit.localvideo draft.director-plan.json
.build/debug/local-video apply-plan edit.localvideo draft.director-plan.json EXPECTED_REVISION
```

Use the revision returned by director-context or check-plan. Applying to a changed project is rejected. The command saves the project file and preserves its previous contents as a backup. It does not update an already open editor automatically; use Import edit plan for that workflow.

## Architecture and reference work

The design follows a useful separation observed during static artifact research: read the project, propose targeted changes, check, apply, inspect, and undo. PLSTK implements that workflow around its own Swift project model and renderer.

The project contains independently written editing operations, provider adapters, prompts, and interface code. Proprietary package contents, prompt excerpts, original artwork, hosted gateway behavior, billing, and entitlement logic remain outside the public repository. Artifact observations describe the inspected version and do not establish complete runtime behavior or server implementation.

The next development work should test supported live models on real editing tasks, add transcription and richer temporal understanding, and expand the renderer with curated motion and design templates.

# cmux-next UI preview loop

Preview work as soon as a surface changes. Keep the fast local loop separate from
the hosted evidence loop: local HMR answers “does this feel right?”, while a
branch or native capture answers “what did this exact revision render?”

## Choose the fastest useful lane

| Lane | Typical feedback | Use it for | Where it runs |
| --- | --- | --- | --- |
| Local web HMR | about one second after a save | React/webview layout, copy, states, and interaction | Developer checkout; Vite on `127.0.0.1` |
| Live gallery | while the pushed branch builds, usually 1–2 minutes | Real components and fixture states, including before/after comparison | Gallery host and remote browser |
| Hosted matrix | after the manifest is rendered | Repeatable screenshots, themes, locales, and play-step measurements | Freestyle, Testbox, or CI; never a laptop browser |
| Hosted native capture | one batched fleet run | AppKit/sidebar, native settings, and end-to-end behavior | Managed capture mini |

Start with the first lane that can answer the question. Move up only when the
change crosses that lane's boundary. A native sidebar change can use the web
gallery for nearby web surfaces, but its final visual evidence must come from a
hosted native capture.

## Local web HMR

From the checkout, start the development surfaces once and keep the printed index
open in a cmux browser tab:

```sh
scripts/cmux-next/web-dev.sh
```

Open `INDEX_URL`. It links to the real agent pane, pane preview, diff, Markdown,
editor, Settings, and (when the checkout has the gallery Vite config) `/gallery/`.
Vite watches `webviews/`; a normal edit appears in the open tab in about one
second. The launcher binds its listeners to `127.0.0.1` and supports the
`CMUX_WEB_DEV_*_PORT` overrides described in [cmux-next-web-dev.md](cmux-next-web-dev.md).

Use the real page or component and its fixture entry. Do not build a screenshot
shell that imitates the product. Gallery fixtures must be public-safe and should
exercise the state an agent or developer needs to inspect. Use the gallery
`play` steps for repeatable hover, keyboard, pointer, and drag states; the shell
can replay them before a review.

This lane is intentionally local and interactive. It does not prove a pushed
revision, a native AppKit surface, or a production bundle. An agent may read the
index and gallery state, but automation should not steal the developer's focus.
Open a browser tab only with an explicit `--open` or a user action.

## Branch gallery and before/after review

Once the branch has a pushed commit, use the repository's compare helper:

```sh
scripts/gallery-compare.sh --open --entry agent-pane.composer
```

The helper requires the local `HEAD` to match its upstream branch. It asks the
gallery host to build the branch and its merge base, then prints a tailnet URL
that fills in as the states become available. The `--entry` value is a substring
filter; omit it to inspect every state reached by the change. This is the useful
branch-level loop for an agent: the URL is reviewable, the two revisions are
side by side, and no Swift build or developer-laptop browser run is needed.

For a matrix or a new entry, follow [Adding gallery entries](../webviews/src/gallery/ENTRIES.md).
Generate and dry-run a manifest locally, then render it remotely with
`--freestyle-vms N` or the CI equivalent. Pick `N` from available free RAM. The
matrix report includes the entry, variant, source path, play-step measurements,
and the rendered revision; retain that report with the review artifact.

## Native AppKit evidence

Native builds and captures run on the managed fleet. Do not run `swift build`,
`swift test`, `xcodebuild`, or a native capture on the developer Mac. Batch all
states for one revision into one tagged app launch through the repository's
fleet helper, then wait for the exact-head receipt.

The normal PR evidence command is:

```sh
cmux-ci capture <head-sha> --state scene:<name> --pr <number>
```

`<name>` must be a registered native scene. The command returns the capture
metadata and Markdown for the light and dark stills. If the surface has no scene
yet, add the scene through the native gallery/capture owner before asking for a
capture; do not substitute a mocked browser frame. Use the repository's existing
test artifact path for offscreen drawing checks when that is the appropriate
question. For example, `WorkspaceRowCloseNotchGalleryTests` writes the
`close-notch-gallery` PNG set and tar archive only when the fleet sets
`CMUX_TEST_REQUIRE_GUI=1`.

## Sidebar close-notch example

The close-notch work is a good **native** preview matrix because it has a tunable
visual choice and input semantics. Inspect these states together:

* every `SidebarCloseNotch` look;
* hovered and selected-hovered rows;
* Soft Blue light and dark themes;
* the long workspace title that reaches the row's trailing inset;
* press and release inside the drawn cut;
* press in the cut and release back on the row fill, which must not close.

The source of truth is the real sidebar code and tests, including
`Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/WorkspaceRowCloseNotchGalleryTests.swift`
and `WorkspaceRowDogEarTests.swift`. The offscreen gallery gives a visual matrix;
the dog-ear tests cover geometry and hit testing. A native scene should reuse
the same fixtures and expose a stable scene id before it is used in a PR capture.
Until that scene is registered, use the hosted `WorkspaceRowCloseNotchGalleryTests`
artifact when a fleet runner is configured for the suite; do not pass
`sidebar.closeNotch` to the web gallery wrapper, because it is a native tunable
rather than a web gallery entry.

## Agent-friendly wrapper

Use the checked-in wrapper for the repeatable local and branch-gallery loop:

```sh
# Start or describe the local HMR surfaces.
scripts/cmux-next/preview.sh web --json

# Open a local HMR gallery entry without changing focus unless --open is given.
scripts/cmux-next/preview.sh gallery --entry agent-pane.composer --open --json

# For a pushed branch, compare against its merge base.
scripts/cmux-next/preview.sh gallery --compare --entry agent-pane.composer --open --json

# Print the current preview record without opening a tab.
scripts/cmux-next/preview.sh status --json
```

The wrapper owns `web`, `gallery`, and `status`; native capture remains an
explicit managed-fleet operation:

```sh
cmux-ci capture "$HEAD_SHA" --state scene:<registered-name> --pr "$PR_NUMBER"
```

The agent contract is deliberately small:

* `--json` emits one machine-readable record with `mode`, `repo`, `branch`, `sha`,
  `worktree_dirty`, `index_url`, `gallery_url`, `entry`, `pid`, `log`, `reused`,
  `opened`, and `phase`;
* human output includes the same key provenance, and the final URL or artifact
  link is easy to extract;
* success means the local process is reachable or the compare helper accepted
  the request; it does not mean a hosted gallery build or native capture is
  complete;
* `--open` is opt-in. Without it, the command prints records and never changes
  focus, selection, scroll, or the active cmux tab;
* repeated `web` and `gallery` calls reuse the task-local process when the repo
  and SHA still match. A changed SHA stops the old managed process before
  starting a new one, instead of silently reusing old preview proof;
* concurrent starts for the same checkout fail fast with the recorded owner
  process id; retry after that command finishes rather than starting a second
  Vite session;
* failures identify the owning lane and the next command, with a non-zero exit
  status. No polling loop or duplicate fleet dispatch is hidden inside the
  wrapper.

The wrapper stores its task-local record outside the checkout under
`$TMPDIR/cmux-next-preview` (override with `CMUX_PREVIEW_STATE_DIR`). Its JSON
receipt looks like this:

```json
{
  "mode": "gallery",
  "repo": "/Users/leoli/Projects/checkouts/cmux/sidebar-row-dogear",
  "branch": "sidebar-row-dogear",
  "sha": "<full-40-character-sha>",
  "worktree_dirty": true,
  "gallery_url": "http://127.0.0.1:4178/gallery/#/agent-pane.composer",
  "entry": "agent-pane.composer",
  "pid": 12345,
  "reused": true,
  "opened": false,
  "phase": "ready"
}
```

The exact state file is implementation-owned and safe to delete. Do not put
preview state in shared machine configuration.

## Provenance and stale-preview safeguards

Treat a screenshot or URL as evidence only when its provenance is explicit:

1. Record the full repository, full commit SHA, branch/upstream ref, source path,
   entry or scene id, variant/state, theme, and capture timestamp.
2. For a branch gallery, require the upstream ref to resolve to the same SHA as
   local `HEAD`; push again before opening a new compare URL after any head
   change. `scripts/gallery-compare.sh` already enforces this check.
3. For native capture, bind the request to the exact SHA and PR. A green or
   acknowledged dispatch is not a completed capture; retain the fleet job's
   terminal receipt and artifact URL.
4. Mark local HMR records as `dirty: true` when uncommitted edits are present.
   They are useful for iteration, but they must not be presented as branch or
   PR evidence.
5. If a live branch URL says it is still building, wait on its supported event
   or status surface. Do not start a second build merely because the page has
   not changed. If the branch or base moves, discard the old record and create a
   new exact-SHA record.
6. Keep light and dark captures, fixture names, and interaction state in the
   record. An unlabeled screenshot is a design hint, not a verification receipt.

The result should let a developer save, see the real surface immediately, open a
branch comparison with one command, and request one batched native capture when
the change warrants it—while letting an agent produce the same sequence with
stable ids and receipts instead of guessing which tab or revision it is viewing.

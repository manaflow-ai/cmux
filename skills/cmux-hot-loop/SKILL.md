---
name: cmux-hot-loop
description: "The loop for every cmux NEXT change you can see: write the code, put it into a running cmux (no build), use it (screenshot, video, click through), then run compile, CI, gallery and suites. Use before any app build, dev build, gallery job or test run for a change to webviews/, cmux-tui/ or acpmux, when trying someone's PR, branch or commit, and when asked for hot swap, hot reload or hot apply."
---

# The hot loop

**Start here, before any dev build: copy your nightly and swap your code in.**

```sh
cmux app try .              # a fresh clone of /Applications/cmux NIGHTLY.app beside the person's cmux, your tree in
cmux app try . --extract    # keep what went in: branch cmux-try/<copy> and a patch
cmux app try . --stop       # quit the clone and delete it
```

It puts your working tree's web UI (a dev server: saves show live) and daemon Rust into the clone, never into
the person's running app, and prints the clone's socket: drive it with `cmux --app-socket SOCKET ...`. Running it
again makes a fresh clone with your newest code. `--from APP` clones another build; `--dry-run` prints the plan.
Swift and FFI changes still need a build: it says why and prints the fleet `cmux-ci build cmux ...` command (dev
builds stay available). Off a Mac it prints the fleet route (push, `cmux-ci hot-verify N --look`).

Leo, 2026-11-15: "imagine if you could just write the code and then the code goes into your app and then you
can just use it." And: "Just screenshot it, take a video, touch it, interact with it, click around with it, and
then push it through the various testing instead of the other way around."

1. **Write** the change.
2. **Put it in** a running cmux, the cheapest way its layer allows (table below). No build.
3. **Use it.** Screenshot it, record a short video, click through the flow it changes. Fix what looks or feels
   wrong and put it in again; each round is seconds.
4. **Then test.** Compile checks, CI, gallery, suites, as before. They come after the look, not instead of it.

Build only when `plan` says the change needs one.

One command does steps 2 and 3 and leaves the proof: `scripts/cmux-next/hot-verify.py plan --source dir:. --app APP` says
`needs_build: true|false`; `hot-verify.py look --source dir:.|pr:N --app APP --out DIR` puts the change into a side
copy of APP, then writes before and after screenshots (light and dark), a click-through, a video and
`receipt.json`. Post the receipt's `<!-- cmux-hot-verify ... -->` marker on the PR with the shots: cmuxterm-hq's
`hot_verify_share` counts it (target 80% of the newest hot-eligible merged PRs; goal `hot-verify-share`).

## Which command, by layer

| Layer | Put it in | Take it out |
|---|---|---|
| Your working tree (web and daemon Rust), in a copy of the NIGHTLY | `cmux app try .` | `cmux app try . --stop` |
| Web: a PR's `webviews/` | `cmux customize use pr:N` | `cmux customize library off pr-N` |
| Web: a pushed branch or commit, no PR | `cmux customize use branch:NAME` or `sha:SHA` | `cmux customize library off NAME` |
| Web: your working copy, no push | `cmux customize use dir:PATH --watch` (applies again about 19 s after each save on a fleet Mac) | `cmux customize library off NAME` |
| Web: a fork's branch | `cmux customize use OWNER/REPO@REF` (the layer the fork's own workflow published, never our CI) | `cmux customize library off NAME` |
| Web: your checkout | `cmux live start --worktree <checkout>` (hot reload on every save) | `cmux live stop` |
| Terminal daemon, acpmux (`cmux-tui/` Rust), a merged commit | `scripts/cmux-next/hot-apply.py apply SHA` | `scripts/cmux-next/hot-apply.py rollback` |
| A whole PR, branch or commit | `cmux app try <PR\|branch\|sha>` | `cmux app try undo` |
| Daemon Rust from your checkout, terminals kept | `cmux live start --rust` | `cmux live stop` |
| Swift inside function bodies (CmuxNext modules, MessagesLabHome) | live code on a Debug base: `cmux live start --swift` ([live code](../../docs/cmux-next/live-code.md)) | `cmux live-code undo --all` |
| String catalogs (`.xcstrings`), Cloud wire types (`clients/ts`) | `cmux app try .` (web pages take the change; Swift's translations wait for a build) | `cmux app try . --stop` |
| Backend, images, workers, CI (no app change) | `cmux-ci test -- CMD` on Linux; Cloud calls from a copy: `cmux app try .`, then sign in from the copy | |
| Swift signatures, stored properties, new types, Rust the app links, resources, manifests | a build (`plan` names it) | |

Your code layers: `cmux customize library status` (what is on, one line), `library refresh` (pull each layer's
newest build in place; a fork's new code only through `use` again), `library off --all` (every code layer off; cmux serves its own pages).
`cmux customize doctor` lists every layer left on, and every customization file that does not load, is skipped,
overrides another or sits in the wrong folder, with its fix (`doctor fix ID off|remove`); the app shows the same notice.

## Examples

A web PR, in the app you are using:

```sh
cmux customize use pr:43496          # pr-43496 is on; open pages reload onto it
# look: screenshot the page, record it, click through
cmux customize library off pr-43496  # put back what was under it
```

A daemon change from a merged commit, before the nightly:

```sh
scripts/cmux-next/hot-apply.py plan SHA        # parts: web, rust, ffi; what is left for a build, and why
scripts/cmux-next/hot-apply.py apply SHA       # about 2.7 s; same app pid, terminals kept
scripts/cmux-next/hot-apply.py apply SHA --restart-sessions   # also other sessions' daemons, about 6.9 s
scripts/cmux-next/hot-apply.py rollback
```

`--restart-sessions` hands each other session's terminal daemon (a Chief's) to the new build; the 6.9 s
figure holds once the hot-apply fix for it lands. `apply SHA --dry-run` plans, fetches and checks without
touching the app, and `--base COMMIT` plans on a host with no app.

Someone's whole PR, the cheapest way there is (live binaries when CI published them for this app, else the
PR's nightly-feed build; it never builds):

```sh
cmux app try 43581
cmux app try status
cmux app try undo
```

## What still needs a build

Swift, resources, manifests, helpers bundled from cmux-tui crates, and Rust the app links statically.
`hot-apply.py plan` lists them under `left`, with why. Swift inside function bodies can go into a live code build
instead (docs/cmux-next/live-code.md).

Known limit: a tree build (your own `cargo build`) is not Team-signed, so hot-applying its Rust into a Developer
ID NIGHTLY is held back for now. Published per-commit builds, side copies (`scripts/cmux-next/try-pr.sh`) and
DEV builds take it.

## Signed in, without an "authenticated dev build"

A signed-in build to drive comes from a copy of a signed-in app, not from a new build:

| You want | Run | Signed in as |
|---|---|---|
| A PR or commit in your own NIGHTLY (Mac) | `cmux app try <PR\|sha>`, back with `cmux app try undo` | your production account, already signed in |
| A PR in a side copy of your app (Mac) | `scripts/cmux-next/try-pr.sh N` | signed out at first (own data); sign in once, production for a NIGHTLY copy |
| An agent, off a Mac (Linux, lane VM) | `cmux-ci hot-verify N --look` (a copy of the published NIGHTLY on a fleet display Mac) | none needed for a look |
| An agent step that needs a signed-in app | `cmux-ci run ... --sign-in agent` | the shared agent account, a session made for that step and revoked after it |
| A Swift change, a build handed to a person | `cmux-ci build cmux --ref SHA --tag T --workspace W --for-person` | the person's own cmux.com account (production Cloud) |

Never copy a person's own login file into a build or a step; the rows above are the supported routes.

## Where it runs

Never put a change into the person's own cmux unless they asked; use a side copy (`scripts/cmux-next/try-pr.sh
N`, `side-instance.sh`) or a fleet Mac. Builds and tests still never run on the person's Mac (CLAUDE.md).

More: [docs/cmux-next/hot-reload.md](../../docs/cmux-next/hot-reload.md) for every path in detail, and the
[cmux-live](../cmux-live/SKILL.md) skill for `cmux live`.

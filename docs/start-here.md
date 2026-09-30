# Start here

You want to change something in cmux and you have not done it before. This page
is the shortest path from that to a merged pull request. It assumes nothing
except that you can use git.

cmux is a macOS terminal that treats agents as first-class panes. The app and
the `cmux` CLI are Swift. `cmux-tui`, the SDKs and the repository tooling are
Rust, Python and TypeScript.

## 1. Pick something small

Sorted roughly by how little setup they need:

| If you want to | Look at |
|---|---|
| Fix something small with a clear starting point | [`good first issue`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) |
| Start with the smallest scoped work | [`difficulty:1`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22difficulty%3A1%22) |
| Work on one package or feature boundary | [`difficulty:2`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22difficulty%3A2%22) |
| Join a design or cross-component effort | [`difficulty:3`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22difficulty%3A3%22) |
| Take something nobody is working on | [`help wanted`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) |
| Work on one part of the app | [`area:` labels](https://github.com/manaflow-ai/cmux/labels?q=area) |
| Fix something badly broken | [`S1: critical`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22S1%3A+critical%22) and [`S2: major`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3A%22S2%3A+major%22) |
| Help without building anything | [`needs-triage`](https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue+is%3Aopen+label%3Aneeds-triage) |

[`docs/triage.md`](triage.md) explains what those labels mean and who assigns
them. Difficulty is a maintainer assessment of scope and coordination, while
`good first issue` means the starting point and verification path are explicit.
Some searches are still thin. The exception is `needs-triage`, which is around
500 issues: the rules could not tell which part of cmux each one is about. Reading one, working out where it belongs,
and saying so in a comment is useful and needs no Xcode.

**Say on the issue that you are picking it up.** One comment. It stops two
people writing the same patch, and it is how you find out early that an issue
is waiting on a decision rather than on code.

If the issue is old, check whether it is still true on
[NIGHTLY](https://github.com/manaflow-ai/cmux#nightly-builds) before you write
anything. Plenty of open issues were fixed by other work and nobody noticed.

## 2. Things you can fix without a Mac build

Most of cmux needs macOS and Xcode. These do not:

- Documentation, including this page and the [README](../README.md).
- Translations and localization catalogs.
- The Python tooling under `scripts/` and its tests under `tests/`, which run
  on Linux.
- The triage rules in [`scripts/ci/triage_rules.py`](../scripts/ci/triage_rules.py).
- The `cmux-tui` Rust crates and the SDKs, which have their own test lanes.

The web surfaces under `web/` also build and test on Linux, but note they are
licensed differently from the app: [LICENSE](../LICENSE) puts `web/` and the
other server directories under the Business Source License, and a change there
needs a signed [CLA](../CLA.md) before it can be merged. The app and CLI are the
GPL part of the tree.

If you do have a Mac: [CONTRIBUTING.md](../CONTRIBUTING.md) has the
prerequisites and the two commands that get you a running debug build
(`./scripts/setup.sh`, then `CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh
--tag my-feature`). Clone with `--recursive`; the submodules are not optional.

## 3. Check your change before you push

Run this on your own machine:

```bash
python3 scripts/verify-local.py
```

It picks the static checks your diff actually touches and prints the exact
rerun command when one fails. It does not need maintainer access, a shared
backend, or a build farm.

Then go up the [verification ladder](contributor-verification.md) as far as your
change needs: package tests, then compiling the app, then the isolated UI
checks. Where you stop is a judgement call, and saying where you stopped is
part of the pull request. "Compiles" and "I ran it" are different claims, and
reviewers will treat them differently.

You do not need a Mac build farm. When you open the pull request, CI runs the
static checks and routes the Swift, package and tooling tests your diff actually
touches, with no label and no request from you. The expensive full macOS suite is
label-gated; a maintainer adds `full-ci` in the rare case a change needs those
lanes, and it is not a merge requirement.

If checks do not start at all on your first pull request, they are waiting for a
maintainer to approve a workflow run from a new contributor. That is a GitHub
default, not a judgement about your patch.

## 4. Open the pull request

Fill in the template. The parts reviewers actually read:

- **Summary**: the problem, then what a person can do after your change.
  One paragraph beats five bullet points.
- **Testing**: what you ran and what it establishes. Name the command. If you
  could not run something, say which thing and why, once.
- **Changelog**: one `Added:`/`Changed:`/`Fixed:`/`Removed:` line, or `none`
  for internal changes. Do not edit `CHANGELOG.md`; the release builds it from
  these lines.
- For a bug fix, commit the failing test first, then the fix. That way the
  history shows the bug was there.

Keep the diff to one thing. A PR that fixes a bug and also reformats a file is
two PRs, and the reformatting will slow down the fix.

First time through you will also be asked to sign the
[CLA](../CLA.md): one comment on your PR with the sentence the bot gives you.

## 5. What happens next

Automated reviewers comment first, sometimes several of them, sometimes with
setup noise that has nothing to do with you. Ignore what does not apply.
Do not `@`-mention the review bots to get more of them; it makes the thread
harder to read and does not speed anything up.

A human reply can take a while. The outside-PR queue is long and we know it is
the weakest part of contributing here. If your PR goes quiet and you want eyes
on it, comment on it and say so. That works better than opening a second one.

To land, a change needs green CI, a review that has been answered, and no
pending decision about what cmux should do. That last one is the usual reason
a finished patch waits: if the question is "should cmux behave this way", a
maintainer answers it before the code goes in.

If we end up fixing the same thing another way, we credit you with a
`Co-authored-by` trailer and link the fix from your PR.

## For a class or a group

If several people are contributing at once, a few things make it work:

- Tell us first, on a single issue or in
  [Discord](https://discord.gg/xsgFEVrWCZ). Say roughly how many people and
  over what weeks. We will point at the parts of the backlog that suit a group.
- Have each person claim a different issue in a comment before starting. Thirty
  patches for one `good first issue` helps nobody.
- `needs-triage` and localization scale well across many people and need no
  Mac. A group that clears 200 `needs-triage` issues has done more for cmux
  than a group that opens 200 small PRs.
- One PR per person per issue. Do not open a PR per commit.
- Read [STYLE.md](../STYLE.md) once as a group; it is short, and it is what
  reviewers will hold the description to.

## Where to ask

- [Discord](https://discord.gg/xsgFEVrWCZ) for quick questions.
- [Discussions](https://github.com/manaflow-ai/cmux/discussions) for anything
  worth finding again later.
- [CONTRIBUTING.md](../CONTRIBUTING.md) for build, test and release mechanics.
- [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) for how we talk to each other:
  be nice, assume the best.

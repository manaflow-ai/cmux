# Make it yours in minutes

Open **Settings → Customize → Examples**. Pick one small example, copy its install command,
and paste it into a terminal in a folder where you keep projects. Accept the install card,
then edit `main.js`: every save reloads the view while `cmux ext dev` runs.

These are starting points for your own extensions, not a bundled widget set. Each has its own
app ID and source folder; several can run together beside your existing custom sidebar.
No SDK package, token in a file, app rebuild, or restart is needed.

| Example | What you can make | Files |
| --- | --- | --- |
| **My PRs** | Keep your open pull requests beside your work. Click a row to open it in a cmux browser tab. | [23 lines](../../skills/cmux-customization/templates/pull-watch/main.js) · [manifest](../../skills/cmux-customization/templates/pull-watch/cmux-app.json) |
| **Needs you** | See which agent chats are waiting for your answer. Open the question directly from the sidebar. | [23 lines](../../skills/cmux-customization/templates/needs-you/main.js) · [manifest](../../skills/cmux-customization/templates/needs-you/cmux-app.json) |
| **This workspace** | Follow the tabs in your focused workspace. Jump to its terminal, chat, or browser with one click. | [43 lines](../../skills/cmux-customization/templates/workspace-tabs/main.js) · [manifest](../../skills/cmux-customization/templates/workspace-tabs/cmux-app.json) |
| **Dashboard links** | Paste and keep the links your team uses every day. Open a dashboard beside your code in a cmux browser tab. | [39 lines](../../skills/cmux-customization/templates/saved-links/main.js) · [manifest](../../skills/cmux-customization/templates/saved-links/cmux-app.json) |
| **Branch status** | See the branch and ahead/behind counts for your current folder. In Session Info, the same view follows that chat’s repository. | [17 lines](../../skills/cmux-customization/templates/branch-status/main.js) · [manifest](../../skills/cmux-customization/templates/branch-status/cmux-app.json) |
| **Review requests** | Keep the pull requests waiting for your review in the sidebar. Open a review in a cmux browser tab. | [18 lines](../../samples/apps/showcase-pr-review/main.js) · [manifest](../../samples/apps/showcase-pr-review/cmux-app.v2.json) |
| **Working agents** | See your working and blocked terminal agents together. Click an agent to focus its terminal. | [24 lines](../../samples/apps/showcase-agent-status/main.js) · [manifest](../../samples/apps/showcase-agent-status/cmux-app.v2.json) |
| **Quick actions** | Put useful cmux actions in your sidebar. Each button runs a real app action from your click. | [15 lines](../../samples/apps/showcase-command-buttons/main.js) · [manifest](../../samples/apps/showcase-command-buttons/cmux-app.v2.json) |
| **Focus timer** | Start or pause a short focus session beside your work. Native controls count down and cmux tells you when time is up. | [47 lines](../../samples/apps/showcase-focus-timer/main.js) · [manifest](../../samples/apps/showcase-focus-timer/cmux-app.v2.json) |
| **Today** | Keep a small Today list beside your workspace. Add a note and keep it across reloads using local app storage. | [45 lines](../../samples/apps/showcase-standup/main.js) · [manifest](../../samples/apps/showcase-standup/cmux-app.v2.json) |

## Install, change, remove

**Copy install command** creates a new `cmux-example-<name>.XXXXXX` folder in your current
directory and downloads the two files linked above. It never writes over your customize folder.
The command runs `cmux ext dev` in that folder. Keep that terminal running while you edit;
Ctrl-C stops watching, and the installed example stays available. Resume with
`cmux ext dev <folder>`. To edit an installed example, reuse that folder: installing its fixed
ID from a second folder is refused so it cannot overwrite your work. To make a second instance,
change the manifest’s `id` first.

To copy files yourself, save the source as `main.js` and the manifest as `cmux-app.json` together
in a new folder, then run `cmux ext dev <folder>`. Use **Source** on a Settings row to read it first.
The examples use the built-in JavaScript scene kit, with no build step. The TS, Python, Rust,
and Go SDKs are not required and remain unpublished.

Read scopes are granted at installation. Enable the example’s requested action or storage
scopes in **Settings → Apps** to open tabs, focus a terminal, or keep notes. Refused permissions
show a message in the view. GitHub examples use your connected GitHub integration.

To remove an example, run `cmux ext remove <id>` using its manifest’s `id`. Your source folder
stays available to edit. A focus timer starts fresh on reload; saved notes and links survive
when their storage permission is enabled. Branch status includes Refresh for external Git changes.

## See the examples

The [gallery](customization-showcase.gallery.md) records three states per view. Fixture-backed
native captures demonstrate rendering; the separate NIGHTLY readback checks real data, clicks,
and edit/save reload. Pending checks are explicitly marked there.

The [catalog](../../skills/cmux-customization/showcase.json) drives Settings and lists the same
files, descriptions, capture states, and API gaps. Existing larger recipes remain in the
[examples library](../../skills/cmux-customization/references/examples.md).

## What is still awkward

- `github.pulls` has no CI/check-run fields, so PR views cannot yet show CI badges.
- New-agent actions lack prompt/diff attachments for “Review this diff with Codex”.
- NEXT has no chat-toolbar contribution host or chat transcript API for a summarize button.
- Declarative workspace layouts remain classic-only; a Morning layout needs a NEXT action.
- Session Info has no per-chat token/cost signal.
- `cmux.live` does not accept reactive parameters; the workspace example needs its own small, coalesced loader. Create readers in a render export, never a dynamic child or the script’s top level.
- Custom `cmuxConfig.*` actions are restricted to `local/customize`; independent examples use built-in actions.

These are explicit follow-up targets, not claims made by the samples. The default theme remains
One Color; every view uses the native kit and follows the person’s selected theme.

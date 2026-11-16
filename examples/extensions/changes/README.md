# Changes: a live pull request list in the sidebar

`local/changes` is a sidebar section with a live list of pull requests, like the Changes list in a
session rail, as a customization you add. Each row has the title, `repo #N`, the lines added and
removed, the checks (failing, running, passed, merged) and the review state. A click opens the pull
request in a cmux browser tab. The ⋯ menu has Open on GitHub, Copy link, and Check out in a new
workspace. The first five rows show, then Show more.

It imports nothing but `cmux-extension-sdk`, and it is opt in: cmux never turns it on. You install it
(below), and turning it off is one click in Settings > Apps.

## Which pull requests

Settings > Apps > Changes > Show:

| Show | Lists |
| --- | --- |
| This workspace's branch | The pull requests whose head is the selected workspace's branch, in its GitHub repository (`git.status` with `github: true`) |
| My open pull requests (default) | The ones you opened |
| Mentioning me | The ones that mention you |
| Asking for my review | The ones that ask for your review |
| Saved search | Any GitHub search, for example `repo:manaflow-ai/cmux label:bug` |

## How it stays live, and what it can read

- `cmux.watch("github.changes", params)` does every read. It is one read per (source, params) for
  every window that shows the section, and it stops when the section is gone.
- Every GitHub read is a conditional request (`If-None-Match`): a pull request that did not change
  is answered from its ETag and costs your rate limit nothing. The section never sets a timer;
  GitHub webhooks reach it through cmux Cloud (`github.changed`), so a check or review flips
  within seconds; until that push is live the source re-reads every 60 s at most.
- GitHub access is one scope, `integration:github:read`, approved once on the install card. The
  reads go through your GitHub sign-in in cmux (today the `gh` CLI's; private repositories
  included) and the token never reaches this extension's code.
- Without a sign-in it reads public repositories through GitHub's public API, once you grant
  `net:api.github.com` in Settings > Apps > Changes. That API allows 60 requests an hour, so this
  route shows at most 5 rows with their checks (no review state) and refreshes every 5 to 15
  minutes. Set the GitHub login setting so "My open pull requests" knows who you are. When a
  network's public limit is used up, the section says so and when it resets.
- Loaded from a folder (`cmux ext dev`), it installs unverified and sandboxed: no network, so no
  GitHub reads either way, until you turn off Run sandboxed in the App Store (Installed,
  Changes, Permissions). The section says this instead of asking you to sign in.

## Looks

The `look` variant (Settings > Apps > Changes > Look) has three: `rail` (two lines, the reference),
`compact` (one standard sidebar row) and `panel` (a glass card per pull request).

## Install

From the root of this repository, with cmux open:

```sh
cmux ext dev examples/extensions/changes
```

Accept the install card once; after that every save to `src/main.ts` reloads it. `cmux ext remove
local/changes` uninstalls it. Tests: `cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts`
(the section) and `js/test/github-changes.test.ts` (the source).

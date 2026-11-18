# Making a customization repo: template, gallery, release, and staying working across updates

A customization repo is a git repository that holds one whole cmux look or setup: a theme file,
settings, a chat stylesheet, and optional views and extensions. People install it with one line:

```sh
cmux setup install github.com/OWNER/REPO
```

This page is the process, start to finish, for anyone: copy the template, check it, take the
gallery pictures, cut a release, get it listed, and keep it working as cmux changes. The formats
themselves are documented where they live; this page links to them at the step that needs them.

## 1. Start from the template

Copy [`examples/setup-template/`](../../examples/setup-template/) into a new repository:

```sh
cp -R examples/setup-template ~/src/my-look && cd ~/src/my-look && git init -b main
```

| File | What it is | Format |
| --- | --- | --- |
| `cmux-setup.json` | The listing header (id, name, version, `engines.cmux`) and the settings the look sets | `cmuxSetup: 1` over `cmuxProfile: 1` |
| `themes/NAME.json` | Colors, surfaces, borders, density; picked by `appearance.themeFile` | [theme-recipes.md](theme-recipes.md) |
| `agent-pane/theme.css` | The chat's paint: only `cmux.agentPane.style/1` tokens, on `:root` | `schemas/agent-pane/style-tokens.json` |
| `customize/` | Optional: a hover card, sidebar rows, a section (a `cmux-app.json` manifest v2 app) | [sidebar-customization.md](sidebar-customization.md) |
| `SHOTS.md` | The gallery states your README pictures show | this page, step 3 |
| `.github/workflows/check.yml` | Runs `cmux setup check` against the newest nightly on every push and once a day | this page, step 5 |

Rules the template already follows, so keep them:

- The id is `OWNER/NAME`, and OWNER is the repository's owner. `cmux setup install` refuses
  anything else.
- Every setting is an ordinary public setting. Use the key names from Settings (each row shows
  its key) or `cmux settings describe KEY`. Nothing in a look reaches into cmux's own files.
- Set `engines.cmux` to the oldest cmux you tested with (`cmux --version` prints it). An older
  cmux then refuses the install with a plain reason instead of drawing half a look.
- Paint, never layout: a look changes colors, type, radii and density on the shared grid. It
  never sets a row height, a pane width or motion, so switching looks moves nothing.

## 2. Check it while you work

```sh
cmux setup check .            # every finding, with the file and key
cmux setup check . --json     # the same, for an agent or CI
```

`setup check` reads the folder and writes nothing: it runs every check `setup install` runs (the
id, `engines.cmux`, each setting's key and value, the theme file, the stylesheet's tokens, the
`customize/` manifest, the secrets scan) and reports all of them at once, so one pass shows
everything to fix. A finding is an `error` (install would refuse) or a `warning` (install works,
but something will break later, such as a setting that was renamed: see step 6).

To see the look on your own window, install the folder itself, and remove it to get your setup
back exactly as it was:

```sh
cmux setup install ./            # shows what it changes, asks, then applies it as one generation
cmux setup remove OWNER/NAME     # takes off exactly that layer
```

## 3. Take the gallery pictures

Every listed look has the same set of pictures, so a person can compare looks side by side. List
the ones you took in `SHOTS.md` and link them from the README:

| File | State |
| --- | --- |
| `screenshots/chat.png` | An agent chat mid-conversation: a prompt, tool rows, a reply with a code block |
| `screenshots/chat-end.png` | The same chat scrolled to the end, with the composer |
| `screenshots/sidebar.png` | The sidebar with a few workspaces, one working, one needing input |
| `screenshots/stylesheet-over-a-light-theme.png` or `...-dark-theme.png` | Your `agent-pane/theme.css` over the other base theme, so people see what happens when they keep your stylesheet and change theme |

Take them from a cmux window with the look installed: `cmux window screenshot --out
screenshots/chat.png` captures the window with cmux's own capture (no screen recording grant, no
change of focus). Use the demo workspace from a fresh profile so no private names show.

## 4. Release

A release is a git tag that equals `version` in `cmux-setup.json`:

1. Bump `version` (semver: a new look choice is minor, a fix is a patch, anything that changes
   what an existing install looks like is a major).
2. Run `cmux setup check . --strict` (warnings fail too).
3. Commit, tag and push: `git tag v1.1.0 && git push origin main v1.1.0`.
4. Create the GitHub release for the tag, with the gallery pictures in the notes.

People who installed the look get it with `cmux setup update OWNER/NAME`; it applies as one
generation, so `cmux customize rollback` takes them back.

## 5. Get it listed

Add the GitHub topic `cmux-setup` to the repository, and open a pull request to
[manaflow-ai/cmux-extensions](https://github.com/manaflow-ai/cmux-extensions) adding one entry to
`setups.json`:

```json
{ "id": "OWNER/NAME", "name": "Name", "author": "You", "description": "One line.", "repo": "OWNER/REPO" }
```

The registry's review checks the entry, and from then on the compatibility job (step 6) runs your
repo against every cmux nightly.

## 6. Staying working across cmux updates

cmux changes every day. These are the promises it makes to a published look, and what you do
about each kind of change.

| What changed in cmux | What happens to your installed look | What you do |
| --- | --- | --- |
| A new setting, choice, token or slot | Nothing. An older cmux skips a setting it does not know yet and lists it as skipped on the install card | Nothing; raise `engines.cmux` if the look needs it |
| A setting renamed | cmux rewrites the old key to the new one on install and on read, and `setup check` warns with the new name | Rename the key before the window ends: `setup check` names the new key |
| A setting removed | The key is skipped with a notice; the rest of the look still installs | Drop the key; the notice says what replaced it, if anything |
| A choice renamed | The old value is read as the new one (the row's `aliases`) | Nothing; update when you next release |
| An interface's major (`cmux.section/1` to `/2`) | cmux keeps serving `/1` until no listed extension uses it | Move to `/2` when you can; `cmux ext dev` warns while `/1` is deprecated |
| A slot variant that fails to load | That slot falls back to cmux's default; every other slot keeps your variant | Fix the variant; the error names the slot |

Renames and removals are declared once, in `schemas/settings/retired-keys.json` in the cmux
repository, with the version they start and the end of their deprecation window. During the
window cmux migrates silently and `setup check` warns; after it, `setup check` reports an error so
the author knows, and install still migrates, so a person's look never breaks because its author
was away.

The compatibility job is what makes this honest. After each nightly, it runs every repository in
`setups.json` through that nightly's checks in a clean home folder and posts a report: each repo,
pass or fail, each finding, and what is new since the previous nightly. A cmux change that would
break a listed look shows up there, before a person updates, and the fix (a migration entry, an
alias, or a change to the look) lands before the release.

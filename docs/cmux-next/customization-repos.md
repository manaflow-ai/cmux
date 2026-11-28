# Making a customization repo: template, gallery, release, and staying working across updates

A customization repo is a git repository that holds one whole cmux look or setup: a theme file,
settings, a chat stylesheet, and optional views and extensions. People install it with one line:

```sh
cmux setup install github.com/OWNER/REPO
```

Every `cmux setup` command (install, update, remove, export, check) is in
[setup-repos.md](setup-repos.md). This page is the process, start to finish, for anyone: copy the template, check it, take the
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
| `agent-pane/theme.css` | Optional chat paint; inspect the result in the app because token validation is not available | [setup-repos.md](setup-repos.md#check-one-before-you-push-it) |
| `customize/` | Optional sections, panels and pages (a `cmux-app.json` manifest v2 app); sidebar decorations and hover cards use local customization | [setup-repos.md](setup-repos.md) |
| `SHOTS.md` | The gallery states your README pictures show | this page, step 3 |

Before using the template:

- Replace `OWNER` and `REPO` in the manifest and README. The id is lowercase `owner/name`,
  and its owner must match the repository's owner. The placeholders are not installable ids.
- Every setting is an ordinary public setting. Use the key names from Settings (each row shows
  its key) or `cmux settings describe KEY`. Nothing in a look reaches into cmux's own files.
- Set `engines.cmux` to the oldest cmux you tested with (`cmux --version` prints it). An older
  cmux then refuses the install with a plain reason instead of drawing half a look.
- Keep chat CSS limited to paint. Use documented settings for density and proportions;
  see [theme-recipes.md](theme-recipes.md). Check both light and dark appearances.

## 2. Check it while you work

```sh
cmux setup check .            # every finding, with the file and key
cmux setup check . --json     # the same, for an agent or CI
```

`setup check` reads the folder and writes nothing. It checks the id, `engines.cmux`, settings,
theme files, the `customize/` manifest and secrets, reporting findings together. Fix errors and
review warnings before publishing; `--strict` also fails on warnings. Author checks can be
stricter than installation: an unknown setting is an error here, even though installation can
skip it (step 6).

Read the report's `skipped` list too. Stylesheet token validation is not implemented:
`agent-pane/theme.css` is checked only for hidden characters and secrets. A clean check does
not prove that CSS takes effect or looks right; inspect it in the running app.

To see the look on your own window, install the folder itself, and remove it to get your setup
back exactly as it was:

```sh
cmux setup install ./            # shows what it changes, asks, then applies it as one generation
cmux setup remove OWNER/NAME     # takes off exactly that layer
```

## 3. Take the gallery pictures

Capture these states so a person can compare looks side by side. List
the ones you took in `SHOTS.md` and link them from the README:

| File | State |
| --- | --- |
| `screenshots/chat.png` | An agent chat mid-conversation: a prompt, tool rows, a reply with a code block |
| `screenshots/chat-end.png` | The same chat scrolled to the end, with the composer |
| `screenshots/sidebar.png` | The sidebar with a few workspaces, one working, one needing input |
| `screenshots/stylesheet-over-a-light-theme.png` or `...-dark-theme.png` | Your `agent-pane/theme.css` over the other base theme, so people see what happens when they keep your stylesheet and change theme |

Take them from a cmux window with the look installed, using a demo workspace with no private
names. See [the looks gallery](setup-repos.md#the-looks-gallery) for the golden preview command
and filenames used by gallery cards.

## 4. Release

Use a git tag corresponding to `version` in `cmux-setup.json` (for example, version `1.1.0`
and tag `v1.1.0`):

1. Bump `version` (semver: a new look choice is minor, a fix is a patch, anything that changes
   what an existing install looks like is a major).
2. Run `cmux setup check . --strict` (warnings fail too).
3. Commit, tag and push: `git tag v1.1.0 && git push origin main v1.1.0`.
4. Create the GitHub release for the tag, with the gallery pictures in the notes.

`cmux setup update OWNER/NAME` follows the installed source ref to its latest commit; it does
not select the newest release tag automatically. Updates apply as one generation, so
`cmux customize rollback` takes them back. Document the source ref you support alongside releases.

## 5. Get it listed

Add the GitHub topic `cmux-setup` to the repository to help people find it. To appear in the
built-in gallery, open a reviewed pull request to cmux adding an entry to
[`cmux-tui/crates/cmux-customize/src/setup/looks.json`](../../cmux-tui/crates/cmux-customize/src/setup/looks.json),
following the existing entries:

```json
{ "id": "owner/my-look", "name": "My Look", "tagline": "One line.", "repo": "github.com/owner/repo" }
```

Include previews and the results of your checks. The gallery list ships with cmux; listing a
look does not schedule compatibility checks for its repository.

## 6. Staying working across cmux updates

Test your look on the oldest cmux you support and on the version you intend people to update
to. The settings migration table helps existing installs, but does not replace author checks.

| What changed in cmux | What happens to your installed look | What you do |
| --- | --- | --- |
| An unknown setting | Setup installation leaves the key out and reports it; `setup check` reports an error | Correct a typo, or raise `engines.cmux` if the look needs the newer setting |
| A setting renamed in the migration table | Installation maps it to the replacement | Use the current key; inspect the check's deprecation finding |
| A setting removed in the migration table | Installation drops it and records a notice | Remove it or use its documented replacement |
| A choice renamed with a declared alias | Migration maps the old value to its replacement | Use the current value when publishing |
| An invalid value for a known setting | Installation refuses the setup | Correct the value; unknown-key fallback does not cover invalid values |
| A view interface or stylesheet changes | Settings migrations do not establish compatibility for views or CSS | Validate the manifest and try every affected view and appearance in the app |

Renames and removals are declared once, in `schemas/settings/retired-keys.json` in the cmux
repository. Entries can supply replacements, value mappings and deprecation windows.
Installation migrates declared retired keys even after a window ends. Author checks inspect
the source settings and can report both deprecation warnings and unknown-key errors; update
the source instead of relying on installation's fallback.

The template does not include a CI workflow. If you automate compatibility checks in your
repository, provision the cmux versions you support and run `cmux setup check . --strict` on
each. Record `cmux --version`, the setup commit and the check output with each release. Repeat
the visual checks after changes to cmux or the look; a passing command cannot validate its feel.

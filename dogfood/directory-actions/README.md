# Directory Actions Dogfood

This tree is for dogfooding per-directory `cmux.json` resolution.

Use a terminal pane in cmux and `cd` into these directories:

- `dogfood/directory-actions/alpha`
- `dogfood/directory-actions/alpha/nested`
- `dogfood/directory-actions/legacy`
- `dogfood/directory-actions/legacy/prefer-dot-cmux`

What each one demonstrates:

- `alpha`
  - Inherits the ancestor `./.cmux/cmux.json`
  - Shows ancestor lookup from the active pane cwd
- `alpha/nested`
  - Has its own `./.cmux/cmux.json`
  - Overrides `cmux.newTerminal`
  - Replaces the surface tab bar button list
  - Still inherits parent actions into Command Palette
- `legacy`
  - Uses fallback `./cmux.json`
  - Demonstrates backward-compatible local config loading
- `legacy/prefer-dot-cmux`
  - Contains both `./cmux.json` and `./.cmux/cmux.json`
  - The `./.cmux/cmux.json` file should win

General expectations:

- Image-backed project-local icons start as a lock until that exact action is trusted.
- Emoji-backed project-local actions show their emoji immediately, but still prompt on first run.
- Running a trusted action opens a new terminal tab in the current pane and sends the configured shell input.
- Command Palette should update as the active pane cwd changes.

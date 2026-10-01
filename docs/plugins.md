# cmux app plugins

An app plugin is a directory with a `cmux-plugin.toml` whose `kind` is
`extension`. It adds command-palette actions (bindable to shortcuts in
cmux.json) and commands that run on cmux events. Plugins are executables in
any language; cmux runs them with your user permissions and does not sandbox
them.

The manifest format is shared with cmux-tui, whose sidebar and agent plugins
use the same file with `kind = "sidebar"` or `kind = "agent"`
([cmux-tui plugin contract](../cmux-tui/spec/plugins.md)). Those kinds are
still installed with cmux-tui; `cmux plugin` installs `extension` plugins.

## Try the example

```sh
cmux plugin link Examples/cmux-plugin-hello
cmux plugin enable hello
```

`enable` prints every command the plugin can run and asks before activating
it. Open the command palette and run **Say Hello**. The app picks up the
change right away when it is running, or at its next launch.

## Manifest

```toml
[plugin]
name = "hello"            # [a-z0-9_-]+, at most 64 bytes; also the install directory name
kind = "extension"
version = "0.1.0"         # optional
description = "..."       # optional
platforms = ["macos"]     # optional; must include macos when present

[[actions]]
id = "say-hello"          # [a-z0-9_-]+; the registry id is plugin.hello.say-hello
title = "Say Hello"
subtitle = "Hello plugin" # optional; defaults to the plugin name
keywords = ["example"]    # optional palette search terms
argv = ["./bin/say-hello"]
shortcut = "cmd+ctrl+h"   # optional default, cmux.json syntax
palette = true            # optional; false keeps it out of the palette
timeout_seconds = 60      # optional, 1 to 300

[[events]]
event = "workspace.created"   # exact name or * prefix/suffix, as in automations.json
argv = ["./bin/log-event"]
timeout_seconds = 60          # optional, 1 to 300

[build]                       # optional; runs once in the checkout during install
command = ["make"]
```

Unknown tables and keys are errors, so a typo fails at install time instead
of being ignored.

`argv` is never passed through a shell. An `argv[0]` containing a slash but
not starting with one (`./bin/tool`, `bin/tool`) is relative to the plugin
directory; a bare name (`python3`) is looked up on `PATH`. Commands run with
the plugin directory as the working directory, stdout and stderr discarded,
and are killed, with their process group, after the timeout (60 seconds by
default).

### Environment

| Variable | Value |
| --- | --- |
| `CMUX_PLUGIN_ID` | The plugin name. |
| `CMUX_PLUGIN_DIR` | The plugin directory (the link target for linked plugins). |
| `CMUX_PLUGIN_STATE_DIR` | `~/.local/state/cmux/plugins/<name>`, created before each run. |
| `CMUX_PLUGIN_CONFIG_DIR` | `~/.config/cmux/plugins/<name>`, for the user's plugin settings. |
| `CMUX_PLUGIN_VERSION` | `plugin.version`, when set. |
| `CMUX_PLUGIN_ACTION_ID` | Actions only: `plugin.<name>.<action>`. |
| `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID` | Actions only: the workspace and focused surface the action ran in. |
| `CMUX_PLUGIN_CONTEXT_JSON` | JSON object with `plugin_id`, `action_id`, `workspace_id`, `surface_id`, and `socket_path`; omitted optional values are represented as empty strings. |
| `CMUX_SOCKET_PATH` | The app's control socket. |
| `CMUX_BUNDLED_CLI_PATH` | The app's `cmux` CLI. Its directory is also first on `PATH`. |

Event hooks run as [automation](automations.md) `run` rules, so they also get
`CMUX_EVENT_JSON`, `CMUX_AUTOMATION_EVENT_NAME`, and the other automation
variables. The event payload carries the workspace and surface ids.

## Actions, shortcuts, and cmux.json

Each action joins the cmux.json action registry as `plugin.<name>.<action>`,
so it can be retitled, rebound, hidden from the palette, or used as a tab-bar
button like any other action:

```json
{
  "actions": {
    "plugin.hello.say-hello": { "shortcut": "cmd+shift+h" }
  },
  "ui": {
    "surfaceTabBar": {
      "buttons": ["cmux.newTerminal", "cmux.newBrowser", "plugin.hello.say-hello"]
    }
  }
}
```

A plugin's default shortcut is ignored when it is invalid or already bound to
a cmux shortcut. A shortcut set in cmux.json always applies.

`cmux plugin action invoke hello.say-hello` runs an action from a script, with
the caller's workspace and surface (or the selected ones) as context.

## Install, enable, remove

```text
cmux plugin install <git-url|owner/repo[/subdir]> [--subdir <path>] [--force] [--yes]
cmux plugin link <dir> [--force]
cmux plugin list [--json]
cmux plugin enable <name> [--yes]
cmux plugin disable <name>
cmux plugin remove <name>
cmux plugin reload
cmux plugin action invoke <name>.<action>
```

`install` clones with `git clone --depth 1` into a hidden staging directory,
validates the manifest, prints every command the plugin runs (including the
build command), asks for confirmation, runs `[build]`, and moves the plugin to
`~/.local/share/cmux/mux-plugins/extension/<name>`. `owner/repo` is a GitHub
shorthand; `owner/repo/sub/dir` installs one directory of a repository.
HTTP(S) sources with credentials, a query, or a fragment are rejected; use a
git credential helper or SSH for private repositories. `link` symlinks a local
directory instead, for development.

Nothing runs until `cmux plugin enable`. Enabling records the SHA-256 of the
manifest in `~/.config/cmux/plugins.json`. When a reinstall or an edit changes
the manifest, the plugin shows as `changed` in `cmux plugin list` and stays
inactive until it is enabled again. Only the manifest is fingerprinted: a
linked plugin's scripts can change without re-enabling.

`remove` deletes the install (only the symlink for a linked plugin) and its
enablement, and leaves the state and config directories in place.

These paths are fixed under your home directory; `XDG_*` variables are not
consulted, because the app and a shell would otherwise disagree.

## Not yet supported

Plugin panes, link handlers, startup commands, and a plugin catalog are
planned as separate additions. A manifest that declares them is rejected
today rather than half-loaded.

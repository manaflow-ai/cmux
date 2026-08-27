package main

// commands is the relay's command table. Each entry maps a CLI command name to
// a v2 JSON-RPC method and declares which flags it accepts. Relay-specific
// behaviour (paramKeyOverrides, specialDispatch, defaultParams) lives in
// cli_overrides.go; init() in cli.go applies those overrides on top.
var commands = []commandSpec{
	{
		name:      "break-pane",
		v2Method:  "pane.break",
		flagKeys:  []string{"pane", "surface", "workspace", "window", "focus", "no-focus"},
		boolFlags: []string{"focus", "no-focus"},
	},
	{
		name:     "capabilities",
		v2Method: "system.capabilities",
		noParams: true,
	},
	{
		name:     "clear-history",
		v2Method: "surface.clear_history",
		flagKeys: []string{"surface", "workspace", "window"},
	},
	{
		name:     "close-surface",
		v2Method: "surface.close",
		flagKeys: []string{"surface", "panel", "workspace", "window"},
	},
	{
		name:     "close-window",
		v2Method: "window.close",
		flagKeys: []string{"window"},
	},
	{
		name:     "close-workspace",
		v2Method: "workspace.close",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:     "current-window",
		v2Method: "window.current",
		noParams: true,
	},
	{
		name:     "current-workspace",
		v2Method: "workspace.current",
		flagKeys: []string{"window"},
	},
	{
		name:      "dismiss-notification",
		v2Method:  "notification.dismiss",
		flagKeys:  []string{"id", "all-read"},
		boolFlags: []string{"all-read"},
	},
	{
		name:     "equalize-splits",
		v2Method: "workspace.equalize_splits",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:     "focus-panel",
		v2Method: "surface.focus",
		flagKeys: []string{"panel", "workspace", "window"},
	},
	{
		name:     "focus-window",
		v2Method: "window.focus",
		flagKeys: []string{"window"},
	},
	{
		name:      "join-pane",
		v2Method:  "pane.join",
		flagKeys:  []string{"target-pane", "pane", "surface", "workspace", "window", "focus", "no-focus"},
		boolFlags: []string{"focus", "no-focus"},
	},
	{
		name:     "jump-to-unread",
		v2Method: "notification.jump_to_unread",
		noParams: true,
	},
	{
		name:     "last-pane",
		v2Method: "pane.last",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:     "last-workspace",
		v2Method: "workspace.last",
		flagKeys: []string{"window"},
	},
	{
		name:     "list-pane-surfaces",
		v2Method: "pane.surfaces",
		flagKeys: []string{"pane", "workspace", "window"},
	},
	{
		name:     "list-panes",
		v2Method: "pane.list",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:     "list-panels",
		v2Method: "surface.list",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:     "list-windows",
		v2Method: "window.list",
		noParams: true,
	},
	{
		name:     "list-workspaces",
		v2Method: "workspace.list",
		flagKeys: []string{"window"},
	},
	{
		name:      "mark-notification-read",
		v2Method:  "notification.mark_read",
		flagKeys:  []string{"id", "workspace", "surface", "window", "all"},
		boolFlags: []string{"all"},
	},
	{
		name:     "move-workspace-to-window",
		v2Method: "workspace.move_to_window",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:      "new-pane",
		v2Method:  "pane.create",
		flagKeys:  []string{"type", "direction", "placement", "workspace", "window", "url", "focus"},
		boolFlags: []string{"focus"},
	},
	{
		name:          "new-split",
		v2Method:      "surface.split",
		flagKeys:      []string{"surface", "panel", "workspace", "window", "focus"},
		boolFlags:     []string{"focus"},
		positionalKey: "direction",
	},
	{
		name:      "new-surface",
		v2Method:  "surface.create",
		flagKeys:  []string{"type", "pane", "placement", "workspace", "window", "url", "provider", "renderer", "working-directory", "focus"},
		boolFlags: []string{"focus"},
	},
	{
		name:     "new-window",
		v2Method: "window.create",
		noParams: true,
	},
	{
		name:       "new-workspace",
		v2Method:   "workspace.create",
		flagKeys:   []string{"name", "cwd", "description", "focus", "window", "group", "group-placement", "group-reference", "layout", "env-file", "command"},
		boolFlags:  []string{"focus"},
		repeatKeys: []string{"env"},
	},
	{
		name:     "next-workspace",
		v2Method: "workspace.next",
		flagKeys: []string{"window"},
	},
	{
		name:     "notify",
		v2Method: "notification.create",
		flagKeys: []string{"title", "subtitle", "body", "workspace", "surface", "window"},
	},
	{
		name:     "open-notification",
		v2Method: "notification.open",
		flagKeys: []string{"id"},
	},
	{
		name:     "ping",
		v2Method: "system.ping",
		noParams: true,
	},
	{
		name:     "previous-workspace",
		v2Method: "workspace.previous",
		flagKeys: []string{"window"},
	},
	{
		name:      "read-screen",
		v2Method:  "surface.read_text",
		flagKeys:  []string{"surface", "workspace", "window", "scrollback", "lines"},
		boolFlags: []string{"scrollback"},
	},
	{
		name:     "refresh-surfaces",
		v2Method: "surface.refresh",
		noParams: true,
	},
	{
		name:          "rename-workspace",
		v2Method:      "workspace.rename",
		flagKeys:      []string{"workspace", "window", "title"},
		positionalKey: "title",
	},
	{
		name:     "resize-pane",
		v2Method: "pane.resize",
		flagKeys: []string{"pane", "workspace", "window", "direction", "amount"},
	},
	{
		name:     "select-workspace",
		v2Method: "workspace.select",
		flagKeys: []string{"workspace", "window"},
	},
	{
		name:          "send",
		v2Method:      "surface.send_text",
		flagKeys:      []string{"surface", "workspace", "window"},
		positionalKey: "text",
	},
	{
		name:          "send-key",
		v2Method:      "surface.send_key",
		flagKeys:      []string{"surface", "workspace", "window"},
		positionalKey: "key",
	},
	{
		name:      "swap-pane",
		v2Method:  "pane.swap",
		flagKeys:  []string{"pane", "target-pane", "workspace", "window", "focus"},
		boolFlags: []string{"focus"},
	},
}

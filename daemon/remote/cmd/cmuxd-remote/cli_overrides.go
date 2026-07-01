package main

// commandOverride describes relay-specific behaviour that cannot be expressed
// in the system.command_spec JSON and therefore cannot be generated.
// The generator produces the base commandSpec from the spec; init() applies
// these overrides on top.
type commandOverride struct {
	// paramKeyOverrides maps a CLI flag name to the JSON param key sent to the
	// server when they differ (e.g. "--name" must be sent as "title").
	paramKeyOverrides map[string]string

	// positionalKey is the param key for a positional argument. Takes precedence
	// over the positionalKey in the generated spec (for cases where the override
	// needs to differ from the Mac CLI convention).
	positionalKey string

	// defaultParams are params always included in the RPC call even when the
	// corresponding flag is absent.
	defaultParams map[string]any

	// specialDispatch marks the command as having a custom runXxxRelay function
	// in cli.go. runCLI dispatches to it instead of the generic relay path.
	specialDispatch bool

	// clientOnlyFlags are flag names that are handled client-side and must NOT
	// be forwarded to the server as RPC params. They are still accepted by
	// parseFlags so the user can pass them; the special dispatch function reads
	// them from parsedFlags.flags before building the params map.
	clientOnlyFlags []string
}

// commandOverrides is consulted by init() and by runCLI for dispatch.
// Add an entry here whenever the relay needs to deviate from the generated spec.
var commandOverrides = map[string]commandOverride{

	// --name is the CLI flag; the server param is "title".
	// --command, --env-file, and --layout are handled client-side by
	// runNewWorkspaceRelay (post-create send, file read, JSON parse).
	"new-workspace": {
		paramKeyOverrides: map[string]string{"name": "title"},
		clientOnlyFlags:   []string{"command", "env-file", "layout"},
		specialDispatch:   true,
	},

	// Mac CLI help shows "title" as a positional arg; relay accepts --title as a
	// flag instead (both paths exist on the server side).
	"rename-workspace": {
		positionalKey: "", // flag only in relay; positional not wired
	},

	// new-pane defaults direction to "right" when the flag is omitted, matching
	// the Mac CLI default.
	"new-pane": {
		defaultParams: map[string]any{"direction": "right"},
	},

	// --panel is an alias for --surface that maps to surface_id.
	"focus-panel": {
		paramKeyOverrides: map[string]string{"panel": "surface_id"},
	},

	// --target-pane maps to the server param target_pane_id.
	"join-pane": {
		paramKeyOverrides: map[string]string{"target-pane": "target_pane_id"},
	},
}

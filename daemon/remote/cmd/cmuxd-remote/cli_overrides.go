package main

// commandOverride describes relay-specific behaviour that cannot be expressed
// in the system.command_spec JSON and therefore cannot be generated.
// The generator produces the base commandSpec from the spec; init() applies
// these overrides on top.
type commandOverride struct {
	// paramKeyOverrides maps a CLI flag name to the JSON param key sent to the
	// server when they differ (e.g. "--name" must be sent as "title").
	paramKeyOverrides map[string]string

	// disablePositional clears any positionalKey inherited from commands.go,
	// making the command accept the positional value only via an explicit flag.
	disablePositional bool

	// defaultParams are params always included in the RPC call even when the
	// corresponding flag is absent.
	defaultParams map[string]any

	// specialDispatch marks the command as having a custom runXxxRelay function
	// in cli.go. runCLI dispatches to it instead of the generic relay path.
	specialDispatch bool

	// clientOnlyFlags are flag names handled client-side that must NOT be
	// forwarded as RPC params. execV2 filters these out before building params.
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

	// Mac CLI shows "title" as a positional arg; relay accepts --title as a
	// flag instead, so positional args should be rejected.
	"rename-workspace": {
		disablePositional: true,
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
	"close-surface": {
		paramKeyOverrides: map[string]string{"panel": "surface_id"},
	},
	"new-split": {
		paramKeyOverrides: map[string]string{"panel": "surface_id"},
	},

	// --target-pane maps to the server param target_pane_id.
	"join-pane": {
		paramKeyOverrides: map[string]string{"target-pane": "target_pane_id"},
	},
}

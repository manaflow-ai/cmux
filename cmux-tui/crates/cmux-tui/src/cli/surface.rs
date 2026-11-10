//! Which command-line surface (`cmux` or `cmux-tui`) an invocation exposes.

use super::*;

/// Scopes the `cmux` name shows and accepts: the features cmux-next
/// supports (plans/cmux-next/state-ownership.md, section 5). The app scopes
/// (`app`, `action`, `settings`, `window`, `events`) and `acp` route before
/// this parser.
pub(super) const CMUX_SCOPES: &[&str] = &[
    "machine",
    // The session daemon's lifecycle (`server` on the `cmux-tui` surface);
    // `cmux server` is the machine server, routed before this parser.
    "daemon",
    // The whole session (`session current snapshot`, `stop`, the journal) and
    // the clients attached to it: an agent in a cmux-tui pane reads its
    // topology and cleans up with the `cmux` on its PATH, not only `cmux-tui`.
    "session",
    "client",
    "workspace",
    "screen",
    "pane",
    "tab",
    "terminal",
    "browser",
    "notification",
    "settings",
    "attention",
    "agent",
    "room",
    "space",
    "closed",
    "git",
];

/// Which command-line surface this invocation exposes. The binary ships as
/// `cmux` (the curated CLI) and as `cmux-tui` (the full resource grammar its
/// own tooling and Cloud guests use); every other name is `cmux-tui`, so a
/// renamed or test binary keeps the full grammar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Surface {
    Cmux,
    CmuxTui,
}

impl Surface {
    pub(crate) fn for_program(argv0: Option<&std::ffi::OsStr>) -> Self {
        let name = argv0.and_then(|value| std::path::Path::new(value).file_name());
        if name.is_some_and(|name| name == "cmux" || name == "cmux.exe") {
            Self::Cmux
        } else {
            Self::CmuxTui
        }
    }

    pub(super) fn current() -> Self {
        Self::for_program(std::env::args_os().next().as_deref())
    }

    pub(super) fn scopes(self) -> &'static [&'static str] {
        match self {
            Self::Cmux => CMUX_SCOPES,
            Self::CmuxTui => PUBLIC_SCOPES,
        }
    }

    /// Compares canonical scopes, so `daemon` and the internal lifecycle
    /// scope name `server` are one scope.
    pub(super) fn accepts(self, scope: &str) -> bool {
        let scope = shorthand::scope(scope);
        self.scopes().iter().any(|known| shorthand::scope(known) == scope)
    }
}

/// The name this process was run as (`cmux` or `cmux-tui`), read from argv[0]
/// once. Diagnostics start with it: `format!("{BIN}: …")`; `stderr_log!`
/// brings it into scope.
pub(crate) struct ProgramName;

pub(crate) const BIN: ProgramName = ProgramName;

impl std::fmt::Display for ProgramName {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        static SURFACE: std::sync::OnceLock<Surface> = std::sync::OnceLock::new();
        formatter.write_str(match SURFACE.get_or_init(Surface::current) {
            Surface::Cmux => "cmux",
            Surface::CmuxTui => "cmux-tui",
        })
    }
}

/// `cmux machine --help`: the device noun's old name (cmuxterm-hq#7487 item 6). Its verbs stay;
/// the VM verbs are `cmux vm` ([`VM_POINTER`]).
pub(super) const MACHINE_CATALOG_HELP: &str = "\
USAGE
  cmux machine ls [--catalog]
  cmux machine <selector> show [--catalog]
  cmux machine add | revoke | rotate | doctor

`cmux machine` is the old name of `cmux device`: `cmux device <selector> show`
and `cmux device revoke | rotate | doctor` run the same. `cmux device list`
lists every device that can reach this one; `machine ls` is the machine catalog,
whose ids `cmux chat --on` takes. `cmux device --help` has every device verb.

With the cmux app running, `machine ls` also lists its Cloud machines
(`kind: cloud`, `target: vm:<id>`); without it a note says they are missing.
";

/// Where a `machine` help sends a person for VMs: `vm` is the one noun that makes them (CMUX-43).
pub(super) const VM_POINTER: &str = "\
Cloud VMs (new, run, show, pause, resume, rm, exec, key, access) are `cmux vm`:
`cmux vm --help`.
";

/// `cmux vm`'s VM API verbs (cli/vm.rs), in `cmux vm --help` and a `vm` usage error.
pub(super) const VM_VERBS_HELP: &str = "\
Cloud VMs through the cmux VM API (vm.cmux.dev):
  run       Run a command on a fresh VM, deleted when it ends (--sync, --pull, --keep)
  new       Make a Cloud VM (with the app signed in, the one your sidebar
            shows; `cmux vm new --help`)
  show      Show a VM (`cmux vm show ID`)
  pause     Pause a VM, keeping its memory
  resume    Resume a paused VM
  start     Start a stopped VM
  stop      Stop a VM; its disk stays
  rm        Delete a VM for good
  exec      Run a command on a VM
  fork      Fork a VM
  snapshot  Snapshots (new, show, ls, rm)
  access    Short-lived access to one VM (new, ls, revoke, exec)
  key       A VM-only agent key for any process (new, status, revoke)
  creation  Recover a create whose answer was lost (list, get, cancel, reconcile)

`cmux vm access new|exec --target vm:VM_ID` mints access through the
cmux API instead, for the app's Cloud VMs. Use `cmux vm resize` to
resize one.
";

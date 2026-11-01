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

pub(super) const MACHINE_CATALOG_HELP: &str = "\
USAGE
  cmux machine ls [--catalog]
  cmux machine <selector> show [--catalog]
  cmux machine add | revoke | rotate | doctor

With the cmux app running, `machine ls` also lists its Cloud machines
(`kind: cloud`, `target: machine:<id>`); without it a note says they are missing.
";

/// `cmux machine`'s Cloud machine verbs (cli/vm.rs), in every `machine` help.
pub(super) const MACHINE_VM_HELP: &str = "\
Cloud machines through the cmux VM API (vm.cmux.dev):
  run       Run a command on a fresh machine, deleted when it ends (--sync, --pull, --keep)
  new       Create a machine
  show      Show a machine (`cmux machine show ID`)
  pause     Pause a machine, keeping its memory
  resume    Resume a paused machine
  start     Start a stopped machine
  stop      Stop a machine; its disk stays
  rm        Delete a machine for good
  exec      Run a command on a machine
  fork      Fork a machine
  snapshot  Snapshots (new, show, ls, rm)
  access    Short-lived access to one machine (new, ls, revoke, exec)
  key       A machine-only agent key for any process (new, status, revoke)
  creation  Recover a create whose answer was lost (list, get, cancel, reconcile)

`cmux machine access new|exec --target machine:VM_ID` mints access through the
cmux API instead, for `cmux cloud`'s machines. Use `cmux cloud resize-machine`
to resize one.

Old spellings still work: `cmux vm …` for every verb (`cmux vm ls` lists the
VM API's machines), and create, get, delete, `token create` and
`client-session create` for new, show, rm, `key new` and `access new`.
";

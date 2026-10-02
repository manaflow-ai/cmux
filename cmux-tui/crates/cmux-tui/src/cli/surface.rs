//! Which command-line surface (`cmux` or `cmux-tui`) an invocation exposes.

use super::*;

/// Scopes the `cmux` name shows and accepts: the features cmux-next
/// supports (plans/cmux-next/state-ownership.md, section 5). The app scopes
/// (`app`, `action`, `settings`, `window`, `events`) and `acp` route before
/// this parser.
pub(super) const CMUX_SCOPES: &[&str] = &[
    "server",
    "workspace",
    "screen",
    "pane",
    "tab",
    "terminal",
    "browser",
    "notification",
    "agent",
    "room",
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

    pub(super) fn accepts(self, scope: &str) -> bool {
        self.scopes().contains(&scope)
    }
}

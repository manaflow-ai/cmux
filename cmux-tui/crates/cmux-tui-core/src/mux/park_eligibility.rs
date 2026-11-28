//! Which terminals may be parked (`park-tabs`, the PTY reclaim, the idle freeing timer): one rule
//! for every path that ends a shell and keeps its tab
//! (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md, "Which terminal tabs free").
//!
//! A terminal parks only when every fact holds; a fact that cannot be read keeps it running:
//! - no client is attached to any of its views, and `set-terminal-keep` does not keep it;
//! - its workspace is neither pinned nor kept awake (Keep Workspace Awake, which the Mac app
//!   mirrors to the daemon as `keep_awake`), the workspaces the app's own planner keeps
//!   (`WorkspaceFreeingPlanner.Terminal.workspaceKept`); a terminal whose workspace cannot be
//!   found counts as kept;
//! - its state can be saved ([`saved_state_ready`]);
//! - no program reports a status in it (OSC 7501);
//! - no command runs (OSC 133 `C` without `D`);
//! - its shell runs no process at all: no foreground job, no background job (`cmd &`), no
//!   suspended one (vim after ^Z) ([`crate::platform::shell_has_children`]);
//! - its shell sits at its prompt (OSC 133 `A`): a terminal without shell integration never
//!   parks (vim and a prompt look alike).
//!
//! Three waivers, each only where a caller's rules allow it ([`ParkRules`]):
//! - an idle Claude Code or Codex TUI whose session a respawn resumes (the agent roster: idle or
//!   done, with a harness session id) parks with its shell's children
//!   (`workspaces.freeing.agents`, on by default);
//! - a running command parks with its shell when the person chose
//!   `workspaces.freeing.runningCommands: relaunch` (the freed shell offers it again);
//! - `park-tabs` alone also parks a shell nobody used yet that has not drawn its first prompt
//!   (no client input, no command seen, no child): the classic migration parks the workspaces it
//!   brings over right after their shells start.

use super::*;

/// Why a terminal was not parked: `park-tabs`' `refused[].reason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ParkRefusal {
    /// A client holds an attach stream on one of its views.
    Attached,
    /// `set-terminal-keep on`.
    Kept,
    /// Its workspace is pinned or kept awake, or could not be found.
    WorkspaceKept,
    /// Its shell's state cannot be saved yet ([`saved_state_ready`]).
    StateNotSaved,
    /// A program reports a status in it (OSC 7501).
    ProgramStatus,
    /// A command runs in it (OSC 133 `C`).
    CommandRunning,
    /// Its shell runs a process (a job in the foreground, the background or suspended).
    Children,
    /// Its shell's processes could not be read.
    ChildrenUnknown,
    /// Its shell is not at a prompt it reported (OSC 133 `A`), or sends none.
    NoPrompt,
}

impl ParkRefusal {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Attached => "attached",
            Self::Kept => "kept",
            Self::WorkspaceKept => "workspace_kept",
            Self::StateNotSaved => "state_not_saved",
            Self::ProgramStatus => "program_status",
            Self::CommandRunning => "command_running",
            Self::Children => "children",
            Self::ChildrenUnknown => "children_unknown",
            Self::NoPrompt => "no_prompt",
        }
    }
}

/// What a terminal does now, as far as parking it goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct ParkFacts {
    /// A client holds an attach stream on one of its views.
    pub(crate) attached: bool,
    /// `set-terminal-keep on`.
    pub(crate) kept: bool,
    /// Its workspace is pinned or kept awake, or no workspace of it was found.
    pub(crate) workspace_kept: bool,
    /// [`saved_state_ready`].
    pub(crate) saved_state_ready: bool,
    /// A program reports a status in it (OSC 7501).
    pub(crate) program_reported: bool,
    /// A command runs (OSC 133 `C` seen, its `D` not yet).
    pub(crate) command_running: bool,
    /// When its shell drew the prompt it sits at (Unix ms); `None`: a command runs or the shell
    /// sends no OSC 133.
    pub(crate) prompt_since_ms: Option<u64>,
    /// Its shell runs a process of its own; `None`: unknown.
    pub(crate) children: Option<bool>,
    /// A client wrote input, or the shell ran a command, since this daemon saw it start or adopted it.
    pub(crate) used: bool,
    /// The program the terminal started is a shell (or login(1) that starts one).
    pub(crate) shell: bool,
    /// An agent TUI is idle in it with a session a respawn resumes (the agent roster).
    pub(crate) resumable_agent: bool,
}

/// The waivers a caller allows (module docs).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct ParkRules {
    /// An idle agent TUI with a resumable session parks (`workspaces.freeing.agents`).
    pub(crate) agents: bool,
    /// A running command parks with its shell (`workspaces.freeing.runningCommands: relaunch`).
    pub(crate) running_commands: bool,
    /// A shell nobody used that has not drawn its first prompt parks (`park-tabs` only).
    pub(crate) unused_before_prompt: bool,
}

impl ParkRules {
    /// The PTY reclaim: idle shells only, no waiver.
    pub(crate) const PRESSURE: Self =
        Self { agents: false, running_commands: false, unused_before_prompt: false };
}

/// Why `facts` keep the terminal running under `rules`; `None`: it may park.
pub(crate) fn park_refusal(facts: &ParkFacts, rules: ParkRules) -> Option<ParkRefusal> {
    if facts.attached {
        return Some(ParkRefusal::Attached);
    }
    if facts.kept {
        return Some(ParkRefusal::Kept);
    }
    if facts.workspace_kept {
        return Some(ParkRefusal::WorkspaceKept);
    }
    if !facts.saved_state_ready {
        return Some(ParkRefusal::StateNotSaved);
    }
    // The agent path: the respawn resumes the session, so the agent (the shell's child) may end.
    if rules.agents && facts.resumable_agent {
        return None;
    }
    if facts.program_reported {
        return Some(ParkRefusal::ProgramStatus);
    }
    if facts.command_running {
        return (!rules.running_commands).then_some(ParkRefusal::CommandRunning);
    }
    match facts.children {
        None => return Some(ParkRefusal::ChildrenUnknown),
        Some(true) => return Some(ParkRefusal::Children),
        Some(false) => {}
    }
    if facts.prompt_since_ms.is_none()
        && !(rules.unused_before_prompt && !facts.used && facts.shell)
    {
        return Some(ParkRefusal::NoPrompt);
    }
    None
}

/// Whether a terminal's shell state (its environment, functions, history, directory stack) is
/// saved so the shell that starts again on show gets it back. Every shell counts as saveable for
/// now: the shell state save and restore change (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md,
/// a later slice) makes this false for a terminal whose state it could not save, and every park
/// path then keeps that terminal running ([`ParkRefusal::StateNotSaved`]).
pub(crate) fn saved_state_ready(_surface: &Surface) -> bool {
    true
}

/// Login shells and the shells cmux starts: a terminal that runs one of these as its own program
/// has a prompt to come back to.
const SHELLS: &[&str] = &[
    "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish",
    "pwsh", "login",
];

/// Whether `program` (an argv[0] or an executable path) names a shell; a login shell's leading `-`
/// is ignored.
pub(crate) fn is_shell_program(program: &str) -> bool {
    let base = Path::new(program)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    SHELLS.contains(&base.trim_start_matches('-'))
}

#[cfg(test)]
#[path = "park_eligibility_tests.rs"]
mod tests;

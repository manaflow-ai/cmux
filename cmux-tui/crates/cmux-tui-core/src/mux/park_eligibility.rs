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
mod tests {
    use super::*;

    /// A shell idle at its prompt with nothing running: the one case that parks.
    fn idle_shell() -> ParkFacts {
        ParkFacts {
            saved_state_ready: true,
            prompt_since_ms: Some(1_000),
            children: Some(false),
            used: true,
            shell: true,
            ..ParkFacts::default()
        }
    }

    const PARK_TABS: ParkRules =
        ParkRules { agents: true, running_commands: false, unused_before_prompt: true };

    #[test]
    fn only_an_idle_shell_at_its_prompt_parks() {
        let all = [ParkRules::PRESSURE, PARK_TABS];
        let table: [(&str, ParkFacts, Option<ParkRefusal>); 10] = [
            ("prompt idle", idle_shell(), None),
            (
                "a foreground job",
                ParkFacts { children: Some(true), ..idle_shell() },
                Some(ParkRefusal::Children),
            ),
            (
                "a background job or a suspended vim at the prompt",
                ParkFacts { children: Some(true), prompt_since_ms: Some(5), ..idle_shell() },
                Some(ParkRefusal::Children),
            ),
            (
                "children unknown",
                ParkFacts { children: None, ..idle_shell() },
                Some(ParkRefusal::ChildrenUnknown),
            ),
            ("attached", ParkFacts { attached: true, ..idle_shell() }, Some(ParkRefusal::Attached)),
            ("kept", ParkFacts { kept: true, ..idle_shell() }, Some(ParkRefusal::Kept)),
            (
                "a pinned or kept-awake workspace",
                ParkFacts { workspace_kept: true, ..idle_shell() },
                Some(ParkRefusal::WorkspaceKept),
            ),
            (
                "OSC 7501",
                ParkFacts { program_reported: true, ..idle_shell() },
                Some(ParkRefusal::ProgramStatus),
            ),
            (
                "a running command",
                ParkFacts { command_running: true, prompt_since_ms: None, ..idle_shell() },
                Some(ParkRefusal::CommandRunning),
            ),
            (
                "no shell integration",
                ParkFacts { prompt_since_ms: None, ..idle_shell() },
                Some(ParkRefusal::NoPrompt),
            ),
        ];
        for (name, facts, want) in table {
            for rules in all {
                assert_eq!(park_refusal(&facts, rules), want, "{name} under {rules:?}");
            }
        }
        assert_eq!(
            park_refusal(&ParkFacts { saved_state_ready: false, ..idle_shell() }, PARK_TABS),
            Some(ParkRefusal::StateNotSaved),
            "the save-state hook keeps a shell whose state is not saved"
        );
    }

    #[test]
    fn a_resumable_agent_parks_with_its_shells_children_only_when_allowed() {
        let agent = ParkFacts {
            resumable_agent: true,
            program_reported: true,
            children: Some(true),
            prompt_since_ms: None,
            ..idle_shell()
        };
        assert_eq!(park_refusal(&agent, PARK_TABS), None);
        assert_eq!(park_refusal(&agent, ParkRules::PRESSURE), Some(ParkRefusal::ProgramStatus));
        let watched = ParkFacts { attached: true, ..agent };
        assert_eq!(park_refusal(&watched, PARK_TABS), Some(ParkRefusal::Attached));
        let working = ParkFacts { resumable_agent: false, ..agent };
        assert_eq!(park_refusal(&working, PARK_TABS), Some(ParkRefusal::ProgramStatus));
    }

    #[test]
    fn a_running_command_parks_only_under_relaunch() {
        let running = ParkFacts {
            command_running: true,
            children: Some(true),
            prompt_since_ms: None,
            ..idle_shell()
        };
        let relaunch = ParkRules { running_commands: true, ..PARK_TABS };
        assert_eq!(park_refusal(&running, relaunch), None);
        assert_eq!(park_refusal(&running, PARK_TABS), Some(ParkRefusal::CommandRunning));
    }

    #[test]
    fn an_unused_starting_shell_parks_only_through_park_tabs() {
        let starting = ParkFacts { prompt_since_ms: None, used: false, ..idle_shell() };
        assert_eq!(park_refusal(&starting, PARK_TABS), None);
        assert_eq!(park_refusal(&starting, ParkRules::PRESSURE), Some(ParkRefusal::NoPrompt));
        let used = ParkFacts { used: true, ..starting };
        assert_eq!(park_refusal(&used, PARK_TABS), Some(ParkRefusal::NoPrompt));
        let program = ParkFacts { shell: false, ..starting };
        assert_eq!(park_refusal(&program, PARK_TABS), Some(ParkRefusal::NoPrompt));
        let busy = ParkFacts { children: Some(true), ..starting };
        assert_eq!(park_refusal(&busy, PARK_TABS), Some(ParkRefusal::Children));
    }

    #[test]
    fn names_shells_by_their_program() {
        assert!(is_shell_program("/bin/zsh"));
        assert!(is_shell_program("-zsh"));
        assert!(is_shell_program("/usr/bin/login"));
        assert!(!is_shell_program("/usr/local/bin/vim"));
        assert!(!is_shell_program("claude"));
    }
}

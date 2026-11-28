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

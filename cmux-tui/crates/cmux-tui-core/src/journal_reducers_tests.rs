use super::*;
use serde_json::json;

fn hook_event<'a>(
    sequence: u64,
    kind: &'a str,
    subjects: &'a [JournalSubject],
    payload: &'a Value,
) -> RosterEvent<'a> {
    RosterEvent {
        producer_id: AGENT_HOOK_PRODUCER_ID,
        kind,
        subjects,
        payload,
        sequence,
        committed_at_ms: 1_000 + sequence,
    }
}

fn terminal_subject(id: &str) -> Vec<JournalSubject> {
    vec![JournalSubject { kind: "terminal".into(), id: id.into() }]
}

#[test]
fn lifecycle_kinds_fold_into_roster_states() {
    let subjects = terminal_subject("term_a");
    let payload = json!({});
    let mut roster = AgentRoster::default();

    roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload));
    assert_eq!(roster.entries["term_a"].state, "idle");
    assert_eq!(roster.entries["term_a"].agent, None, "payload without adapter has no agent");

    roster.apply(&hook_event(2, "agent.turn.started", &subjects, &payload));
    assert_eq!(roster.entries["term_a"].state, "working");

    roster.apply(&hook_event(3, "agent.approval.requested", &subjects, &payload));
    assert_eq!(roster.entries["term_a"].state, "blocked");

    // Child events carry no top-level transition.
    let deltas = roster.apply(&hook_event(4, "agent.child.spawned", &subjects, &payload));
    assert!(deltas.is_empty());
    assert_eq!(roster.entries["term_a"].state, "blocked");

    let deltas = roster.apply(&hook_event(5, "agent.session.ended", &subjects, &payload));
    assert_eq!(
        deltas,
        vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Hook }]
    );
    assert!(roster.entries.is_empty());
}

const CLAUDE_TERMINAL: &str = "term_00000000000000000000000000000001";

/// Folds one Claude hook event per `(native event, tool)` into a roster and returns the
/// terminal's state after each one (empty while it has no entry). The events come from
/// `agent_hook_journal_ingress`, so their kinds are the ones a real hook produces.
fn claude_roster_states(events: &[(&str, &str)]) -> Vec<String> {
    let mut roster = AgentRoster::default();
    let mut states = Vec::new();
    for (index, (native_event, tool)) in events.iter().enumerate() {
        let ingress = crate::agent_hook_journal_ingress(
            "claude",
            native_event,
            Some(CLAUDE_TERMINAL),
            json!({"tool_name": tool}),
        )
        .unwrap();
        roster.apply(&RosterEvent {
            producer_id: &ingress.producer_id,
            kind: &ingress.kind,
            subjects: &ingress.subjects,
            payload: &ingress.payload,
            sequence: index as u64 + 1,
            committed_at_ms: 1_000 + index as u64,
        });
        states.push(
            roster
                .entries
                .get(CLAUDE_TERMINAL)
                .map(|entry| entry.state.clone())
                .unwrap_or_default(),
        );
    }
    states
}

/// A question blocks the agent; the tool call that completes after the person answers it
/// resumes the agent, which is still in its turn. Before the fix the answer's PostToolUse
/// re-raised the question, so the agent stayed blocked (and the sidebar's dot stayed orange)
/// until the turn ended.
#[test]
fn a_completed_question_tool_call_resumes_a_blocked_agent() {
    assert_eq!(
        claude_roster_states(&[
            ("PreToolUse", "AskUserQuestion"),
            ("PostToolUse", "AskUserQuestion")
        ]),
        ["blocked", "working"],
    );
}

/// An approved permission blocks the agent until its tool call completes.
#[test]
fn a_completed_approved_tool_call_resumes_a_blocked_agent() {
    assert_eq!(
        claude_roster_states(&[("PermissionRequest", "Bash"), ("PostToolUse", "Bash")]),
        ["blocked", "working"],
    );
}

/// A failed tool call is a step of a running turn, not a question for the person.
#[test]
fn a_failed_tool_call_does_not_block_a_working_agent() {
    assert_eq!(
        claude_roster_states(&[("UserPromptSubmit", "Bash"), ("PostToolUseFailure", "Bash")]),
        ["working", "working"],
    );
}

/// A tool call that completes after the turn ended changes nothing: only a blocked agent
/// resumes, so a finished one is not woken into a turn it never started.
#[test]
fn a_completed_tool_call_leaves_a_finished_turn_alone() {
    assert_eq!(
        claude_roster_states(&[
            ("UserPromptSubmit", "Bash"),
            ("Stop", ""),
            ("PostToolUse", "Bash")
        ]),
        ["working", "idle", "idle"],
    );
}

fn session_payload(session_id: &str) -> Value {
    json!({"normalized": {"agent_session_id": session_id}})
}

#[test]
fn journal_roster_ignores_hook_events_from_ended_or_superseded_sessions() {
    let subjects = terminal_subject("term_a");
    let old = session_payload("old");
    let new = session_payload("new");
    let mut roster = AgentRoster::default();

    roster.apply(&hook_event(1, "agent.session.ended", &subjects, &old));
    roster.apply(&hook_event(2, "agent.session.started", &subjects, &new));
    assert_eq!(roster.entries["term_a"].state, "idle");
    // A late turn from the ended session is fenced out.
    assert!(roster.apply(&hook_event(3, "agent.turn.started", &subjects, &old)).is_empty());
    // So is a session-less event once a native session owns the terminal.
    let sessionless = json!({});
    assert!(roster.apply(&hook_event(4, "agent.turn.started", &subjects, &sessionless)).is_empty());
    // A replayed or reordered sequence cannot rewind the fence.
    assert!(roster.apply(&hook_event(2, "agent.turn.started", &subjects, &new)).is_empty());
    assert_eq!(roster.entries["term_a"].state, "idle");
    assert_eq!(
        roster.hook_fences["term_a"],
        HookFence { session_id: "new".into(), sequence: 2, ended: false, ended_at_ms: None }
    );

    roster.apply(&hook_event(5, "agent.turn.started", &subjects, &new));
    assert_eq!(roster.entries["term_a"].state, "working");
    // The fence survives a snapshot round trip.
    let restored = AgentRoster::restore(&roster.snapshot().to_string()).unwrap();
    assert_eq!(restored.hook_fences, roster.hook_fences);
}

#[test]
fn journal_roster_hook_echo_restarts_an_ended_fence_like_the_projector() {
    let subjects = terminal_subject("term_a");
    let old = session_payload("old");
    let echo = |session: &str| {
        json!({
            "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
            "normalized": {"state": "working", "source": "hook", "source_session": session},
        })
    };
    let mut roster = AgentRoster::default();
    roster.apply(&hook_event(1, "agent.session.ended", &subjects, &old));

    // An echo that names the ended session cannot reopen it.
    let stale = echo("old");
    assert!(roster.apply(&hook_event(2, "agent.state.changed", &subjects, &stale)).is_empty());
    assert!(roster.entries.is_empty());

    let fresh = echo("new");
    roster.apply(&hook_event(3, "agent.state.changed", &subjects, &fresh));
    assert_eq!(roster.entries["term_a"].state, "working");
    assert_eq!(
        roster.hook_fences["term_a"],
        HookFence { session_id: "new".into(), sequence: 1, ended: false, ended_at_ms: None }
    );
    let completed = session_payload("old");
    assert!(roster.apply(&hook_event(4, "agent.turn.completed", &subjects, &completed)).is_empty());
    let completed = session_payload("new");
    roster.apply(&hook_event(5, "agent.turn.completed", &subjects, &completed));
    assert_eq!(roster.entries["term_a"].state, "idle");
}

#[test]
fn journal_roster_resume_without_observation_stamps_starts_a_new_incarnation() {
    // Older hook helpers do not stamp observations. A same-id start after
    // an end cannot be proven stale, so it resumes the session.
    let subjects = terminal_subject("term_a");
    let payload = session_payload("a");
    let mut roster = AgentRoster::default();
    roster.apply(&hook_event(1, "agent.session.started", &subjects, &payload));
    roster.apply(&hook_event(2, "agent.session.ended", &subjects, &payload));
    assert!(roster.entries.is_empty());
    assert!(roster.apply(&hook_event(3, "agent.turn.started", &subjects, &payload)).is_empty());
    roster.apply(&hook_event(4, "agent.session.started", &subjects, &payload));
    assert_eq!(roster.entries["term_a"].state, "idle");
    assert_eq!(
        roster.hook_fences["term_a"],
        HookFence { session_id: "a".into(), sequence: 4, ended: false, ended_at_ms: None }
    );
}

#[test]
fn journal_roster_retiring_a_terminal_drops_its_hook_fence() {
    let subjects = terminal_subject("term_a");
    let ended = session_payload("old");
    let mut roster = AgentRoster::default();
    roster.apply(&hook_event(1, "agent.session.ended", &subjects, &ended));
    assert!(roster.entries.is_empty());
    assert!(roster.retire_terminal("term_a"), "the fence alone must persist its removal");
    assert!(roster.hook_fences.is_empty());
}

#[test]
fn socket_echo_carries_explicit_state_and_loses_to_hook_entries() {
    let subjects = terminal_subject("term_a");
    let socket_payload = json!({
        "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
        "normalized": {"state": "working", "source": "socket", "source_session": "probe"},
    });
    let mut roster = AgentRoster::default();

    roster.apply(&hook_event(1, "agent.state.changed", &subjects, &socket_payload));
    let entry = &roster.entries["term_a"];
    assert_eq!(entry.state, "working");
    assert_eq!(entry.source, "socket");
    assert_eq!(entry.session.as_deref(), Some("probe"));
    assert_eq!(entry.agent, None);

    // A hook event takes the terminal over and names the agent...
    let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
    roster.apply(&hook_event(2, "agent.turn.started", &subjects, &hook_payload));
    assert_eq!(roster.entries["term_a"].source, "hook");
    assert_eq!(roster.entries["term_a"].agent.as_deref(), Some("claude"));

    // ...and later socket reports cannot downgrade it.
    let deltas = roster.apply(&hook_event(3, "agent.state.changed", &subjects, &socket_payload));
    assert!(deltas.is_empty());
    assert_eq!(roster.entries["term_a"].source, "hook");
}

#[test]
fn folds_are_idempotent_per_state_and_deterministic_across_replays() {
    let subjects = terminal_subject("term_a");
    let payload = json!({});
    let events = [
        "agent.session.started",
        "agent.turn.started",
        "agent.turn.started",
        "agent.turn.completed",
    ];

    let mut live = AgentRoster::default();
    let mut delta_count = 0usize;
    for (index, kind) in events.iter().enumerate() {
        delta_count += live.apply(&hook_event(index as u64 + 1, kind, &subjects, &payload)).len();
    }
    // A same-state re-report still refreshes recency (chronological
    // views sort on it), so every event here produces a delta.
    assert_eq!(delta_count, 4);

    let mut replayed = AgentRoster::default();
    for (index, kind) in events.iter().enumerate() {
        replayed.apply(&hook_event(index as u64 + 1, kind, &subjects, &payload));
    }
    assert_eq!(serde_json::to_value(&live).unwrap(), serde_json::to_value(&replayed).unwrap());
}

fn stamped_event<'a>(
    committed_at_ms: u64,
    kind: &'a str,
    subjects: &'a [JournalSubject],
    payload: &'a Value,
) -> RosterEvent<'a> {
    RosterEvent {
        producer_id: AGENT_HOOK_PRODUCER_ID,
        kind,
        subjects,
        payload,
        sequence: committed_at_ms,
        committed_at_ms,
    }
}

fn screen_payload(agent: &str, state: &str) -> Value {
    json!({
        "format": "cmux.agent-hook.v1",
        "adapter": {"id": agent, "version": 1},
        "native_event": "ScreenDetect",
        "normalized": {"state": state},
        "native": {},
    })
}

#[test]
fn screen_detect_events_fold_with_detected_source_and_adapter_agent() {
    let subjects = terminal_subject("term_a");
    let payload = screen_payload("codex", "working");
    let mut roster = AgentRoster::default();

    let deltas = roster.apply(&stamped_event(5_000, "agent.state.changed", &subjects, &payload));
    assert_eq!(deltas.len(), 1);
    let entry = &roster.entries["term_a"];
    assert_eq!(entry.state, "working");
    assert_eq!(entry.source, "detected");
    assert_eq!(entry.agent.as_deref(), Some("codex"));
    assert_eq!(entry.updated_at_ms, 5_000);
}

#[test]
fn screen_detect_loses_to_fresh_hooks_and_claims_stale_ones() {
    let subjects = terminal_subject("term_a");
    let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
    let screen = screen_payload("claude", "blocked");
    let mut roster = AgentRoster::default();

    roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
    // A fresh hook entry (29s old) is live agent truth.
    let deltas = roster.apply(&stamped_event(39_000, "agent.state.changed", &subjects, &screen));
    assert!(deltas.is_empty());
    assert_eq!(roster.entries["term_a"].source, "hook");

    // At 30s the hook is stale and screen detection takes over.
    let deltas = roster.apply(&stamped_event(40_000, "agent.state.changed", &subjects, &screen));
    assert_eq!(deltas.len(), 1);
    assert_eq!(roster.entries["term_a"].source, "detected");
    assert_eq!(roster.entries["term_a"].state, "blocked");

    // A hook event always reclaims the terminal.
    let deltas =
        roster.apply(&stamped_event(41_000, "agent.turn.started", &subjects, &hook_payload));
    assert_eq!(deltas.len(), 1);
    assert_eq!(roster.entries["term_a"].source, "hook");
}

#[test]
fn legacy_detected_source_reclaims_a_stale_hook_at_the_boundary() {
    let subjects = terminal_subject("term_a");
    let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
    let screen = screen_payload("claude", "idle");
    let mut roster = AgentRoster::default();

    roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
    let deltas = roster.apply(&stamped_event(
        10_000 + STALE_HOOK_MS,
        "agent.state.changed",
        &subjects,
        &screen,
    ));

    assert_eq!(deltas.len(), 1);
    assert_eq!(roster.entries["term_a"].source, "detected");
    assert_eq!(roster.entries["term_a"].state, "idle");
}

#[test]
fn screen_detect_beats_socket_reports_in_both_directions() {
    let subjects = terminal_subject("term_a");
    let socket_payload = json!({
        "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
        "normalized": {"state": "idle", "source": "socket"},
    });
    let screen = screen_payload("codex", "working");
    let mut roster = AgentRoster::default();

    // Screen detection overwrites a socket-owned entry...
    roster.apply(&stamped_event(1_000, "agent.state.changed", &subjects, &socket_payload));
    let deltas = roster.apply(&stamped_event(2_000, "agent.state.changed", &subjects, &screen));
    assert_eq!(deltas.len(), 1);
    assert_eq!(roster.entries["term_a"].source, "detected");

    // ...and a later socket report cannot downgrade it.
    let deltas =
        roster.apply(&stamped_event(3_000, "agent.state.changed", &subjects, &socket_payload));
    assert!(deltas.is_empty());
    assert_eq!(roster.entries["term_a"].source, "detected");
    assert_eq!(roster.entries["term_a"].state, "working");
}

#[test]
fn screen_detect_exit_removes_only_detected_entries() {
    let subjects = terminal_subject("term_a");
    let done = screen_payload("codex", "done");
    let mut roster = AgentRoster::default();

    // Detected entry: the agent process left the pane -> removal.
    roster.apply(&stamped_event(
        1_000,
        "agent.state.changed",
        &subjects,
        &screen_payload("codex", "working"),
    ));
    let deltas = roster.apply(&stamped_event(2_000, "agent.session.ended", &subjects, &done));
    assert_eq!(
        deltas,
        vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Detected }]
    );
    assert!(roster.entries.is_empty());

    // A fresh hook entry is never removed by a screen exit.
    let hook_payload = json!({"adapter": {"id": "claude", "version": 1}});
    roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
    let deltas = roster.apply(&stamped_event(11_000, "agent.session.ended", &subjects, &done));
    assert!(deltas.is_empty());
    assert_eq!(roster.entries["term_a"].source, "hook");

    // A socket entry is not removed by a screen exit either.
    let mut socket_roster = AgentRoster::default();
    let socket_payload = json!({
        "adapter": {"id": SOCKET_REPORT_ADAPTER, "version": 1},
        "normalized": {"state": "idle", "source": "socket"},
    });
    socket_roster.apply(&stamped_event(1_000, "agent.state.changed", &subjects, &socket_payload));
    let deltas =
        socket_roster.apply(&stamped_event(2_000, "agent.session.ended", &subjects, &done));
    assert!(deltas.is_empty());
    assert_eq!(socket_roster.entries["term_a"].source, "socket");
}

#[test]
fn userland_plugin_events_fold_without_core_vendor_knowledge() {
    let subjects = terminal_subject("term_a");
    let working = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id":"screen_detector","version":1},
        "adapter": {"id":"codex","version":1},
        "event":"state.changed",
        "normalized": {
            "state":"working",
            "source_session":"pid:42",
            "observed_at_ms":"1000"
        }
    });
    let ended = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id":"screen_detector","version":1},
        "adapter": {"id":"codex","version":1},
        "event":"session.ended",
        "normalized": {
            "state":"done",
            "source_session":"pid:42",
            "observed_at_ms":"2000"
        }
    });
    let mut roster = AgentRoster::default();
    let event = RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &working,
        sequence: 1000,
        committed_at_ms: 1000,
    };
    let deltas = roster.apply(&event);
    assert_eq!(deltas.len(), 1);
    assert_eq!(roster.entries["term_a"].source, "plugin");
    assert_eq!(roster.entries["term_a"].agent.as_deref(), Some("codex"));

    let event = RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.session.ended",
        subjects: &subjects,
        payload: &ended,
        sequence: 2000,
        committed_at_ms: 2000,
    };
    assert_eq!(
        roster.apply(&event),
        vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Plugin }]
    );
    assert!(roster.entries.is_empty());
}

#[test]
fn fresh_hook_wins_over_plugin_and_stale_hook_can_be_replaced() {
    let subjects = terminal_subject("term_a");
    let hook_payload = json!({"adapter":{"id":"claude","version":1}});
    let plugin_payload = |observed_at_ms: u64| {
        json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"claude","version":1},
            "event":"state.changed",
            "normalized":{
                "state":"blocked",
                "source_session":"pid:42",
                "observed_at_ms":observed_at_ms.to_string()
            }
        })
    };
    let mut roster = AgentRoster::default();
    roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
    let first_plugin_payload = plugin_payload(39_000);
    let plugin = RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &first_plugin_payload,
        sequence: 39_000,
        committed_at_ms: 39_000,
    };
    assert!(roster.apply(&plugin).is_empty());
    assert_eq!(roster.entries["term_a"].source, "hook");
    let plugin_payload = plugin_payload(40_000);
    let plugin = RosterEvent { payload: &plugin_payload, committed_at_ms: 40_000, ..plugin };
    assert_eq!(roster.apply(&plugin).len(), 1);
    assert_eq!(roster.entries["term_a"].source, "plugin");
}

#[test]
fn an_older_plugin_observation_cannot_reclaim_a_hook_row() {
    let subjects = terminal_subject("term_a");
    let hook_payload = json!({"adapter":{"id":"claude","version":1}});
    let plugin_payload = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id":"screen_detector","version":1},
        "adapter": {"id":"claude","version":1},
        "event":"state.changed",
        "normalized":{"state":"blocked","source_session":"pid:42","observed_at_ms":"9000"}
    });
    let mut roster = AgentRoster::default();
    roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
    let plugin = RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &plugin_payload,
        sequence: 50_000,
        committed_at_ms: 50_000,
    };
    assert!(roster.apply(&plugin).is_empty());
    assert_eq!(roster.entries["term_a"].source, "hook");
}

#[test]
fn future_plugin_observation_cannot_outdate_a_live_hook() {
    let subjects = terminal_subject("term_a");
    let hook_payload = json!({"adapter":{"id":"claude","version":1}});
    let plugin_payload = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id":"screen_detector","version":1},
        "adapter": {"id":"claude","version":1},
        "event":"state.changed",
        "normalized": {
            "state":"blocked",
            "source_session":"pid:42",
            "observed_at_ms":u64::MAX.to_string()
        }
    });
    let mut roster = AgentRoster::default();
    roster.apply(&stamped_event(10_000, "agent.turn.started", &subjects, &hook_payload));
    let plugin = RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &plugin_payload,
        sequence: 20_000,
        committed_at_ms: 20_000,
    };
    assert!(roster.apply(&plugin).is_empty());
    assert_eq!(roster.entries["term_a"].source, "hook");
}

#[test]
fn supervisor_exit_retires_only_old_entries_for_that_plugin() {
    let subjects_a = terminal_subject("term_a");
    let subjects_b = terminal_subject("term_b");
    let payload = |session: &str, timestamp: u64| {
        json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":session,
                "observed_at_ms":timestamp.to_string()
            }
        })
    };
    let mut roster = AgentRoster::default();
    let first = payload("pid:1", 100);
    let second = payload("pid:2", 300);
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects_a,
        payload: &first,
        sequence: 100,
        committed_at_ms: 100,
    });
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects_b,
        payload: &second,
        sequence: 300,
        committed_at_ms: 300,
    });
    let exit = json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
        "adapter":{"id":"cmux","version":1},
        "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
        "normalized":{"plugin_id":"screen_detector","observed_at_ms":"200"},
        "native":{}
    });
    let deltas = roster.apply(&RosterEvent {
        producer_id: AGENT_HOOK_PRODUCER_ID,
        kind: "agent.plugin.exited",
        subjects: &[],
        payload: &exit,
        sequence: 200,
        committed_at_ms: 200,
    });
    assert_eq!(
        deltas,
        vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Plugin }]
    );
    assert!(!roster.entries.contains_key("term_a"));
    assert!(roster.entries.contains_key("term_b"));
}

#[test]
fn late_exit_from_an_old_plugin_generation_cannot_remove_replacement_rows() {
    let subjects = terminal_subject("term_a");
    let event = |generation: &str, timestamp: u64| {
        let payload = json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":"pid:42",
                "plugin_generation":generation,
                "observed_at_ms":timestamp.to_string()
            }
        });
        (payload, timestamp)
    };
    let (old_payload, old_time) = event("1", 100);
    let (new_payload, new_time) = event("2", 200);
    let mut roster = AgentRoster::default();
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &old_payload,
        sequence: old_time,
        committed_at_ms: old_time,
    });
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &new_payload,
        sequence: new_time,
        committed_at_ms: new_time,
    });
    let exit = json!({
        "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
        "adapter":{"id":"cmux","version":1},
        "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
        "normalized": {
            "plugin_id":"screen_detector",
            "plugin_generation":"1",
            "observed_at_ms":"300"
        },
        "native":{}
    });
    assert!(
        roster
            .apply(&RosterEvent {
                producer_id: AGENT_HOOK_PRODUCER_ID,
                kind: "agent.plugin.exited",
                subjects: &[],
                payload: &exit,
                sequence: 300,
                committed_at_ms: 300,
            })
            .is_empty()
    );
    assert_eq!(roster.entries["term_a"].producer_generation.as_deref(), Some("2"));
}

#[test]
fn late_observation_from_an_exited_plugin_generation_cannot_recreate_a_row() {
    let subjects = terminal_subject("term_a");
    let payload = |observed_at_ms: u64| {
        json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":"pid:42",
                "plugin_generation":"1",
                "observed_at_ms": observed_at_ms.to_string()
            }
        })
    };
    let mut roster = AgentRoster::default();
    let first = payload(100);
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &first,
        sequence: 100,
        committed_at_ms: 100,
    });
    let exit = json!({
        "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
        "adapter":{"id":"cmux","version":1},
        "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
        "normalized": {
            "plugin_id":"screen_detector",
            "plugin_generation":"1",
            "observed_at_ms":"200"
        },
        "native":{}
    });
    assert_eq!(
        roster.apply(&RosterEvent {
            producer_id: AGENT_HOOK_PRODUCER_ID,
            kind: "agent.plugin.exited",
            subjects: &[],
            payload: &exit,
            sequence: 200,
            committed_at_ms: 200,
        }),
        vec![RosterDelta::Remove { terminal_id: "term_a".into(), source: AgentSource::Plugin }]
    );
    let late = payload(300);
    assert!(
        roster
            .apply(&RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &late,
                sequence: 300,
                committed_at_ms: 300,
            })
            .is_empty()
    );
    assert!(!roster.entries.contains_key("term_a"));
}

#[test]
fn newer_plugin_generation_can_claim_after_an_exit_fence() {
    let subjects = terminal_subject("term_a");
    let payload = |generation: &str, observed_at_ms: u64| {
        json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":"working",
                "source_session":"pid:42",
                "plugin_generation":generation,
                "observed_at_ms": observed_at_ms.to_string()
            }
        })
    };
    let exit = |generation: &str, observed_at_ms: u64| {
        json!({
            "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
            "adapter":{"id":"cmux","version":1},
            "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
            "normalized": {
                "plugin_id":"screen_detector",
                "plugin_generation":generation,
                "observed_at_ms": observed_at_ms.to_string()
            },
            "native":{}
        })
    };
    let mut roster = AgentRoster::default();
    let old = payload("1", 100);
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &old,
        sequence: 100,
        committed_at_ms: 100,
    });
    let old_exit = exit("1", 200);
    roster.apply(&RosterEvent {
        producer_id: AGENT_HOOK_PRODUCER_ID,
        kind: "agent.plugin.exited",
        subjects: &[],
        payload: &old_exit,
        sequence: 200,
        committed_at_ms: 200,
    });
    let replacement = payload("2", 150);
    assert_eq!(
        roster
            .apply(&RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &replacement,
                sequence: 300,
                committed_at_ms: 300,
            })
            .len(),
        1
    );
    assert_eq!(roster.entries["term_a"].producer_generation.as_deref(), Some("2"));
}

#[test]
fn untagged_plugin_exit_cannot_remove_a_tagged_child() {
    let subjects = terminal_subject("term_a");
    let payload = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id":"screen_detector","version":1},
        "adapter": {"id":"codex","version":1},
        "event":"state.changed",
        "normalized": {
            "state":"working",
            "source_session":"pid:42",
            "plugin_generation":"7",
            "observed_at_ms":"100"
        }
    });
    let mut roster = AgentRoster::default();
    assert_eq!(
        roster
            .apply(&RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &payload,
                sequence: 100,
                committed_at_ms: 100,
            })
            .len(),
        1
    );

    let exit = json!({
        "format": crate::agent_hooks::AGENT_HOOK_FORMAT,
        "adapter":{"id":"cmux","version":1},
            "native_event": crate::agent_hooks::JOURNAL_PLUGIN_EXIT_NATIVE_EVENT,
        "normalized":{"plugin_id":"screen_detector","observed_at_ms":"200"},
        "native":{}
    });
    assert!(
        roster
            .apply(&RosterEvent {
                producer_id: AGENT_HOOK_PRODUCER_ID,
                kind: "agent.plugin.exited",
                subjects: &[],
                payload: &exit,
                sequence: 200,
                committed_at_ms: 200,
            })
            .is_empty()
    );
    assert!(roster.entries.contains_key("term_a"));
}

#[test]
fn stale_plugin_observations_cannot_regress_a_generation() {
    let subjects = terminal_subject("term_a");
    let payload = |generation: &str, state: &str, observed_at_ms: &str| {
        json!({
            "format": AGENT_PLUGIN_FORMAT,
            "plugin": {"id":"screen_detector","version":1},
            "adapter": {"id":"codex","version":1},
            "event":"state.changed",
            "normalized": {
                "state":state,
                "source_session":"pid:42",
                "plugin_generation":generation,
                "observed_at_ms":observed_at_ms
            }
        })
    };
    let mut roster = AgentRoster::default();
    let current = payload("2", "working", "200");
    roster.apply(&RosterEvent {
        producer_id: "screen_detector",
        kind: "plugin.screen_detector.agent.state.changed",
        subjects: &subjects,
        payload: &current,
        sequence: 200,
        committed_at_ms: 200,
    });
    let old_timestamp = payload("2", "blocked", "100");
    assert!(
        roster
            .apply(&RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &old_timestamp,
                sequence: 300,
                committed_at_ms: 300,
            })
            .is_empty()
    );
    assert_eq!(roster.entries["term_a"].state, "working");

    let old_generation = payload("1", "blocked", "999");
    assert!(
        roster
            .apply(&RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &old_generation,
                sequence: 999,
                committed_at_ms: 999,
            })
            .is_empty()
    );
    assert_eq!(roster.entries["term_a"].producer_generation.as_deref(), Some("2"));
}

#[test]
fn malformed_plugin_envelopes_never_enter_the_roster() {
    let subjects = terminal_subject("term_a");
    let valid = json!({
        "format": AGENT_PLUGIN_FORMAT,
        "plugin": {"id":"screen_detector","version":1},
        "adapter": {"id":"codex","version":1},
        "event":"state.changed",
        "normalized": {
            "state":"working",
            "source_session":"pid:42",
            "observed_at_ms":"100"
        }
    });
    let malformed = [
        json!({"format":"wrong","plugin":{"id":"screen_detector","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42","observed_at_ms":"100"}}),
        json!({"format":AGENT_PLUGIN_FORMAT,"plugin":{"id":"other","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42","observed_at_ms":"100"}}),
        json!({"format":AGENT_PLUGIN_FORMAT,"plugin":{"id":"screen_detector","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42"}}),
        json!({"format":AGENT_PLUGIN_FORMAT,"plugin":{"id":"screen_detector","version":1},"adapter":{"id":"codex","version":1},"event":"state.changed","normalized":{"state":"working","source_session":"pid:42","plugin_generation":7,"observed_at_ms":"100"}}),
    ];
    for payload in malformed {
        let event = RosterEvent {
            producer_id: "screen_detector",
            kind: "plugin.screen_detector.agent.state.changed",
            subjects: &subjects,
            payload: &payload,
            sequence: 100,
            committed_at_ms: 100,
        };
        let mut roster = AgentRoster::default();
        assert!(roster.apply(&event).is_empty());
        assert!(roster.entries.is_empty());
    }
    let mut roster = AgentRoster::default();
    assert_eq!(
        roster
            .apply(&RosterEvent {
                producer_id: "screen_detector",
                kind: "plugin.screen_detector.agent.state.changed",
                subjects: &subjects,
                payload: &valid,
                sequence: 100,
                committed_at_ms: 100,
            })
            .len(),
        1
    );
}

#[test]
fn snapshot_round_trips_and_foreign_producers_are_ignored() {
    let subjects = terminal_subject("term_a");
    let payload = json!({});
    let mut roster = AgentRoster::default();
    roster.apply(&hook_event(1, "agent.turn.started", &subjects, &payload));

    let snapshot = roster.snapshot().to_string();
    let restored = AgentRoster::restore(&snapshot).unwrap();
    assert_eq!(restored.entries, roster.entries);

    let foreign = RosterEvent {
        producer_id: "someone_else",
        ..hook_event(2, "agent.session.ended", &subjects, &payload)
    };
    assert!(roster.apply(&foreign).is_empty());
    assert!(!roster.entries.is_empty());
}

#[test]
fn restore_rejects_unknown_entry_semantics() {
    let snapshot = json!({
        "entries": {
            "term_a": {
                "state": "working",
                "source": "stronger-than-hook",
                "producer": null,
                "producer_generation": null,
                "session": null,
                "agent": null,
                "updated_at_ms": 1
            }
        },
        "plugin_exit_fences": {}
    })
    .to_string();

    assert!(AgentRoster::restore(&snapshot).is_none());
}

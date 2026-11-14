use super::*;
use serde_json::json;

#[test]
fn socket_attention_becomes_the_vm_principal_op() {
    let mut session = Session::new(
        "vm_m0000000000000000001",
        DaemonInfo { version: "test".into(), capabilities: vec![] },
        60_000,
    );
    let line = json!({
        "attention": {
            "event_id": "attn_1", "kind": "question", "session": "acp_s1",
            "title": "Cloud chat", "occurred_at": 1_790_000_000_000u64
        }
    })
    .to_string();
    let (requests, note) = session.line(&line, 1);
    assert!(note.is_none());
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].op, ATTENTION_EMIT_OP);
    assert_eq!(requests[0].params["event_id"], "attn_1");
    assert!(requests[0].params.get("body").is_none());
    let (next, note) = session.answered(
        &requests[0],
        &Answer::Http { status: 200, body: json!({"ok": true}) },
        2,
        0.5,
    );
    assert!(note.is_none());
    assert!(next.is_empty());
    assert_eq!(session.attention.len(), 0);
}
fn session() -> Session {
    Session::new(
        "vm_m0000000000000000001",
        DaemonInfo { version: "test".into(), capabilities: vec![] },
        3_600_000,
    )
}

fn ok() -> Answer {
    Answer::Http { status: 200, body: json!({"ok": true, "value": {"applied": true}}) }
}

fn acp(turns: u64, at: Option<u64>) -> String {
    let mut a = json!({"turns": turns});
    if let Some(at) = at {
        a["last_agent_action_at"] = json!(at);
    }
    json!({"acp_activity": a}).to_string()
}

/// A Cloud chat mid-turn with no app attached: the daemon sees no session, acpmux one.
/// The report counts it; once the turn ends the count drops and the end is the last action.
#[test]
fn a_running_acpmux_turn_with_no_attached_client_is_active_until_it_ends() {
    let mut s = session();
    let start = s.start(0);
    s.answered(&start[0], &ok(), 0, 0.5);
    let idle = json!({"attached_clients": 0, "live_agents": 0});
    let r = s.daemon_activity(&idle, 100);
    assert!(r.is_empty(), "inside the 10 s window");
    // Past the window: the held report goes with 0 sessions.
    let r = s.fire(20_000);
    assert_eq!(r[0].params["activity"]["active_sessions"], 0);
    s.answered(&r[0], &ok(), 20_000, 0.5);

    let (r, note) = s.line(&acp(1, Some(1_790_000_000_000)), 40_000);
    assert!(note.is_none());
    assert_eq!(r.len(), 1, "a turn that starts is reported at once");
    assert_eq!(r[0].params["activity"]["active_sessions"], 1);
    assert_eq!(r[0].params["activity"]["last_agent_action_at"], 1_790_000_000_000u64);
    s.answered(&r[0], &ok(), 40_000, 0.5);

    // The daemon's own change never overwrites acpmux's count.
    let r = s.daemon_activity(&idle, 60_000);
    assert_eq!(r[0].params["activity"]["active_sessions"], 1);
    s.answered(&r[0], &ok(), 60_000, 0.5);

    // A renewal with a newer action changes no count: no report, the time rides along.
    let (r, _) = s.line(&acp(1, Some(1_790_000_020_000)), 80_000);
    assert!(r.is_empty(), "no report for a renewal while a turn runs");
    assert_eq!(s.reporter.activity().last_agent_action_at, Some(1_790_000_020_000));

    // The turn ends: the count drops and the end time is the last agent action.
    let end = 1_790_000_030_000u64;
    let (r, _) = s.line(&acp(0, Some(end)), 90_000);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].params["activity"]["active_sessions"], 0);
    assert_eq!(r[0].params["activity"]["last_agent_action_at"], end);
    assert_eq!(s.acp.next_expiry(), Some(90_000 + ACP_ACTIVITY_TTL_MS), "known until then");
}

/// Counts add up: an attached client and a running turn are two open sessions.
#[test]
fn the_daemon_count_and_acpmux_turns_add_up() {
    let mut s = session();
    s.line(&acp(2, None), 0);
    s.daemon_activity(&json!({"attached_clients": 1, "live_agents": 0}), 0);
    assert_eq!(s.reporter.activity().active_sessions, 3);
    s.line(&json!({"activity": {"active_sessions": 0}}).to_string(), 0);
    assert_eq!(s.reporter.activity().active_sessions, 2, "a socket activity line keeps acpmux's");
}

/// acpmux that stops renewing mid-turn (it died) stops counting after the TTL, so the
/// machine can go idle again.
#[test]
fn an_acpmux_count_not_renewed_expires() {
    let mut s = session();
    let start = s.start(0);
    s.answered(&start[0], &ok(), 0, 0.5);
    let (r, _) = s.line(&acp(1, Some(5)), 20_000);
    s.answered(&r[0], &ok(), 20_000, 0.5);
    assert_eq!(s.next_deadline(), Some(20_000 + ACP_ACTIVITY_TTL_MS));
    assert!(s.fire(20_000 + ACP_ACTIVITY_TTL_MS - 1).is_empty());
    let r = s.fire(20_000 + ACP_ACTIVITY_TTL_MS);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].params["activity"]["active_sessions"], 0);
    assert_eq!(r[0].params["activity"]["last_agent_action_at"], 5);
}

/// `activity-turns` travels with `activity`, only while acpmux's count is known: an agent
/// that just started has not heard from acpmux, so its 0 is not a known 0.
#[test]
fn activity_turns_is_advertised_only_while_acpmux_reports() {
    use super::super::wire::{
        ACTIVITY_CAPABILITY, ACTIVITY_PHASES_CAPABILITY, ACTIVITY_TURNS_CAPABILITY,
    };
    let base = DaemonInfo { version: "v".into(), capabilities: vec!["fs-v1".into()] };
    let both = base.with_activity(true, true, false);
    assert_eq!(both.capabilities, ["fs-v1", ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY]);
    assert_eq!(both.with_activity(true, true, false), both, "never twice");
    assert_eq!(
        both.with_activity(true, false, true).capabilities,
        ["fs-v1", ACTIVITY_CAPABILITY],
        "never `activity-phases` without `activity-turns`"
    );
    assert_eq!(both.with_activity(false, true, true), base, "never without `activity`");
    assert_eq!(
        base.with_activity(true, true, true).capabilities,
        ["fs-v1", ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY, ACTIVITY_PHASES_CAPABILITY]
    );

    let caps = |s: &Session| s.reporter.daemon().capabilities.clone();
    let mut s = session();
    s.activity_stream(true, 0);
    assert_eq!(caps(&s), [ACTIVITY_CAPABILITY], "a fresh agent: no word from acpmux yet");
    s.line(&acp(0, None), 1_000);
    assert_eq!(caps(&s), [ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY]);
    s.line(&acp(0, None), 21_000);
    s.fire(21_000 + ACP_ACTIVITY_TTL_MS);
    assert_eq!(caps(&s), [ACTIVITY_CAPABILITY], "acpmux went quiet");
}

/// Staging, 2026-11-07 and 2026-11-08: after a self-update's restart the agent started with
/// the bake's recorded block (the session host was not listening yet), so every report named
/// the image's build and the Cloud never saw the update. The running session host's
/// `identify` replaces it, keeps the activity capabilities, and goes in a report at once.
#[test]
fn the_running_session_hosts_identify_replaces_the_bakes_daemon_block() {
    use super::super::wire::{ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY};
    let baked = DaemonInfo { version: "0.1.0+aaaaaaaaaaaa".into(), capabilities: vec![] };
    let mut s = Session::new("vm_m0000000000000000001", baked.clone(), 3_600_000);
    let start = s.start(0);
    assert_eq!(start[0].params["daemon"]["version"], "0.1.0+aaaaaaaaaaaa");
    s.answered(&start[0], &ok(), 0, 0.5);
    s.activity_stream(true, 1_000);
    s.line(&acp(0, None), 2_000);
    let r = s.fire(20_000);
    s.answered(&r[0], &ok(), 20_000, 0.5);

    // The same block (or the same one with activity capabilities) changes nothing.
    assert!(s.daemon_identified(&baked, 30_000).is_empty());
    assert!(s.daemon_identified(&baked.with_activity(true, true, false), 30_000).is_empty());

    let running = DaemonInfo { version: "0.1.0+bbbbbbbbbbbb".into(), capabilities: vec![] };
    let r = s.daemon_identified(&running, 40_000);
    assert_eq!(r.len(), 1, "a new build is reported at once");
    assert_eq!(r[0].params["daemon"]["version"], "0.1.0+bbbbbbbbbbbb");
    assert_eq!(
        r[0].params["daemon"]["capabilities"],
        json!([ACTIVITY_CAPABILITY, ACTIVITY_TURNS_CAPABILITY]),
        "the stream and acpmux's count still hold"
    );
    s.answered(&r[0], &ok(), 40_000, 0.5);
    assert!(s.daemon_identified(&running, 60_000).is_empty(), "reported once");
}

/// The lead (2026-11-13): "machine id and updater outcome (seen, held with reason, busy
/// with reason, swapped) in sawBuild, so the slow mode gets read instead of inferred." The
/// first report after an update's restart carries the updater's swap; a later check that
/// finds the same thing makes no report, a new outcome does.
#[test]
fn the_report_carries_the_updaters_block_and_goes_when_its_outcome_changes() {
    let baked = DaemonInfo { version: "0.1.0+bbbbbbbbbbbb".into(), capabilities: vec![] };
    let swapped = json!({"outcome": "swapped", "at": 1_000, "seen_at": 500, "waited": "busy:turn",
                             "swapped": {"commit": "bbbbbbbbbbbb", "at": 1_000}});
    let mut s = Session::new("vm_m0000000000000000001", baked, 3_600_000)
        .with_updater(Some(swapped.clone()));
    let start = s.start(0);
    assert_eq!(start.len(), 1);
    assert_eq!(start[0].params["updater"], swapped);
    s.answered(&start[0], &ok(), 0, 0.5);

    let mut later = swapped;
    later["at"] = json!(16_000);
    assert!(s.updater(Some(later), 20_000).is_empty(), "only its time moved");
    let current = json!({"outcome": "current", "at": 46_000, "seen_at": 500, "waited": "busy:turn",
                             "swapped": {"commit": "bbbbbbbbbbbb", "at": 1_000}});
    let r = s.updater(Some(current.clone()), 50_000);
    assert_eq!(r.len(), 1, "a new outcome is reported");
    assert_eq!(r[0].params["updater"], current);
}

fn acp_from(daemon: &str, turns: u64) -> String {
    json!({"acp_activity": {"turns": turns, "daemon": daemon}}).to_string()
}

/// cmux#33330: two acpmux daemons on one machine. The idle one's renewal never replaces the
/// busy one's count; each lapses on its own.
#[test]
fn each_acpmux_daemon_keeps_its_own_count() {
    let mut s = session();
    s.line(&acp_from("/a.sock", 1), 0);
    s.line(&acp_from("/b.sock", 0), 10_000);
    assert_eq!(
        s.reporter.activity().active_sessions,
        1,
        "an idle daemon's line replaced a busy one's"
    );
    s.line(&acp_from("/b.sock", 2), 20_000);
    assert_eq!(s.reporter.activity().active_sessions, 3, "the counts add up");
    // a stops renewing: its count lapses, b's stays.
    s.line(&acp_from("/b.sock", 2), 80_000);
    s.fire(ACP_ACTIVITY_TTL_MS);
    assert_eq!(s.reporter.activity().active_sessions, 2);
    s.fire(80_000 + ACP_ACTIVITY_TTL_MS);
    assert_eq!(s.reporter.activity().active_sessions, 0);
    assert!(!s.acp.known());
}

/// cmux#33331: the report an expiry sends already drops `activity-turns`, so it never says
/// "0 sessions, known" for a count nobody renews.
#[test]
fn the_expiry_report_no_longer_advertises_activity_turns() {
    use super::super::wire::ACTIVITY_TURNS_CAPABILITY;
    let mut s = session();
    let start = s.start(0);
    s.answered(&start[0], &ok(), 0, 0.5);
    for r in s.activity_stream(true, 20_000) {
        s.answered(&r, &ok(), 20_000, 0.5);
    }
    let (r, _) = s.line(&acp(1, Some(5)), 40_000);
    assert_eq!(r.len(), 1);
    let caps = |r: &OpRequest| r.params["daemon"]["capabilities"].clone();
    assert!(
        caps(&r[0]).as_array().unwrap().contains(&json!(ACTIVITY_TURNS_CAPABILITY)),
        "the first acpmux line's report already says the count is known: {}",
        caps(&r[0])
    );
    s.answered(&r[0], &ok(), 40_000, 0.5);
    let r = s.fire(40_000 + ACP_ACTIVITY_TTL_MS);
    assert_eq!(r.len(), 1, "one report for the expiry");
    assert_eq!(r[0].params["activity"]["active_sessions"], 0);
    assert!(
        !caps(&r[0]).as_array().unwrap().contains(&json!(ACTIVITY_TURNS_CAPABILITY)),
        "the expiry report still advertises activity-turns: {}",
        caps(&r[0])
    );
}

/// cmux#33573: daemon a lapses while it says a turn runs and daemon b keeps renewing 0. a's
/// agent host may still run that turn, so the report stops advertising `activity-turns`
/// until a reports again; it never says "0 sessions, known".
#[test]
fn a_busy_daemon_that_lapses_beside_an_idle_one_makes_the_count_unknown() {
    use super::super::wire::ACTIVITY_TURNS_CAPABILITY;
    let mut s = session();
    s.activity_stream(true, 0);
    let turns = |s: &Session| {
        s.reporter.daemon().capabilities.iter().any(|c| c == ACTIVITY_TURNS_CAPABILITY)
    };
    s.line(&acp_from("/a.sock", 1), 0);
    s.line(&acp_from("/b.sock", 0), 0);
    s.line(&acp_from("/b.sock", 0), 60_000);
    assert!(turns(&s));
    s.fire(ACP_ACTIVITY_TTL_MS);
    assert_eq!(s.reporter.activity().active_sessions, 0);
    assert!(!turns(&s), "a busy daemon lapsed: 0 sessions must not be known");
    // b's renewals do not make it known again; a's return does.
    s.line(&acp_from("/b.sock", 0), 120_000);
    assert!(!turns(&s));
    s.line(&acp_from("/a.sock", 0), 130_000);
    assert!(turns(&s), "a reported again");
    // An idle daemon that lapses changes nothing.
    s.line(&acp_from("/a.sock", 0), 140_000);
    s.fire(130_000 + ACP_ACTIVITY_TTL_MS);
    s.fire(140_000 + ACP_ACTIVITY_TTL_MS - 1);
    assert!(turns(&s), "an idle daemon's lapse is not a busy one's");
}

fn acp_phases(daemon: &str, phases: &[(&str, u64)]) -> String {
    let turns: Vec<Value> = phases
        .iter()
        .map(|(p, since)| json!({"phase": p, "since": since, "processes": 0, "attached": false}))
        .collect();
    json!({"acp_activity": {"turns": phases.len(), "daemon": daemon,
            "phases": {"relayed": false, "turns": turns}}})
    .to_string()
}

/// cmux#34298: acpmux's phases reach the report as `activity.phases`, `activity-phases` is
/// advertised while every daemon whose count holds sends them, and a phase change alone is
/// a report.
#[test]
fn acpmux_phases_reach_the_report_and_a_phase_change_is_reported() {
    use super::super::wire::ACTIVITY_PHASES_CAPABILITY;
    let mut s = session();
    // Every report goes and is applied at once.
    let send = |s: &mut Session, mut r: Vec<OpRequest>, now: u64| {
        r.extend(s.fire(now));
        for req in &r {
            s.answered(req, &ok(), now, 0.5);
        }
        r
    };
    let start = s.start(0);
    send(&mut s, start, 0);
    let r = s.activity_stream(true, 0);
    send(&mut s, r, 0);
    let phases_cap = |s: &Session| {
        s.reporter.daemon().capabilities.iter().any(|c| c == ACTIVITY_PHASES_CAPABILITY)
    };
    let r = s.line(&acp_from("/a.sock", 0), 20_000).0;
    send(&mut s, r, 20_000);
    assert!(!phases_cap(&s), "an acpmux that sends no phases");

    let r = s.line(&acp_phases("/a.sock", &[("model-wait", 31_000)]), 31_000).0;
    let r = send(&mut s, r, 31_000);
    assert!(phases_cap(&s));
    assert_eq!(r.len(), 1, "the count changed: one report");
    assert_eq!(
        r[0].params["activity"]["phases"],
        json!({"relayed": false, "turns": [{"phase": "model-wait", "since": 31_000,
                "processes": 0, "attached": false}]})
    );

    // The same count, now running a tool: a report (past the 10 s window).
    let r = s.line(&acp_phases("/a.sock", &[("tool", 45_000)]), 45_000).0;
    let r = send(&mut s, r, 45_000);
    assert_eq!(r.len(), 1, "a phase change is reported");
    assert_eq!(r[0].params["activity"]["phases"]["turns"][0]["phase"], "tool");
    // An unchanged renewal is not.
    let r = s.line(&acp_phases("/a.sock", &[("tool", 45_000)]), 65_000).0;
    assert!(send(&mut s, r, 65_000).is_empty(), "a renewal that changes nothing");

    // A second daemon without phases: the machine's phases are unknown.
    s.line(&acp_from("/b.sock", 0), 70_000);
    assert!(!phases_cap(&s));
    assert!(s.reporter.activity().phases.is_none());
}

/// acpmux's person's prompt time reaches the report's `activity.last_person_prompt_at` (what
/// cmux-platform's post-chat warm window reads), a new one is reported at once even while a
/// turn runs, and an older one or another daemon's line never moves it back.
#[test]
fn a_persons_prompt_time_reaches_the_report() {
    let mut s = session();
    let send = |s: &mut Session, mut r: Vec<OpRequest>, now: u64| {
        r.extend(s.fire(now));
        for req in &r {
            s.answered(req, &ok(), now, 0.5);
        }
        r
    };
    let start = s.start(0);
    send(&mut s, start, 0);
    let prompted = |turns: u64, at: u64| {
        json!({"acp_activity": {"turns": turns, "daemon": "/a.sock",
                "last_person_prompt_at": at}})
        .to_string()
    };
    let r = s.line(&acp_from("/a.sock", 1), 20_000).0;
    let r = send(&mut s, r, 20_000);
    assert!(r[0].params["activity"].get("last_person_prompt_at").is_none(), "none yet");

    // A person's prompt while a turn runs: the same count, still a report.
    let at = 1_790_000_000_000u64;
    let r = s.line(&prompted(1, at), 40_000).0;
    let r = send(&mut s, r, 40_000);
    assert_eq!(r.len(), 1, "a person's prompt is reported at once");
    assert_eq!(r[0].params["activity"]["last_person_prompt_at"], at);

    // An older time, or a line with none (another daemon), leaves it where it was.
    let r = s.line(&prompted(1, at - 5_000), 60_000).0;
    assert!(send(&mut s, r, 60_000).is_empty(), "an older time changes nothing");
    s.line(&acp_from("/b.sock", 0), 70_000);
    assert_eq!(s.reporter.activity().last_person_prompt_at, Some(at));

    // The turn ends: the report still carries the prompt time.
    let r = s.line(&prompted(0, at), 90_000).0;
    let r = send(&mut s, r, 90_000);
    assert_eq!(r[0].params["activity"]["active_sessions"], 0);
    assert_eq!(r[0].params["activity"]["last_person_prompt_at"], at);
}

/// A phases block that does not match its line's count, or does not read, is dropped: the
/// Cloud never reads fewer turns than sessions at work as the whole machine.
#[test]
fn a_phases_block_that_does_not_match_its_count_is_dropped() {
    let line = |turns: u64, block: Value| json!({"turns": turns, "phases": block});
    let one = json!({"relayed": true, "turns": [{"phase": "tool", "since": 1}]});
    assert_eq!(read_phases(&line(1, one.clone()), 1).map(|p| p.0), Some(true));
    assert!(read_phases(&line(2, one), 2).is_none(), "two at work, one turn");
    let bad = json!({"turns": [{"phase": "", "since": 1}]});
    assert!(read_phases(&line(1, bad), 1).is_none());
    let no_since = json!({"turns": [{"phase": "tool"}]});
    assert!(read_phases(&line(1, no_since), 1).is_none());
    assert!(read_phases(&json!({"turns": 0}), 0).is_none(), "no block");
}

/// The workload probe's result reaches the report as `activity.workload` with
/// `activity-workload` (only with `activity`); a report goes when the machine turns busy or
/// quiet, not when only which process uses CPU changes; a probe that stops reading withdraws
/// the capability, so the Cloud reads the machine as busy.
#[test]
fn the_workload_reaches_the_report_and_only_a_change_of_state_is_reported() {
    use super::super::wire::ACTIVITY_WORKLOAD_CAPABILITY;
    let mut s = session();
    let send = |s: &mut Session, mut r: Vec<OpRequest>, now: u64| {
        r.extend(s.fire(now));
        for req in &r {
            s.answered(req, &ok(), now, 0.5);
        }
        r
    };
    let start = s.start(0);
    send(&mut s, start, 0);
    let cap = |r: &OpRequest| {
        r.params["daemon"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!(ACTIVITY_WORKLOAD_CAPABILITY))
    };
    let busy = |comm: &str, at: u64| Workload {
        busy_processes: vec![comm.into()],
        last_busy_at: Some(at),
        ..Workload::default()
    };
    // Without the activity stream the block rides along, never the capability.
    let r = s.workload(Some(busy("node", 1)), 20_000);
    let r = send(&mut s, r, 20_000);
    assert_eq!(r.len(), 1);
    assert!(!cap(&r[0]));
    assert_eq!(r[0].params["activity"]["workload"]["busy_processes"], 1);
    let r = s.activity_stream(true, 40_000);
    let r = send(&mut s, r, 40_000);
    assert!(cap(&r[0]));
    assert_eq!(r[0].params["activity"]["workload"]["process_names"], json!(["node"]));

    // Another process now uses CPU: still busy, no report.
    assert!(s.workload(Some(busy("cargo", 2)), 60_000).is_empty());
    // Quiet: a report, with the last busy time.
    let quiet = Workload { last_busy_at: Some(2), ..Workload::default() };
    let r = s.workload(Some(quiet.clone()), 80_000);
    let r = send(&mut s, r, 80_000);
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].params["activity"]["workload"]["busy_processes"], 0);
    assert_eq!(r[0].params["activity"]["workload"]["last_busy_at"], 2);
    assert!(s.workload(Some(quiet), 100_000).is_empty(), "nothing changed");
    // A port opens: a report.
    let port =
        Workload { listening_ports: vec![3000], last_busy_at: Some(3), ..Workload::default() };
    let r = s.workload(Some(port), 120_000);
    let r = send(&mut s, r, 120_000);
    assert_eq!(r[0].params["activity"]["workload"]["ports"], json!([3000]));
    // The probe stops reading: the capability and the block go.
    let r = s.workload(None, 140_000);
    let r = send(&mut s, r, 140_000);
    assert_eq!(r.len(), 1);
    assert!(!cap(&r[0]));
    assert!(r[0].params["activity"].get("workload").is_none());
    assert!(s.workload(None, 160_000).is_empty());
}

/// Relayed only when every daemon says so; turns from every daemon.
#[test]
fn the_machine_phases_join_every_daemon() {
    let mut s = session();
    s.line(&acp_phases("/a.sock", &[("model-wait", 1)]), 0);
    let relayed = json!({"acp_activity": {"turns": 1, "daemon": "/b.sock", "phases":
            {"relayed": true, "turns": [{"phase": "tool", "since": 2}]}}});
    s.line(&relayed.to_string(), 0);
    let phases = s.reporter.activity().phases.clone().unwrap();
    assert_eq!(phases["relayed"], false);
    assert_eq!(phases["turns"].as_array().unwrap().len(), 2);
    assert_eq!(s.reporter.activity().active_sessions, 2);
}

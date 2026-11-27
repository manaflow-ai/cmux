use super::*;

fn busy() -> ChatState {
    ChatState { turn_running: true, turn_ms: 1_000, ..ChatState::default() }
}

fn here() -> Own {
    Own { idle_ms: Some(5_000), ..Own::default() }
}

fn read(json: &str) -> Verdict {
    serde_json::from_str(json).expect("verdict")
}

#[test]
fn memory_and_battery_come_from_the_verdict() {
    let v = read(
        r#"{"host":"mac","ok":false,"over":["memory pressure critical"],"pressure":"critical",
            "power":{"batteryPercent":12,"onAc":false,"lidClosed":false},"top":[]}"#,
    );
    let s = signals(&here(), Some(&v));
    assert_eq!(s.memory, Pressure::Critical);
    assert!(s.on_battery);
    assert_eq!(s.battery_percent, Some(12));
    assert!(!s.sleeping);
    // The rule acts on them itself, strongest first (battery before memory).
    assert_eq!(
        judge(Mode::Auto, &busy(), &here(), "s1", Some(&v)).decision,
        AutoDecision::ToCloud { reason: AutoReason::LowBattery }
    );
    let lid = read(r#"{"ok":true,"power":{"lidClosed":true}}"#);
    assert!(signals(&Own::default(), Some(&lid)).sleeping);
    // No verdict (no daemon, an older one): nothing is known, nothing moves for it.
    assert_eq!(signals(&here(), None), Signals { idle_ms: Some(5_000), ..Signals::default() });
    let unknown = read(r#"{"ok":null,"pressure":"unknown"}"#);
    assert_eq!(signals(&here(), Some(&unknown)).memory, Pressure::Normal);
    // Charging at 5%: on AC is not on battery.
    let charging = read(r#"{"ok":true,"power":{"batteryPercent":5,"onAc":true}}"#);
    assert_eq!(
        judge(Mode::Auto, &busy(), &here(), "s1", Some(&charging)).decision,
        AutoDecision::Stay
    );
}

#[test]
fn over_budget_is_shadow_only() {
    let v = read(r#"{"ok":false,"over":["load 31.0 >= 15.0"],"pressure":"normal"}"#);
    let j = judge(Mode::Auto, &busy(), &here(), "s1", Some(&v));
    assert_eq!(j.decision, AutoDecision::Stay);
    assert_eq!(
        j.shadow,
        Some(Shadow {
            would: AutoDecision::ToCloud { reason: AutoReason::Busy },
            over: vec!["load 31.0 >= 15.0".into()],
            reserve: None,
        })
    );
    let line = shadow_line(7, "s1", &j).expect("line");
    let parsed: serde_json::Value = serde_json::from_str(&line).expect("json");
    assert_eq!(parsed["session"], "s1");
    assert_eq!(parsed["did"]["do"], "stay");
    assert_eq!(parsed["would"]["reason"], "busy");
    assert!(!line.contains('\n'));
    // The wire keeps `do` and `reason` at the top, as before.
    let wire = serde_json::to_value(&j).expect("wire");
    assert_eq!(wire["do"], "stay");
    assert_eq!(wire["shadow"]["would"]["do"], "toCloud");
}

#[test]
fn no_shadow_without_cause() {
    let over = read(r#"{"ok":false,"over":["available RAM 4%"]}"#);
    let within = read(r#"{"ok":true,"over":[]}"#);
    // Within budget, or not yet sampled.
    assert_eq!(judge(Mode::Auto, &busy(), &here(), "s1", Some(&within)).shadow, None);
    assert_eq!(
        judge(Mode::Auto, &busy(), &here(), "s1", Some(&read(r#"{"ok":null}"#))).shadow,
        None
    );
    assert_eq!(judge(Mode::Auto, &busy(), &here(), "s1", None).shadow, None);
    // An idle chat, a chat not on Auto, one moving, one already in Cloud.
    assert_eq!(judge(Mode::Auto, &ChatState::default(), &here(), "s1", Some(&over)).shadow, None);
    assert_eq!(judge(Mode::Local, &busy(), &here(), "s1", Some(&over)).shadow, None);
    let moving = ChatState { moving: true, ..busy() };
    assert_eq!(judge(Mode::Auto, &moving, &here(), "s1", Some(&over)).shadow, None);
    let cloud = ChatState { at: At::Cloud, ..busy() };
    assert_eq!(judge(Mode::Auto, &cloud, &here(), "s1", Some(&over)).shadow, None);
    // Away (or idle unknown): away is no reason to move.
    let away = Own { idle_ms: Some(rule::AWAY_MS), ..Own::default() };
    let j = judge(Mode::Auto, &busy(), &away, "s1", Some(&over));
    assert_eq!(j.decision, AutoDecision::ToCloud { reason: AutoReason::Away });
    assert_eq!(j.shadow, None);
    assert_eq!(judge(Mode::Auto, &busy(), &Own::default(), "s1", Some(&over)).shadow, None);
    assert_eq!(shadow_line(1, "s", &judge(Mode::Auto, &busy(), &here(), "s1", None)), None);
    // A queued chat counts as work.
    let queued = ChatState { queued: 1, ..ChatState::default() };
    assert!(judge(Mode::Auto, &queued, &here(), "s1", Some(&over)).shadow.is_some());
}

#[test]
fn the_reserve_verdict_names_the_chat_that_would_move() {
    // A daemon with Auto on reserve: only the chat it names would move, with its reason,
    // whatever the budget's `ok` says.
    let v = read(
        r#"{"ok":true,"over":[],"reserve":{"rule":"auto-reserve/1","verdict":{"do":"hold","why":"paced"},
            "enabled":false,"acts":false,"out":[{"session":"s1","reason":"cpu","atMs":27000}]}}"#,
    );
    let j = judge(Mode::Auto, &busy(), &here(), "s1", Some(&v));
    assert_eq!(j.decision, AutoDecision::Stay);
    let shadow = j.shadow.clone().expect("shadow");
    assert_eq!(shadow.would, AutoDecision::ToCloud { reason: AutoReason::Busy });
    assert_eq!(shadow.reserve.as_deref(), Some("cpu"));
    let line: serde_json::Value =
        serde_json::from_str(&shadow_line(3, "s1", &j).expect("line")).expect("json");
    assert_eq!(line["reserve"], "cpu");
    assert_eq!(judge(Mode::Auto, &busy(), &here(), "s2", Some(&v)).shadow, None);
    // Over budget but the reserve rule names nobody: nothing would move.
    let none = read(r#"{"ok":false,"over":["load 31.0 >= 15.0"],"reserve":{"out":[]}}"#);
    assert_eq!(judge(Mode::Auto, &busy(), &here(), "s1", Some(&none)).shadow, None);
    // The same gates hold: away, idle, not on Auto.
    let away = Own { idle_ms: Some(rule::AWAY_MS), ..Own::default() };
    assert_eq!(judge(Mode::Auto, &busy(), &away, "s1", Some(&v)).shadow, None);
    assert_eq!(judge(Mode::Auto, &ChatState::default(), &here(), "s1", Some(&v)).shadow, None);
    assert_eq!(judge(Mode::Local, &busy(), &here(), "s1", Some(&v)).shadow, None);
    // An older daemon (no `reserve`) falls back to `over`, and its line has no `reserve` key.
    let old = read(r#"{"ok":false,"over":["available RAM 4%"]}"#);
    let j = judge(Mode::Auto, &busy(), &here(), "s9", Some(&old));
    assert_eq!(j.shadow.as_ref().and_then(|s| s.reserve.clone()), None);
    assert!(j.shadow.is_some());
    assert!(!shadow_line(1, "s9", &j).expect("line").contains("reserve"));
}

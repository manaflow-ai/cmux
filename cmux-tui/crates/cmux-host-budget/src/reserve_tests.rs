use super::*;

const GB: u64 = 1 << 30;
const STEP: u64 = 3_000;

fn on(reserve_percent: u8) -> ReserveSetting {
    ReserveSetting { enabled: true, reserve_percent }
}

fn agent(session: &str, cpu_cores: f64, rss_gb: u64) -> AgentUse {
    AgentUse {
        session: session.into(),
        cpu_cores,
        rss_bytes: rss_gb * GB,
        in_turn: true,
        movable: true,
    }
}

/// Leo's Mac: 15 performance cores, 48 GB.
fn sample(at_ms: u64, idle_ms: Option<u64>, agents: Vec<AgentUse>) -> ReserveSample {
    ReserveSample {
        at_ms,
        performance_cores: 15.0,
        ram_bytes: 48 * GB,
        idle_ms,
        memory_normal: true,
        cpu_busy: None,
        lateness_p50_ms: None,
        slow_frames: false,
        swap_growth_mb_per_min: None,
        used_ram_bytes: None,
        thermal_serious: false,
        agents,
    }
}

/// Feeds `n` samples 3 s apart from `start`, returning every verdict.
fn run(
    t: &mut ReserveTracker,
    setting: &ReserveSetting,
    start: u64,
    n: u64,
    agents: &dyn Fn() -> Vec<AgentUse>,
) -> Vec<ReserveVerdict> {
    (0..n).map(|i| t.judge(setting, &sample(start + i * STEP, Some(1_000), agents()))).collect()
}

fn hold(why: HoldWhy) -> ReserveVerdict {
    ReserveVerdict::Hold { why }
}

#[test]
fn rule_one_fires_after_ten_samples_over_and_names_the_biggest_agent() {
    // 50% of 15 cores leaves agents 7.5; they use 9.
    let agents = || vec![agent("small", 2.0, 1), agent("big", 6.0, 4), agent("mid", 1.0, 1)];
    let mut t = ReserveTracker::new();
    let v = run(&mut t, &on(50), 0, 10, &agents);
    assert!(v[..9].iter().all(|v| *v == hold(HoldWhy::Holding)), "{v:?}");
    assert_eq!(v[9], ReserveVerdict::MoveOut { session: "big".into(), reason: ReserveReason::Cpu });
    assert_eq!(t.moved().collect::<Vec<_>>(), ["big"]);
}

#[test]
fn a_persons_own_build_moves_nothing() {
    // The machine is pegged by the person's Xcode build; agents idle. The sample
    // carries only agents' own use, so host load never enters the verdict.
    let agents = || vec![agent("a", 0.1, 1), agent("b", 0.2, 1)];
    let mut t = ReserveTracker::new();
    let v = run(&mut t, &on(50), 0, 40, &agents);
    assert!(v.iter().all(|v| *v == hold(HoldWhy::Within)), "{v:?}");
}

#[test]
fn memory_over_the_budget_fires_too() {
    // 75% kept leaves agents 12 GB; they hold 20.
    let agents = || vec![agent("a", 0.5, 14), agent("b", 0.5, 6)];
    let mut t = ReserveTracker::new();
    let v = run(&mut t, &on(75), 0, 10, &agents);
    assert_eq!(
        v[9],
        ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Memory }
    );
}

#[test]
fn away_is_no_reason_to_move() {
    // 13 of 15 cores: over the 50% reserve, under the away line of 90%.
    let agents = vec![agent("a", 13.0, 4)];
    let mut t = ReserveTracker::new();
    for i in 0..20 {
        let away = sample(i * STEP, Some(PRESENT_MS), agents.clone());
        assert_eq!(t.judge(&on(50), &away), hold(HoldWhy::Away));
        let unread = sample(i * STEP + 1, None, agents.clone());
        assert_eq!(t.judge(&on(50), &unread), hold(HoldWhy::Away));
    }
}

#[test]
fn off_moves_nothing_and_forgets() {
    let agents = || vec![agent("a", 14.0, 4)];
    let mut t = ReserveTracker::new();
    let off = ReserveSetting { enabled: false, ..ReserveSetting::default() };
    assert!(run(&mut t, &off, 0, 20, &agents).iter().all(|v| *v == hold(HoldWhy::Off)));
    assert_eq!(ReserveSetting::default().reserve_percent, 50);
    assert!(
        !ReserveSetting::default().enabled,
        "Auto on reserve is off until the person turns it on"
    );
}

#[test]
fn the_streak_needs_samples_in_a_row() {
    let over = || vec![agent("a", 9.0, 1), agent("b", 1.0, 1)];
    let fits = || vec![agent("a", 1.0, 1)];
    let mut t = ReserveTracker::new();
    run(&mut t, &on(50), 0, 9, &over);
    assert_eq!(run(&mut t, &on(50), 9 * STEP, 1, &fits)[0], hold(HoldWhy::Within));
    let v = run(&mut t, &on(50), 10 * STEP, 10, &over);
    assert_eq!(v[8], hold(HoldWhy::Holding));
    assert!(matches!(v[9], ReserveVerdict::MoveOut { .. }));

    // The same reading judged twice, or a burst of reads, is one sample.
    let mut t = ReserveTracker::new();
    for i in 0..30 {
        assert_eq!(t.judge(&on(50), &sample(i * 100, Some(0), over())), hold(HoldWhy::Holding));
    }
    // A gap the readings did not cover starts over.
    let mut t = ReserveTracker::new();
    run(&mut t, &on(50), 0, 9, &over);
    assert_eq!(
        run(&mut t, &on(50), 8 * STEP + MAX_SAMPLE_GAP_MS + 1, 1, &over)[0],
        hold(HoldWhy::Holding)
    );
}

#[test]
fn one_move_out_a_minute() {
    // Two big agents: after the first would-move, the rest still exceed the budget.
    let agents = || vec![agent("a", 9.0, 1), agent("b", 8.0, 1)];
    let mut t = ReserveTracker::new();
    let v = run(&mut t, &on(50), 0, 40, &agents);
    let moves: Vec<_> =
        v.iter().enumerate().filter(|(_, v)| matches!(v, ReserveVerdict::MoveOut { .. })).collect();
    assert_eq!(moves.len(), 2, "{v:?}");
    let (first, second) = (moves[0].0 as u64 * STEP, moves[1].0 as u64 * STEP);
    assert!(second - first >= MOVE_GAP_MS, "{first} then {second}");
    assert!(v.contains(&hold(HoldWhy::Paced)));
}

#[test]
fn only_movable_agents_move() {
    let agents = || {
        let mut front = agent("in-front", 12.0, 1);
        front.movable = false;
        vec![front, agent("other", 1.0, 1)]
    };
    let mut t = ReserveTracker::new();
    let v = run(&mut t, &on(50), 0, 10, &agents);
    assert_eq!(
        v[9],
        ReserveVerdict::MoveOut { session: "other".into(), reason: ReserveReason::Cpu }
    );

    let only_front = || {
        let mut front = agent("in-front", 12.0, 1);
        front.movable = false;
        vec![front]
    };
    let mut t = ReserveTracker::new();
    assert_eq!(run(&mut t, &on(50), 0, 10, &only_front)[9], hold(HoldWhy::NoneMovable));
}

#[test]
fn a_moved_agent_returns_after_its_stay_once_use_fits_for_ten_minutes() {
    let mut t = ReserveTracker::new();
    let over = || vec![agent("big", 8.0, 2), agent("small", 1.0, 1)];
    assert!(matches!(run(&mut t, &on(50), 0, 10, &over)[9], ReserveVerdict::MoveOut { .. }));
    // big's turn ends; its last use (8 cores) plus small's (1) is over 70% of 7.5.
    let calm = || {
        let mut big = agent("big", 0.0, 2);
        big.in_turn = false;
        vec![big, agent("small", 0.5, 1)]
    };
    let v = run(&mut t, &on(50), 10 * STEP, 400, &calm);
    assert!(v.iter().all(|v| *v == hold(HoldWhy::Within)), "it used more than the budget leaves");

    // With a smaller last use it fits: back after the stay and ten minutes of fitting.
    let mut t = ReserveTracker::new();
    let over = || vec![agent("big", 4.0, 2), agent("small", 4.0, 1)];
    let out = run(&mut t, &on(50), 0, 10, &over);
    let ReserveVerdict::MoveOut { session, .. } = &out[9] else { panic!("{out:?}") };
    let out_at = 9 * STEP;
    let v = run(&mut t, &on(50), 10 * STEP, 500, &calm);
    let back =
        v.iter().position(|v| matches!(v, ReserveVerdict::BringBack { .. })).expect("returns");
    let back_at = (10 + back as u64) * STEP;
    assert!(back_at >= out_at + MIN_STAY_MS && back_at >= 10 * STEP + RETURN_HOLD_MS, "{back_at}");
    assert_eq!(
        v[back],
        ReserveVerdict::BringBack { session: session.clone(), reason: ReserveReason::Fits }
    );
}

#[test]
fn a_return_waits_for_the_turn_end() {
    let mut t = ReserveTracker::new();
    let over = || vec![agent("big", 8.0, 2)];
    run(&mut t, &on(50), 0, 10, &over);
    let still_in_turn = || vec![agent("big", 0.5, 2)];
    let v = run(&mut t, &on(50), 10 * STEP, 500, &still_in_turn);
    assert!(!v.iter().any(|v| matches!(v, ReserveVerdict::BringBack { .. })));
}

#[test]
fn twice_out_in_an_hour_pins_it_until_the_person_brings_it_back() {
    let mut t = ReserveTracker::new();
    let over = || vec![agent("a", 5.0, 1), agent("b", 4.0, 1)];
    let idle = || {
        let mut a = agent("a", 0.0, 1);
        a.in_turn = false;
        vec![a, agent("b", 0.2, 1)]
    };
    let mut now = 0;
    let mut outs = 0;
    for _ in 0..2 {
        let v = run(&mut t, &on(50), now, 10, &over);
        assert_eq!(
            v[9],
            ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Cpu }
        );
        outs += 1;
        now += 10 * STEP;
        let v = run(&mut t, &on(50), now, 600, &idle);
        now += 600 * STEP;
        let backs = v.iter().filter(|v| matches!(v, ReserveVerdict::BringBack { .. })).count();
        assert_eq!(backs, if outs == 1 { 1 } else { 0 }, "out {outs}: {v:?}");
    }
    assert_eq!(t.moved().collect::<Vec<_>>(), ["a"]);
    t.brought_back("a");
    assert_eq!(t.moved().count(), 0);
}

#[test]
fn the_reserve_snaps_to_its_stops_and_sets_the_budget() {
    let s = sample(0, Some(0), vec![]);
    for (asked, stop, cores) in
        [(0, 0, 15.0), (25, 25, 11.25), (49, 25, 11.25), (50, 50, 7.5), (99, 75, 3.75)]
    {
        let setting = on(asked);
        assert_eq!(setting.reserve(), stop);
        assert_eq!(AgentBudget::of(&setting, &s).cores, cores);
    }
}

#[test]
fn shadow_lines_record_moves_not_holds() {
    let dir = std::env::temp_dir().join(format!("auto-shadow-{}", std::process::id()));
    let path = dir.join("auto-shadow.jsonl");
    let _ = std::fs::remove_file(&path);
    let s = sample(42, Some(0), vec![agent("a", 9.0, 1)]);
    assert!(!append_shadow(&path, &ShadowLine::new(&on(50), &s, hold(HoldWhy::Holding))).unwrap());
    let moved = ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Cpu };
    assert!(append_shadow(&path, &ShadowLine::new(&on(50), &s, moved.clone())).unwrap());
    let text = std::fs::read_to_string(&path).unwrap();
    let line: ShadowLine = serde_json::from_str(text.trim()).unwrap();
    assert_eq!(line.verdict, moved);
    assert_eq!(line.rule, RESERVE_RULE_VERSION);
    assert!(text.contains(r#""verdict":{"do":"moveOut","session":"a","reason":"cpu"}"#), "{text}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Feeds `n` samples 3 s apart, each shaped by `shape`.
fn run_with(
    t: &mut ReserveTracker,
    n: u64,
    shape: &dyn Fn(&mut ReserveSample),
    agents: &dyn Fn() -> Vec<AgentUse>,
) -> Vec<ReserveVerdict> {
    (0..n)
        .map(|i| {
            let mut s = sample(i * STEP, Some(1_000), agents());
            shape(&mut s);
            t.judge(&on(50), &s)
        })
        .collect()
}

#[test]
fn away_past_ninety_percent_moves() {
    let agents = || vec![agent("a", 14.0, 4)];
    let mut t = ReserveTracker::new();
    let v = run_with(&mut t, 10, &|s| s.idle_ms = Some(PRESENT_MS), &agents);
    assert_eq!(v[9], ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Cpu });
}

#[test]
fn rule_two_saturated_and_late_moves_an_agent_within_its_budget() {
    // Agents use 3 of 7.5 cores, but the machine is 95% busy and timers run late.
    let agents = || vec![agent("a", 2.0, 1), agent("b", 1.0, 1)];
    let late = |s: &mut ReserveSample| {
        s.cpu_busy = Some(0.95);
        s.lateness_p50_ms = Some(1.6);
    };
    let mut t = ReserveTracker::new();
    let v = run_with(&mut t, 10, &late, &agents);
    assert_eq!(
        v[9],
        ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Interactive }
    );

    // Slow frames stand in for lateness.
    let frames = |s: &mut ReserveSample| {
        s.cpu_busy = Some(0.95);
        s.slow_frames = true;
    };
    let mut t = ReserveTracker::new();
    assert_eq!(
        run_with(&mut t, 10, &frames, &agents)[9],
        ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Interactive }
    );
}

#[test]
fn rule_two_needs_lateness_agents_and_presence() {
    let agents = || vec![agent("a", 2.0, 1)];
    // Busy but on time: contention, not harm.
    let on_time = |s: &mut ReserveSample| {
        s.cpu_busy = Some(0.95);
        s.lateness_p50_ms = Some(0.5);
    };
    let mut t = ReserveTracker::new();
    assert!(run_with(&mut t, 20, &on_time, &agents).iter().all(|v| *v == hold(HoldWhy::Within)));
    // Late, but agents idle: the person's own build.
    let idle_agents = || vec![agent("a", 0.2, 1)];
    let late = |s: &mut ReserveSample| {
        s.cpu_busy = Some(0.99);
        s.lateness_p50_ms = Some(3.0);
    };
    let mut t = ReserveTracker::new();
    assert!(run_with(&mut t, 20, &late, &idle_agents).iter().all(|v| *v == hold(HoldWhy::Within)));
    // Late with agents busy, but the person is away.
    let away_late = |s: &mut ReserveSample| {
        late(s);
        s.idle_ms = Some(PRESENT_MS);
    };
    let mut t = ReserveTracker::new();
    assert!(run_with(&mut t, 20, &away_late, &agents).iter().all(|v| *v == hold(HoldWhy::Within)));
}

#[test]
fn rule_three_memory_pressure_holds_away_too_when_agents_hold_a_quarter() {
    // Agents hold 10 of 36 GB used: over a quarter.
    let agents = || vec![agent("a", 0.5, 6), agent("b", 0.5, 4)];
    let pressured = |s: &mut ReserveSample| {
        s.idle_ms = None;
        s.memory_normal = false;
        s.used_ram_bytes = Some(36 * GB);
    };
    let mut t = ReserveTracker::new();
    assert_eq!(
        run_with(&mut t, 10, &pressured, &agents)[9],
        ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::MemoryPressure }
    );

    // Swap growth alone counts.
    let swapping = |s: &mut ReserveSample| {
        s.swap_growth_mb_per_min = Some(100.0);
        s.used_ram_bytes = Some(36 * GB);
    };
    let mut t = ReserveTracker::new();
    assert_eq!(
        run_with(&mut t, 10, &swapping, &agents)[9],
        ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::MemoryPressure }
    );

    // A browser with 200 tabs: agents hold under a quarter, nothing moves.
    let browser = |s: &mut ReserveSample| {
        s.memory_normal = false;
        s.used_ram_bytes = Some(46 * GB);
    };
    let mut t = ReserveTracker::new();
    assert!(run_with(&mut t, 20, &browser, &agents).iter().all(|v| *v == hold(HoldWhy::Within)));
}

#[test]
fn rule_four_thermal_needs_an_agent_core() {
    let hot = |s: &mut ReserveSample| s.thermal_serious = true;
    let mut t = ReserveTracker::new();
    let busy = || vec![agent("a", 1.5, 1)];
    assert_eq!(
        run_with(&mut t, 10, &hot, &busy)[9],
        ReserveVerdict::MoveOut { session: "a".into(), reason: ReserveReason::Thermal }
    );
    let mut t = ReserveTracker::new();
    let idle = || vec![agent("a", 0.3, 1)];
    assert!(run_with(&mut t, 20, &hot, &idle).iter().all(|v| *v == hold(HoldWhy::Within)));
}

#[test]
fn older_samples_without_the_new_readings_still_parse() {
    let json = r#"{"atMs":1,"performanceCores":15.0,"ramBytes":1,"idleMs":null,"agents":[]}"#;
    let s: ReserveSample = serde_json::from_str(json).unwrap();
    assert!(s.memory_normal && s.cpu_busy.is_none() && !s.thermal_serious);
}

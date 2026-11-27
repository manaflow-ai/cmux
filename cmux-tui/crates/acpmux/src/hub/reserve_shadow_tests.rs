use super::*;
use crate::host_pressure::reserve::HOLD_SAMPLES;
use crate::host_pressure::{Budget, SessionLoad, evaluate};
use crate::hub::session_usage::SessionUsage;

const GB: u64 = 1 << 30;

/// Leo's Mac: 15 performance cores, the person typing a second ago.
fn mac() -> Sample {
    Sample {
        performance_cores: Some(15),
        physical_cores: Some(18),
        logical_cpus: 18,
        vm_pressure_level: Some(1),
        available_ram_fraction: Some(0.25),
        cpu_busy: Some(0.4),
        thermal_pressure_level: Some(0),
        hid_idle_seconds: Some(1.0),
        lateness_p50_ms: Some(0.2),
        ..Sample::default()
    }
}

fn agents(list: &[(&str, f64, u64, bool)]) -> AgentsUsage {
    AgentsUsage {
        cpu_cores: list.iter().map(|a| a.1).sum(),
        rss_bytes: list.iter().map(|a| a.2 * GB).sum(),
        sessions: list
            .iter()
            .map(|&(id, cpu_cores, gb, active)| SessionUsage {
                id: id.into(),
                load: SessionLoad { active, cpu_cores, rss_bytes: gb * GB },
            })
            .collect(),
        age_ms: 0,
    }
}

fn parsed(json: &str) -> Settings {
    Settings::Parsed(serde_json::from_str(json).expect("json"))
}

#[test]
fn the_sample_comes_from_the_meter_the_verdict_and_the_agents() {
    let s = mac();
    let verdict = evaluate("mac", &s, Some(80.0), &Budget::default());
    let a = agents(&[("big", 6.0, 4, true), ("idle", 0.0, 1, false)]);
    let r = reserve_sample(9, Some(&s), Some(&verdict), Some(48 * GB), &a).expect("sample");
    assert_eq!(r.at_ms, 9);
    assert_eq!(r.performance_cores, 15.0);
    assert_eq!(r.ram_bytes, 48 * GB);
    assert_eq!(r.idle_ms, Some(1_000));
    assert!(r.memory_normal);
    assert_eq!(r.cpu_busy, Some(0.4));
    assert_eq!(r.lateness_p50_ms, Some(0.2));
    assert_eq!(r.swap_growth_mb_per_min, Some(80.0));
    assert_eq!(r.used_ram_bytes, Some(36 * GB));
    assert!(!r.thermal_serious);
    assert_eq!(r.agents.len(), 2);
    assert_eq!(r.agents[0].session, "big");
    assert!(r.agents[0].in_turn && r.agents[0].movable);
    assert!(!r.agents[1].in_turn);

    // Warn pressure and heavy thermal read as such; no performance cores falls back.
    let hot = Sample {
        performance_cores: None,
        vm_pressure_level: Some(2),
        thermal_pressure_level: Some(2),
        hid_idle_seconds: None,
        ..mac()
    };
    let verdict = evaluate("mac", &hot, None, &Budget::default());
    let r = reserve_sample(1, Some(&hot), Some(&verdict), Some(GB), &a).expect("sample");
    assert_eq!(r.performance_cores, 18.0);
    assert!(!r.memory_normal);
    assert!(r.thermal_serious);
    assert_eq!(r.idle_ms, None);

    // Nothing to judge without a sample or the RAM size.
    assert_eq!(reserve_sample(1, None, None, Some(GB), &a), None);
    assert_eq!(reserve_sample(1, Some(&s), None, None, &a), None);
    assert!(reserve_sample(1, Some(&s), None, Some(GB), &a).is_some_and(|r| r.memory_normal));
}

#[test]
fn the_setting_is_off_unless_the_person_turned_it_on() {
    assert_eq!(setting_from(&Settings::Missing), ReserveSetting::default());
    assert!(!setting_from(&Settings::Missing).enabled);
    assert_eq!(setting_from(&Settings::Unreadable("x".into())), ReserveSetting::default());
    assert_eq!(
        setting_from(&parsed(r#"{"cloud":{"auto":true,"autoReservePercent":25}}"#)),
        ReserveSetting { enabled: true, reserve_percent: 25 }
    );
    assert_eq!(
        setting_from(&parsed(r#"{"cloud.auto":"yes","cloud.autoReservePercent":900}"#)),
        ReserveSetting { enabled: false, reserve_percent: 50 }
    );
}

#[test]
fn shadow_names_the_heaviest_agent_out_while_auto_is_off_and_moves_nothing() {
    let dir = tempfile::tempdir().expect("dir");
    let log = dir.path().join("auto-shadow.jsonl");
    let a = agents(&[("small", 2.0, 1, true), ("big", 6.0, 4, true), ("mid", 1.0, 1, true)]);
    let off = ReserveSetting::default();
    let mut shadow = Shadow::default();
    let mut last = Value::Null;
    for i in 0..u64::from(HOLD_SAMPLES) {
        let r = reserve_sample(i * 3_000, Some(&mac()), None, Some(48 * GB), &a).expect("sample");
        last = shadow.judge(off, &r, Some(&log));
        if i + 1 < u64::from(HOLD_SAMPLES) {
            assert_eq!(last["verdict"]["do"], "hold", "{last}");
            assert_eq!(last["out"], json!([]));
        }
    }
    assert_eq!(last["verdict"]["do"], "moveOut", "{last}");
    assert_eq!(last["verdict"]["session"], "big");
    assert_eq!(last["verdict"]["reason"], "cpu");
    assert_eq!(last["enabled"], false);
    assert_eq!(last["acts"], false);
    assert_eq!(last["reservePercent"], 50);
    assert_eq!(last["out"], json!([{"session": "big", "reason": "cpu", "atMs": 27_000}]));
    // The one move is the one shadow line; holds are not written.
    let text = std::fs::read_to_string(&log).expect("log");
    assert_eq!(text.lines().count(), 1, "{text}");
    let line: ShadowLine = serde_json::from_str(text.trim()).expect("line");
    assert_eq!(line.verdict, ReserveVerdict::MoveOut { session: "big".into(), reason: ReserveReason::Cpu });

    // The next status still says big is out, so a polling app sees a steady answer.
    let r = reserve_sample(30_000, Some(&mac()), None, Some(48 * GB), &a).expect("sample");
    let next = shadow.judge(off, &r, Some(&log));
    assert_eq!(next["verdict"]["do"], "hold");
    assert_eq!(next["out"][0]["session"], "big");
}

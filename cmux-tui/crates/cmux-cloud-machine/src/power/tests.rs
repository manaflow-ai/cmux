use std::path::PathBuf;

use serde_json::Value;

use super::*;

const STATES: usize = Power::KINDS.len();
const EVENTS: usize = Event::KINDS.len();

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/cloud-machine-power/table.json")
}

fn rendered() -> String {
    let mut text = serde_json::to_string_pretty(&table()).expect("table renders");
    text.push('\n');
    text
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_CLOUD_POWER_TABLE=1` rewrites it.
#[test]
fn committed_table_is_current() {
    let path = table_path();
    let now = rendered();
    if std::env::var("CMUX_UPDATE_CLOUD_POWER_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_CLOUD_POWER_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_CLOUD_POWER_TABLE=1 cargo test -p cmux-cloud-machine power` and commit it",
        path.display()
    );
}

/// Every state against every event is a transition or a named refusal, and the table holds
/// exactly those pairs.
#[test]
fn every_state_against_every_event_is_decided() {
    let mut pairs = 0;
    let mut refusals = 0;
    for (machine, kind) in sample_states().into_iter().zip(Power::KINDS) {
        assert_eq!(machine.power.kind(), kind);
        for (event, event_kind) in sample_events(SAMPLE).into_iter().zip(Event::KINDS) {
            assert_eq!(event.kind(), event_kind);
            pairs += 1;
            match step(machine, event) {
                Ok((after, _)) => assert!(after.issued >= machine.issued),
                Err(refusal) => {
                    assert!(Refusal::ALL.contains(&refusal));
                    refusals += 1;
                }
            }
        }
    }
    assert_eq!(pairs, STATES * EVENTS);
    let table = table();
    let rows = table["transitions"].as_array().expect("transitions");
    assert_eq!(rows.len(), pairs);
    let table_refusals = rows.iter().filter(|row| row.get("refusal").is_some()).count();
    assert_eq!(table_refusals, refusals);
    assert_eq!(table["states"].as_array().expect("states").len(), STATES);
    assert_eq!(table["events"].as_array().expect("events").len(), EVENTS);
    println!(
        "power table: {STATES} states x {EVENTS} events = {pairs} pairs, {} transitions, {refusals} refusals",
        pairs - refusals
    );
}

#[test]
fn pause_only_from_running() {
    for machine in sample_states() {
        let result = step(machine, Event::Pause { reason: PauseReason::Idle });
        let running = matches!(machine.power, Power::Running { .. } | Power::Ready { .. });
        assert_eq!(result.is_ok(), running, "pause from {}", machine.power.kind());
        if let Ok((after, effects)) = result {
            assert!(matches!(after.power, Power::Pausing { reason: PauseReason::Idle, .. }));
            assert!(
                matches!(effects[0], Effect::Pause { generation, .. } if generation == after.issued)
            );
        }
    }
}

#[test]
fn resume_only_from_paused() {
    for machine in sample_states() {
        let result = step(machine, Event::Resume);
        let paused = matches!(machine.power, Power::Paused { .. });
        assert_eq!(result.is_ok(), paused, "resume from {}", machine.power.kind());
    }
}

#[test]
fn nothing_leaves_destroyed() {
    let destroyed = Machine { power: Power::Destroyed, issued: SAMPLE };
    for generation in [Generation(0), SAMPLE, Generation(SAMPLE.0 + 1)] {
        for event in sample_events(generation) {
            assert_eq!(step(destroyed, event), Err(Refusal::Destroyed), "{}", event.kind());
        }
    }
}

#[test]
fn attach_only_when_ready() {
    for machine in sample_states() {
        let result = step(machine, Event::Attach);
        let ready = matches!(machine.power, Power::Ready { .. });
        assert_eq!(result.is_ok(), ready, "attach from {}", machine.power.kind());
        if let Ok((after, effects)) = result {
            assert_eq!(after, machine);
            assert_eq!(effects, vec![Effect::Attach]);
        }
    }
    let running = Machine { power: Power::Running { since: SAMPLE }, issued: SAMPLE };
    assert_eq!(step(running, Event::Attach), Err(Refusal::NotReady));
}

#[test]
fn paused_at_and_failed_at_only_on_their_variant() {
    for machine in sample_states() {
        let json = serde_json::to_value(machine.power).expect("power serializes");
        assert_eq!(json["state"], machine.power.kind());
        let paused = matches!(machine.power, Power::Paused { .. });
        let failed = matches!(machine.power, Power::Failed { .. });
        assert_eq!(json.get("pausedAt").is_some(), paused, "{json}");
        assert_eq!(json.get("failedAt").is_some(), failed, "{json}");
        let back: Power = serde_json::from_value(json).expect("power reads back");
        assert_eq!(back, machine.power);
    }
}

/// An answer under any generation but the awaited one is refused, by name, and changes nothing.
#[test]
fn an_older_generation_is_refused() {
    for machine in sample_states() {
        for generation in [Generation(SAMPLE.0 - 1), Generation(SAMPLE.0 + 1), Generation(0)] {
            for event in sample_events(generation) {
                if event.generation().is_none() {
                    continue;
                }
                let expected = match machine.power {
                    Power::Destroyed => Refusal::Destroyed,
                    power if power.awaits().is_some() => {
                        // A state answers only its own kind of answer; others are not awaited.
                        match step(machine, sample_answer(event)) {
                            Ok(_) => Refusal::StaleGeneration,
                            Err(refusal) => refusal,
                        }
                    }
                    _ => Refusal::NotAwaited,
                };
                assert_eq!(
                    step(machine, event),
                    Err(expected),
                    "{} {} under {generation:?}",
                    machine.power.kind(),
                    event.kind()
                );
            }
        }
    }
}

/// `event` with its generation swapped for [`SAMPLE`].
fn sample_answer(event: Event) -> Event {
    sample_events(SAMPLE)
        .into_iter()
        .find(|sample| sample.kind() == event.kind())
        .expect("sample of every kind")
}

#[test]
fn at_most_one_power_operation_in_flight() {
    for machine in sample_states() {
        for event in sample_events(SAMPLE) {
            let Ok((after, effects)) = step(machine, event) else { continue };
            let calls = effects.iter().filter(|effect| effect.is_power_call()).count();
            assert!(calls <= 1);
            if calls == 1 {
                assert!(machine.power.in_flight().is_none());
                assert_eq!(after.power.in_flight(), Some(after.issued));
            }
        }
        if machine.power.in_flight().is_some() {
            for event in [Event::Pause { reason: PauseReason::User }, Event::Resume, Event::Delete]
            {
                assert_eq!(step(machine, event), Err(Refusal::OperationInFlight));
            }
        }
    }
}

/// Create, become ready, attach, pause, resume; the paused machine's late pause timer and the
/// resumed machine's stale pause answer both bounce.
#[test]
fn a_whole_life() {
    let (m, effects) = Machine::create();
    assert_eq!(effects[0], Effect::Create { generation: Generation(1) });
    let (m, effects) = step(m, Event::Succeeded { generation: Generation(1), at: 10 }).unwrap();
    assert_eq!(m.power, Power::Running { since: Generation(2) });
    assert_eq!(effects[0], Effect::AwaitDaemon { generation: Generation(2) });
    assert_eq!(
        step(m, Event::TimedOut { generation: Generation(1) }),
        Err(Refusal::StaleGeneration)
    );
    let (m, _) = step(m, Event::DaemonReady { generation: Generation(2) }).unwrap();
    assert_eq!(m.power.kind(), "ready");
    let (m, effects) = step(m, Event::Attach).unwrap();
    assert_eq!(effects, vec![Effect::Attach]);
    let (m, _) = step(m, Event::Pause { reason: PauseReason::User }).unwrap();
    let (m, _) = step(m, Event::Succeeded { generation: Generation(3), at: 20 }).unwrap();
    assert_eq!(m.power, Power::Paused { paused_at: 20, reason: Some(PauseReason::User) });
    assert_eq!(step(m, Event::TimedOut { generation: Generation(3) }), Err(Refusal::NotAwaited));
    let (m, _) = step(m, Event::Resume).unwrap();
    assert_eq!(m.power, Power::Starting { op: Generation(4) });
    assert_eq!(
        step(m, Event::Failed { generation: Generation(3), at: 30 }),
        Err(Refusal::StaleGeneration)
    );
    let (m, _) = step(m, Event::TimedOut { generation: Generation(4) }).unwrap();
    assert_eq!(m.power, Power::Unknown { probe: Generation(5) });
    let (m, _) = step(
        m,
        Event::Observed { generation: Generation(5), observation: Observation::Running, at: 40 },
    )
    .unwrap();
    assert_eq!(m.power, Power::Running { since: Generation(6) });
    let (m, _) = step(m, Event::Delete).unwrap();
    let (m, _) = step(m, Event::Succeeded { generation: Generation(7), at: 50 }).unwrap();
    assert_eq!(m.power, Power::Destroyed);
}

#[test]
fn table_states_name_record_statuses() {
    let table = table();
    for state in table["states"].as_array().expect("states") {
        let word = state["status"].as_str().expect("status");
        assert_eq!(Status::from_word(word).as_str(), word);
    }
    for status in Status::ALL {
        let observation = Observation::from_status(status);
        assert!(Observation::ALL.contains(&observation));
    }
    assert_eq!(table["refusals"], Value::from(Refusal::ALL.map(Refusal::as_str).to_vec()));
}

/// xorshift64: deterministic, no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// The invariants one step must keep, whatever came before.
fn check(before: Machine, event: Event, result: &Step) {
    let name = || format!("{} {:?} -> {result:?}", before.power.kind(), event);
    match result {
        Err(_) => {}
        Ok((after, effects)) => {
            assert!(after.issued >= before.issued, "{}", name());
            assert!(after.issued.0 <= before.issued.0 + 1, "{}", name());
            for effect in effects {
                if let Some(generation) = effect.generation() {
                    assert_eq!(generation, after.issued, "{}", name());
                    assert!(generation > before.issued, "{}", name());
                }
            }
            if let Some(awaited) = after.power.awaits()
                && after.power != before.power
            {
                assert!(awaited > before.issued, "a new wait reuses a generation: {}", name());
            }
            let calls = effects.iter().filter(|effect| effect.is_power_call()).count();
            assert!(calls <= 1, "{}", name());
            if calls == 1 {
                assert!(before.power.in_flight().is_none(), "{}", name());
            }
        }
    }
    match event {
        Event::Pause { .. } if result.is_ok() => {
            assert!(
                matches!(before.power, Power::Running { .. } | Power::Ready { .. }),
                "{}",
                name()
            );
        }
        Event::Resume if result.is_ok() => {
            assert!(matches!(before.power, Power::Paused { .. }), "{}", name());
        }
        Event::Attach if result.is_ok() => {
            assert!(matches!(before.power, Power::Ready { .. }), "{}", name());
        }
        _ => {}
    }
    if matches!(event, Event::Pause { .. } | Event::Resume | Event::Delete)
        && before.power.in_flight().is_some()
    {
        assert_eq!(*result, Err(Refusal::OperationInFlight), "{}", name());
    }
    if before.power == Power::Destroyed {
        assert_eq!(*result, Err(Refusal::Destroyed), "{}", name());
    }
    if let Some(generation) = event.generation()
        && before.power != Power::Destroyed
        && before.power.awaits() != Some(generation)
    {
        let refusal = result.as_ref().err().copied();
        assert!(
            matches!(refusal, Some(Refusal::StaleGeneration | Refusal::NotAwaited)),
            "{}",
            name()
        );
    }
    let json = serde_json::to_value(result.as_ref().map_or(before.power, |(after, _)| after.power))
        .expect("power serializes");
    let state = json["state"].as_str().expect("state");
    assert_eq!(json.get("pausedAt").is_some(), state == "paused");
    assert_eq!(json.get("failedAt").is_some(), state == "failed");
}

/// Seeded random walks of 12 events from a new and an adopted machine; answers carry the awaited
/// generation, an older one, the last issued one or a future one.
#[test]
fn random_walks_keep_the_invariants() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let mut seen = std::collections::BTreeSet::new();
    for walk in 0..4000 {
        let (mut machine, _) = if walk % 2 == 0 { Machine::create() } else { Machine::adopt() };
        for _ in 0..12 {
            let awaited = machine.power.awaits().unwrap_or(machine.issued);
            let generation = match rng.below(5) {
                0 | 1 => awaited,
                2 => Generation(awaited.0.saturating_sub(1)),
                3 => machine.issued,
                _ => Generation(machine.issued.0 + 1),
            };
            let events = sample_events(generation);
            let mut event = events[rng.below(events.len() as u64) as usize];
            if let Event::Pause { reason } = &mut event
                && rng.below(2) == 0
            {
                *reason = PauseReason::Idle;
            }
            let result = step(machine, event);
            check(machine, event, &result);
            if let Ok((after, _)) = result {
                machine = after;
            }
            seen.insert(machine.power.kind());
        }
    }
    assert_eq!(seen.len(), STATES, "the walks reach every state: {seen:?}");
}

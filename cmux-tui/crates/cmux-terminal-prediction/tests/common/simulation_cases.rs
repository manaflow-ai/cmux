//! The seeded case generators, the seed sweep and the shrinker.

use super::random::SimulationRandom;
use super::screen::{SimulatedEraseForm, SimulatedKey};
use super::simulation::{PredictionSimulation, SimulatedKeystroke, SimulationCase, SimulationFailure};
use std::ops::RangeInclusive;

pub const ALPHABET: &[u8] = b"asdfjo";

/// Appends a keystroke whose round trip and split are drawn around
/// `round_trip`, in the Swift suite's draw order.
fn add(
    random: &mut SimulationRandom,
    keystrokes: &mut Vec<SimulatedKeystroke>,
    key: SimulatedKey,
    gap: i64,
    round_trip: i64,
    trip_percent: (i64, i64),
    uplink_percent: (i64, i64),
) {
    let trip = round_trip * random.int_in(trip_percent.0, trip_percent.1) / 100;
    let uplink = trip * random.int_in(uplink_percent.0, uplink_percent.1) / 100;
    let jitter_seed = random.next_u64();
    keystrokes.push(SimulatedKeystroke { key, gap, uplink, downlink: trip - uplink, jitter_seed });
}

fn character(random: &mut SimulationRandom) -> SimulatedKey {
    SimulatedKey::Character(random.element(ALPHABET))
}

pub fn make(seed: u64) -> SimulationCase {
    let mut random = SimulationRandom::new(seed);
    // Both sides of the 25 ms engage threshold.
    let round_trip = random.element(&[3_000, 12_000, 30_000, 50_000, 70_000, 120_000, 250_000]);
    let mut keystrokes = Vec::new();
    let r = &mut random;
    let k = &mut keystrokes;
    let push = |r: &mut SimulationRandom, k: &mut Vec<SimulatedKeystroke>, key, gap| {
        add(r, k, key, gap, round_trip, (60, 140), (30, 70));
    };

    let length = r.int_in(4, 60) as usize;
    while k.len() < length {
        match r.int_below(0, 10) {
            0..=3 => {
                for _ in 0..r.int_in(1, 8) {
                    let key = character(r);
                    let gap = r.int_in(15_000, 180_000);
                    push(r, k, key, gap);
                }
            }
            4..=5 => {
                for _ in 0..r.int_in(1, 6) {
                    let gap = r.int_in(30_000, 160_000);
                    push(r, k, SimulatedKey::Backspace, gap);
                }
            }
            6 => {
                // A held key: the initial delay, then autorepeat.
                let key = if r.bool() { SimulatedKey::Backspace } else { character(r) };
                let gap = r.int_in(20_000, 200_000);
                push(r, k, key, gap);
                for _ in 0..r.int_in(2, 12) {
                    push(r, k, key, 33_000);
                }
            }
            7 => {
                let key = character(r);
                let gap = r.int_in(300_000, 2_500_000);
                push(r, k, key, gap);
            }
            _ => {
                // A typo corrected at typing speed.
                let key = character(r);
                let gap = r.int_in(30_000, 120_000);
                push(r, k, key, gap);
                let gap = r.int_in(40_000, 140_000);
                push(r, k, SimulatedKey::Backspace, gap);
            }
        }
    }
    let erase_form = r.element(&SimulatedEraseForm::ALL_CASES);
    SimulationCase { keystrokes, erase_form, coalesces_typeahead: false }
}

/// The dogfood report: a fast burst, then Backspace mashed or held at
/// key-repeat speed, over a link slow enough to predict. Sometimes the
/// Backspaces run past the burst into the prompt, where bash rings the bell,
/// and sometimes they start after part of the burst was echoed.
pub fn make_burst_then_delete(seed: u64) -> SimulationCase {
    let mut random = SimulationRandom::new(seed);
    let r = &mut random;
    let round_trip = r.int_in(30_000, 250_000);
    let mut keystrokes = Vec::new();
    let k = &mut keystrokes;
    let push = |r: &mut SimulationRandom, k: &mut Vec<SimulatedKeystroke>, key, gap| {
        add(r, k, key, gap, round_trip, (80, 120), (40, 60));
    };

    // Two keys echoed one at a time first: the run arms only after two
    // echoes in a row, and this case is about what happens once it has.
    for _ in 0..2 {
        let key = character(r);
        push(r, k, key, round_trip * 3);
    }
    for _ in 0..r.int_in(1, 3) {
        let burst = r.int_in(1, 12);
        for _ in 0..burst {
            let key = character(r);
            let gap = r.int_in(15_000, 70_000);
            push(r, k, key, gap);
        }
        let pause = if r.bool() { r.int_in(20_000, 60_000) } else { r.int_in(100_000, 600_000) };
        let deletes = (burst + r.int_in(-3, 3)).max(1);
        for index in 0..deletes {
            let gap = if index == 0 { pause } else { r.int_in(28_000, 40_000) };
            push(r, k, SimulatedKey::Backspace, gap);
        }
        let key = character(r);
        let gap = r.int_in(50_000, 900_000);
        push(r, k, key, gap);
    }
    let erase_form = if r.int_below(0, 4) == 0 {
        r.element(&SimulatedEraseForm::ALL_CASES)
    } else {
        SimulatedEraseForm::BackspaceClearToEnd
    };
    SimulationCase { keystrokes, erase_form, coalesces_typeahead: false }
}

/// Runs the seeds and reports the first failure, shrunk, with the case as a
/// literal to pin as a regression.
pub fn first_failure(seeds: RangeInclusive<u64>, make: impl Fn(u64) -> SimulationCase) -> Option<String> {
    for seed in seeds {
        let simulation_case = make(seed);
        if PredictionSimulation::new(simulation_case.clone()).run().is_none() {
            continue;
        }
        let (minimal, failure) = shrink(simulation_case);
        return Some(format!("seed {seed}\n{}\n{failure}", literal(&minimal)));
    }
    None
}

pub fn literal(simulation_case: &SimulationCase) -> String {
    let keystrokes: Vec<String> = simulation_case
        .keystrokes
        .iter()
        .map(|keystroke| {
            let key = match keystroke.key {
                SimulatedKey::Character(byte) => format!("Character(b'{}')", char::from(byte)),
                SimulatedKey::Backspace => "Backspace".to_string(),
            };
            format!(
                "    ks({key}, {}, {}, {}, {}),",
                keystroke.gap, keystroke.uplink, keystroke.downlink, keystroke.jitter_seed
            )
        })
        .collect();
    format!("SimulationCase {{ keystrokes: vec![\n{}\n], erase_form: {:?} }}", keystrokes.join("\n"), simulation_case.erase_form)
}

/// Deletes keystrokes while the case still fails, for a readable trace.
pub fn shrink(failing: SimulationCase) -> (SimulationCase, SimulationFailure) {
    let mut current = failing;
    let mut failure = PredictionSimulation::new(current.clone()).run().expect("the case fails");
    let mut progress = true;
    while progress {
        progress = false;
        let mut index = 0;
        while index < current.keystrokes.len() {
            let mut candidate = current.clone();
            let removed = candidate.keystrokes.remove(index);
            if index < candidate.keystrokes.len() {
                candidate.keystrokes[index].gap += removed.gap;
            }
            if let Some(smaller) = PredictionSimulation::new(candidate.clone()).run() {
                current = candidate;
                failure = smaller;
                progress = true;
            } else {
                index += 1;
            }
        }
    }
    (current, failure)
}

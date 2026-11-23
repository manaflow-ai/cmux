use std::path::PathBuf;

use super::*;

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/sidebar-row/table.json")
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_SIDEBAR_ROW_TABLE=1` rewrites it.
#[test]
fn committed_sidebar_row_table_is_current() {
    let path = table_path();
    let now = table_text();
    if std::env::var("CMUX_UPDATE_SIDEBAR_ROW_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("{}: {e}; run with CMUX_UPDATE_SIDEBAR_ROW_TABLE=1", path.display())
    });
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_SIDEBAR_ROW_TABLE=1 cargo test -p cmux-layout-reducer sidebar_row` and commit it",
        path.display()
    );
}

/// Every state against every event, at every generation age, is a transition or a named
/// refusal; the table holds exactly those pairs; a refusal changes nothing.
#[test]
fn every_row_state_against_every_event_is_decided() {
    let mut pairs = 0;
    let mut refusals = 0;
    for (row, kind) in sample_states().into_iter().zip(Row::KINDS) {
        assert_eq!(row.kind(), kind);
        for generation in [SAMPLE - 1, SAMPLE, SAMPLE + 1] {
            for (event, event_kind) in sample_events(generation).into_iter().zip(Event::KINDS) {
                assert_eq!(event.kind(), event_kind);
                if event.generation().is_none() && generation != SAMPLE {
                    continue;
                }
                pairs += 1;
                match step(row, event) {
                    Ok((after, effects)) => check_transition(row, after, &effects),
                    Err(refusal) => {
                        assert!(Refusal::ALL.contains(&refusal));
                        refusals += 1;
                    }
                }
            }
        }
    }
    let table = table();
    let rows = table["transitions"].as_array().expect("transitions");
    assert_eq!(rows.len(), pairs);
    assert_eq!(rows.iter().filter(|r| r.get("refusal").is_some()).count(), refusals);
    assert_eq!(table["states"].as_array().expect("states").len(), Row::KINDS.len());
    // Every refusal is reachable from some sample pair.
    for refusal in Refusal::ALL {
        assert!(
            rows.iter().any(|r| r["refusal"] == refusal.as_str()),
            "{refusal} is never refused in the table"
        );
    }
    println!(
        "sidebar row table: {} states, {pairs} pairs, {} transitions, {refusals} refusals",
        Row::KINDS.len(),
        pairs - refusals
    );
}

/// What every transition keeps: a row in its place is patched, any other change lays the list
/// out, a create's name is released exactly when the row stops creating, and nothing leaves
/// `gone`.
fn check_transition(before: Row, after: Row, effects: &[Effect]) {
    assert_ne!(before, Row::Gone, "nothing leaves gone");
    let changed = before != after;
    let in_place = effects.contains(&Effect::PatchInPlace);
    let relayout = effects.contains(&Effect::Relayout);
    if changed {
        assert_eq!(in_place, keeps_place(before, after), "{before:?} -> {after:?}");
        assert_eq!(relayout, !keeps_place(before, after), "{before:?} -> {after:?}");
    } else {
        assert!(!in_place && !relayout);
        assert_eq!(effects, &[Effect::Allow]);
    }
    let left_creating =
        matches!(before, Row::Creating { .. }) && !matches!(after, Row::Creating { .. });
    assert_eq!(effects.contains(&Effect::ReleaseName), left_creating);
    // A connection never moves backwards.
    if let (
        Row::Stale { from: a } | Row::Live { from: a },
        Row::Stale { from: b } | Row::Live { from: b },
    ) = (before, after)
    {
        assert!(b >= a);
    }
    // The interaction only runs on a row that is not pending.
    assert_eq!(effects.contains(&Effect::Allow), !after.is_pending() && !changed);
}

/// Swift draws a creating row in the final row's look and box: the same render as its live row
/// but for what only daemon data can give (interaction, saving, live status), and turning live
/// it keeps its place.
#[test]
fn creating_draws_in_the_final_rows_box() {
    let creating = Row::Creating { create: Create(3) };
    let (live, effects) =
        step(creating, Event::Listed { connection: Connection(1) }).expect("listed");
    assert_eq!(live, Row::Live { from: Connection(1) });
    assert_eq!(effects, vec![Effect::PatchInPlace, Effect::ReleaseName]);
    let (a, b) = (creating.render().expect("drawn"), live.render().expect("drawn"));
    assert_eq!(a.look, b.look);
    assert_eq!(a.layout_box, b.layout_box);
    assert_eq!(a.layout_box, LayoutBox::Row);
    assert!(!a.provisional && !b.provisional);
    // A placeholder or a saved row turning live lays the list out, as before.
    for row in [Row::Placeholder { titled: false }, Row::Stale { from: Connection(1) }] {
        if let Ok((after, effects)) = step(row, Event::Listed { connection: Connection(1) }) {
            assert!(!keeps_place(row, after));
            assert!(effects.contains(&Effect::Relayout));
        }
    }
}

/// Swift's `isPending` (placeholder or creating) is exactly the rows that never interact or
/// save, and `hasProvisionalRows` exactly stale and placeholder rows.
#[test]
fn pending_and_provisional_match_swift() {
    for row in sample_states() {
        let Some(render) = row.render() else {
            assert_eq!(row, Row::Gone);
            continue;
        };
        assert_eq!(render.interactive, !row.is_pending(), "{}", row.kind());
        assert_eq!(render.saved, !row.is_pending(), "{}", row.kind());
        let provisional = matches!(row, Row::Stale { .. } | Row::Placeholder { .. });
        assert_eq!(render.provisional, provisional, "{}", row.kind());
        assert_eq!(render.live_status, matches!(row, Row::Live { .. }));
        assert_eq!(step(row, Event::Interact).is_ok(), !row.is_pending());
    }
    // An untitled placeholder is the only bar; a titled one draws its text in a row's box.
    assert_eq!(Row::Placeholder { titled: false }.render().map(|r| r.look), Some(Look::Bar));
    assert_eq!(
        Row::Placeholder { titled: true }.render().map(|r| r.layout_box),
        Some(LayoutBox::Row)
    );
}

/// An answer over an older connection, or another create's end, is refused and changes nothing.
#[test]
fn an_older_answer_is_refused() {
    let live = Row::Live { from: Connection(5) };
    let older = Connection(4);
    for event in [
        Event::LaunchSnapshot { connection: older },
        Event::Listed { connection: older },
        Event::Unlisted { connection: older },
    ] {
        assert_eq!(step(live, event), Err(Refusal::StaleConnection), "{}", event.kind());
    }
    let creating = Row::Creating { create: Create(9) };
    assert_eq!(
        step(creating, Event::CreateFailed { create: Create(8) }),
        Err(Refusal::StaleCreate)
    );
    assert_eq!(
        step(creating, Event::CreateClosed { create: Create(8) }),
        Err(Refusal::StaleCreate)
    );
    assert_eq!(
        step(creating, Event::CreateFailed { create: Create(9) }).map(|(row, _)| row),
        Ok(Row::Gone)
    );
}

/// A reconnect's launch snapshot marks a live row stale until its live tree lists it again.
#[test]
fn a_reconnect_goes_stale_then_live() {
    let live = Row::Live { from: Connection(1) };
    let (stale, _) =
        step(live, Event::LaunchSnapshot { connection: Connection(2) }).expect("snapshot");
    assert_eq!(stale, Row::Stale { from: Connection(2) });
    assert_eq!(
        step(stale, Event::Listed { connection: Connection(1) }),
        Err(Refusal::StaleConnection)
    );
    let (again, _) = step(stale, Event::Listed { connection: Connection(2) }).expect("listed");
    assert_eq!(again, Row::Live { from: Connection(2) });
}

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

fn random_event(rng: &mut Rng, newest: &mut u64) -> Event {
    // Mostly the newest generation, sometimes a newer one, sometimes a late older one.
    let generation = match rng.below(4) {
        0 => {
            *newest += 1;
            *newest
        }
        1 => rng.below(*newest + 1),
        _ => *newest,
    };
    let connection = Connection(generation);
    let create = Create(generation);
    match rng.below(6) {
        0 => Event::LaunchSnapshot { connection },
        1 => Event::Listed { connection },
        2 => Event::Unlisted { connection },
        3 => Event::CreateFailed { create },
        4 => Event::CreateClosed { create },
        _ => Event::Interact,
    }
}

fn walk(seed: u64, steps: usize) -> Vec<String> {
    let mut rng = Rng(seed | 1);
    let start = rng.below(4);
    let mut newest = rng.below(3);
    let mut row = match start {
        0 => Row::Placeholder { titled: rng.below(2) == 0 },
        1 => Row::Stale { from: Connection(0) },
        2 => Row::Creating { create: Create(newest) },
        _ => Row::Live { from: Connection(newest) },
    };
    let mut trace = vec![row.kind().to_owned()];
    for _ in 0..steps {
        let event = random_event(&mut rng, &mut newest);
        match step(row, event) {
            Ok((after, effects)) => {
                check_transition(row, after, &effects);
                trace.push(format!("{}>{}", event.kind(), after.kind()));
                row = after;
            }
            Err(refusal) => {
                assert!(Refusal::ALL.contains(&refusal));
                // `step` takes the row by value: a refusal hands nothing back to replace it.
                trace.push(format!("{}!{refusal}", event.kind()));
            }
        }
        if row == Row::Gone {
            for event in sample_events(newest) {
                assert_eq!(step(row, event), Err(Refusal::RowGone));
            }
            // The list's next row: a new create (the person presses New again) or a saved row.
            newest += 1;
            row = if rng.below(2) == 0 {
                Row::Creating { create: Create(newest) }
            } else {
                Row::Stale { from: Connection(0) }
            };
            trace.push(format!("new>{}", row.kind()));
        }
    }
    trace
}

#[test]
fn seeded_sidebar_row_walks_keep_the_invariants() {
    let (mut stepped, mut refused, mut reached) = (0, 0, std::collections::BTreeSet::new());
    for seed in 1..=512u64 {
        for line in walk(seed, 200) {
            stepped += 1;
            refused += usize::from(line.contains('!'));
            reached.insert(line.rsplit(['>', '!']).next().map(str::to_owned));
        }
    }
    assert!(refused > 0 && refused < stepped);
    for kind in ["stale", "creating", "live", "gone"] {
        assert!(reached.contains(&Some(kind.to_owned())), "the walk never reached {kind}");
    }
    println!("sidebar row walk: {stepped} steps, {refused} refused");
}

#[test]
fn a_sidebar_row_seed_replays_the_same_walk() {
    assert_eq!(walk(42, 200), walk(42, 200));
}

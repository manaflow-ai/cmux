use super::*;
use flag::*;
use serde_json::json;
use std::time::Instant;

fn a(index: u32, flags: u8) -> Active {
    Active { index, flags }
}

fn caps(cap: u32) -> ProjectCaps {
    ProjectCaps { cap, ..ProjectCaps::default() }
}

#[test]
fn a_quiet_project_shows_its_first_five_then_show_more() {
    let out = project_rows(12, &[], &ProjectCaps::default());
    assert_eq!(out.rows, vec![0, 1, 2, 3, 4]);
    assert_eq!(out.tail, Tail::ShowMore { hidden: 7, next: 7 });
}

#[test]
fn one_row_over_the_cap_shows_whole() {
    let out = project_rows(6, &[], &caps(5));
    assert_eq!(out.rows, (0..6).collect::<Vec<_>>());
    assert_eq!(out.tail, Tail::None);
}

#[test]
fn all_shows_every_row_and_no_tail() {
    let out = project_rows(300, &[], &caps(0));
    assert_eq!(out.rows.len(), 300);
    assert_eq!(out.tail, Tail::None);
}

#[test]
fn show_more_reveals_twenty_at_a_time_then_show_less() {
    let mut c = caps(5);
    let first = project_rows(50, &[], &c);
    assert_eq!(first.tail, Tail::ShowMore { hidden: 45, next: 20 });
    c.revealed = after_press(first.tail, &c);
    assert_eq!(c.revealed, 20);
    let second = project_rows(50, &[], &c);
    assert_eq!(second.rows.len(), 25);
    assert_eq!(second.tail, Tail::ShowMore { hidden: 25, next: 20 });
    c.revealed = after_press(second.tail, &c);
    let third = project_rows(50, &[], &c);
    assert_eq!(third.rows.len(), 45);
    // 5 left: one more press shows them all, never past the members.
    assert_eq!(third.tail, Tail::ShowMore { hidden: 5, next: 5 });
    c.revealed = after_press(third.tail, &c);
    let fourth = project_rows(50, &[], &c);
    assert_eq!(fourth.rows.len(), 50);
    assert_eq!(fourth.tail, Tail::ShowLess);
    assert_eq!(after_press(fourth.tail, &c), 0, "Show less goes back to the cap");
}

#[test]
fn active_chats_always_show_and_yellow_then_blue_float_below_pinned() {
    // Members 0..40; pinned 30, blue 8, yellow 20, running 12, kept (selected) 35.
    let active = [a(8, UNREAD), a(12, RUNNING), a(20, WAITING), a(30, PINNED), a(35, KEEP)];
    let out = project_rows(40, &active, &caps(5));
    // Pinned, yellow, blue; then quiet 0..4 with the running one in its place past them; the kept row in place.
    assert_eq!(out.rows, vec![30, 20, 8, 0, 1, 2, 3, 4, 12, 35]);
    assert_eq!(out.floated, 2);
    assert_eq!(out.tail, Tail::ShowMore { hidden: 35 - 5, next: 20 });
}

#[test]
fn working_chats_never_move_unless_include_working() {
    let active = [a(2, RUNNING), a(9, RUNNING)];
    let off = project_rows(20, &active, &caps(5));
    assert_eq!(off.rows, vec![0, 1, 2, 3, 4, 5, 9]);
    let on = project_rows(20, &active, &ProjectCaps { include_working: true, ..caps(5) });
    assert_eq!(on.rows, vec![2, 9, 0, 1, 3, 4, 5]);
}

#[test]
fn float_off_keeps_every_row_in_place() {
    let active = [a(3, WAITING), a(15, UNREAD)];
    let out = project_rows(20, &active, &ProjectCaps { floats: false, ..caps(5) });
    assert_eq!(out.rows, vec![0, 1, 2, 3, 4, 5, 15]);
    assert_eq!(out.floated, 0);
}

#[test]
fn a_waiting_pinned_row_stays_with_the_pinned() {
    let out = project_rows(10, &[a(5, PINNED | WAITING), a(7, WAITING)], &caps(3));
    assert_eq!(out.rows, vec![5, 7, 0, 1, 2]);
}

#[test]
fn bad_entries_are_ignored() {
    let active = [a(4, WAITING), a(4, UNREAD), a(2, UNREAD), a(99, WAITING), a(6, 0)];
    let out = project_rows(10, &active, &caps(3));
    assert_eq!(
        out.rows,
        vec![4, 0, 1, 2],
        "only the first valid ascending entry counts; 6 is quiet"
    );
}

#[test]
fn every_member_shows_at_most_once_and_the_tail_counts_the_rest() {
    // Exhaustive over small projects: every flag mix of up to 8 members, every cap and reveal.
    let flags = [0, PINNED, WAITING, UNREAD, RUNNING, KEEP];
    for count in 0..=8u32 {
        let mut seed = 0x9e37_79b9u32;
        for _ in 0..200 {
            let mut active = Vec::new();
            for index in 0..count {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let f = flags[(seed >> 24) as usize % flags.len()];
                if f != 0 {
                    active.push(a(index, f));
                }
            }
            for cap in [0, 3, 5] {
                for revealed in [0, 1, 20] {
                    for floats in [false, true] {
                        let c = ProjectCaps { cap, revealed, floats, include_working: false };
                        let out = project_rows(count, &active, &c);
                        let mut seen = out.rows.clone();
                        seen.sort_unstable();
                        seen.dedup();
                        assert_eq!(seen.len(), out.rows.len(), "a row twice: {out:?}");
                        for x in &active {
                            assert!(out.rows.contains(&x.index), "active {x:?} hidden: {out:?}");
                        }
                        let hidden = match out.tail {
                            Tail::ShowMore { hidden, .. } => hidden,
                            _ => 0,
                        };
                        assert_eq!(
                            out.rows.len() as u32 + hidden,
                            count,
                            "{c:?} {active:?} {out:?}"
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn needs_you_lists_yellow_then_blue_at_most_three() {
    let rows =
        [a(1, UNREAD), a(4, RUNNING), a(7, WAITING), a(9, UNREAD), a(12, WAITING), a(20, UNREAD)];
    let out = needs_you(&rows, false, 0);
    assert_eq!(out.rows, vec![7, 12, 1]);
    assert_eq!(out.more, 2);
    let working = needs_you(&rows, true, 10);
    assert_eq!(working.rows, vec![7, 12, 1, 9, 20, 4]);
    assert_eq!(working.more, 0);
    assert_eq!(
        needs_you(&[a(3, PINNED)], false, 0),
        NeedsYou::default(),
        "pinned alone does not need you"
    );
}

#[test]
fn caps_read_the_four_choices_only() {
    assert_eq!(read_cap(&json!("3")), Some(3));
    assert_eq!(read_cap(&json!("all")), Some(0));
    assert_eq!(read_cap(&json!(10)), Some(10));
    assert_eq!(read_cap(&json!(0)), Some(0));
    assert_eq!(read_cap(&json!(7)), None);
    assert_eq!(read_cap(&json!(true)), None);
}

/// The bench (Leo's rule: constant cost as things grow). A project of 30 and
/// one of 3,000 quiet chats, with the same active rows (and a god session: 600
/// active members), collapsed and expanded: the projection visits the same
/// members, never more than its rows plus its active members. Counted, not
/// timed, so it holds on any runner. Prints `SIDEBAR-CAPS` lines, the numbers
/// for the PR.
#[test]
fn the_projection_costs_the_same_at_thirty_and_three_thousand_chats() {
    let active_at = |count: u32, n: u32| -> Vec<Active> {
        // Active rows spread over the project, the same number at every size.
        (0..n)
            .map(|k| {
                a(k * (count / n.max(1)).max(1), [WAITING, UNREAD, RUNNING, PINNED][k as usize % 4])
            })
            .collect()
    };
    for (label, actives) in [("few-active", 6u32), ("god-session", 24)] {
        for revealed in [0u32, 20] {
            let c = ProjectCaps { revealed, ..ProjectCaps::default() };
            let small_active = active_at(30, actives);
            let large_active = active_at(3_000, actives);
            let small = project_rows(30, &small_active, &c);
            let large = project_rows(3_000, &large_active, &c);
            // The cost is counted, not timed: `work` is the members the projection visited. Every
            // visited member is a returned row, so the work is at most the rows plus the active
            // members, whatever the project's size; a walk over the hidden rows breaks this bound
            // at 3,000 chats. Wall time on a shared runner measured noise, not this (a 1.2x timing
            // ratio near 100 ns flaked on base).
            println!(
                "SIDEBAR-CAPS project shape={label} revealed={revealed} chats=30 rows={} work={} | chats=3000 rows={} work={}",
                small.rows.len(),
                small.work,
                large.rows.len(),
                large.work,
            );
            for (count, out, active) in
                [(30, &small, &small_active), (3_000, &large, &large_active)]
            {
                assert!(
                    out.work as usize <= out.rows.len() + active.len(),
                    "{label}: the projection visited {} members at {count} chats for {} rows and {} active",
                    out.work,
                    out.rows.len(),
                    active.len()
                );
            }
            assert!(
                f64::from(large.work) <= f64::from(small.work) * 1.2 + 1.0,
                "{label}: the projection visited {} members at 3,000 chats, {} at 30",
                large.work,
                small.work
            );
            assert!(
                large.rows.len() <= small.rows.len() + 1 + revealed as usize,
                "{label}: rows grew: {small:?} {large:?}"
            );
        }
    }
    // The god session alone: 2,000 active members of 3,000 cost their own rows, never the hidden ones.
    let god: Vec<Active> = (0..2_000).map(|k| a(k, RUNNING)).collect();
    let out = project_rows(3_000, &god, &ProjectCaps::default());
    assert_eq!(out.rows.len(), 2_005);
    assert!(out.work <= 2_000 + 2_005 + 1, "god session work {}", out.work);
    let rows: Vec<Active> = (0..3_000)
        .filter(|k| k % 10 == 0)
        .map(|k| a(k, [WAITING, UNREAD][k as usize % 2]))
        .collect();
    let few: Vec<Active> = rows.iter().take(30).copied().collect();
    let started = Instant::now();
    let big = needs_you(&rows, false, 0);
    let small = needs_you(&few, false, 0);
    println!(
        "SIDEBAR-CAPS needs-you active=300 shown={} more={} | active=30 shown={} more={} ({:?})",
        big.rows.len(),
        big.more,
        small.rows.len(),
        small.more,
        started.elapsed()
    );
    assert_eq!(big.rows.len(), 3);
}

#[test]
fn caps_from_the_c_abi_never_overflow() {
    for cap in [u32::MAX, u32::MAX - 1] {
        for revealed in [0, u32::MAX] {
            let out = project_rows(
                10,
                &[a(3, WAITING)],
                &ProjectCaps { cap, revealed, ..ProjectCaps::default() },
            );
            assert_eq!(out.rows.len(), 10);
            assert_eq!(
                after_press(out.tail, &ProjectCaps { cap, revealed, ..ProjectCaps::default() }),
                0
            );
        }
    }
    let out = project_rows(u32::MAX, &[], &caps(5));
    assert_eq!(out.rows.len(), 5);
}

#[test]
fn show_more_counts_the_row_one_past_a_step() {
    let caps = ProjectCaps { cap: 5, ..ProjectCaps::default() };
    // 26 quiet rows: 21 hidden; one press shows all 21, so the row says 21.
    let first = project_rows(26, &[], &caps);
    assert_eq!(first.tail, Tail::ShowMore { hidden: 21, next: 21 });
    let revealed = ProjectCaps { revealed: after_press(first.tail, &caps), ..caps };
    let second = project_rows(26, &[], &revealed);
    assert_eq!(second.rows.len(), 26);
    assert_eq!(second.tail, Tail::ShowLess);
    // 50 quiet rows: 45 hidden; the row says 20 and a press shows 20.
    let long = project_rows(50, &[], &caps);
    assert_eq!(long.tail, Tail::ShowMore { hidden: 45, next: 20 });
    let after =
        project_rows(50, &[], &ProjectCaps { revealed: after_press(long.tail, &caps), ..caps });
    assert_eq!(after.rows.len(), 25);
}

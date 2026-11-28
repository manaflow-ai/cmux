use super::*;
use serde_json::json;

fn event(seq: u64, at: u64) -> EventRecord {
    EventRecord {
        seq,
        at,
        dir: "mux".into(),
        kind: "status".into(),
        msg: json!({"seq": seq}),
        host_seq: None,
    }
}

fn page(events: &[u64], has_more: bool, page_through: u64) -> JournalPage {
    JournalPage {
        events: events.iter().map(|seq| event(*seq, *seq * 100)).collect(),
        has_more,
        page_through,
    }
}

#[test]
fn visible_preserves_unicode_at_the_preview_boundary() {
    assert_eq!(visible(""), "");
    let full = "🦀".repeat(640);
    assert_eq!(visible(&full), full);
    assert_eq!(visible(&format!("x{full}")), format!("…{full}"));
    assert_eq!(visible(&format!("{}z", "界".repeat(640))), format!("…{}z", "界".repeat(639)));
}

#[test]
fn duplicate_only_pages_advance_by_watermark_without_reducing_twice() {
    let mut values = Vec::new();
    let work = read(
        |after, _| {
            Ok(match after {
                0 => page(&[1], true, 1),
                1 => page(&[1], true, 8),
                8 => page(&[9], false, 9),
                _ => unreachable!(),
            })
        },
        |event| values.push(event.seq),
    )
    .unwrap();
    assert_eq!(values, [1, 9]);
    assert_eq!((work.pages, work.duplicates, work.reduced), (3, 1, 2));
    assert!(read(|_, _| Ok(page(&[1], true, 0)), |_| {}).is_err());
}

#[test]
fn sorts_deduplicates_and_consumes_an_empty_filtered_page() {
    let mut asks = Vec::new();
    let mut values = Vec::new();
    let work = read(
        |after, limit| {
            asks.push((after, limit));
            Ok(match after {
                0 => page(&[2, 1], true, 0),
                2 => page(&[], true, 8),
                8 => {
                    let mut overlap = page(&[2, 9], false, 9);
                    overlap.events[0].msg = json!("duplicate");
                    overlap
                }
                _ => unreachable!(),
            })
        },
        |e| values.push((e.seq, e.msg)),
    )
    .unwrap();
    assert_eq!(asks, [(0, 400), (2, 400), (8, 400)]);
    assert_eq!(values, [(1, json!({"seq":1})), (2, json!({"seq":2})), (9, json!({"seq":9}))]);
    assert_eq!((work.fetched, work.duplicates, work.reduced), (4, 1, 3));
}

#[test]
fn refuses_incomplete_or_out_of_contract_history() {
    assert!(
        read(|_, _| Ok(page(&[], true, 0)), |_| {})
            .unwrap_err()
            .to_string()
            .contains("did not advance")
    );
    assert!(read(|_, _| Ok(page(&[1; PAGE_SIZE + 1], false, 1)), |_| {}).is_err());
    assert!(
        read(
            |after, _| Ok(if after == 0 { page(&[3], true, 3) } else { page(&[2], false, 3) }),
            |_| {}
        )
        .is_err()
    );
}

#[test]
fn unique_visual_transitions_span_all_pages() {
    let mut plan = ReplayPlan::default();
    let work = read(
        |after, limit| {
            let end = (after + limit as u64).min(10_000);
            let mut batch = page(&(after + 1..=end).collect::<Vec<_>>(), end < 10_000, end);
            for record in &mut batch.events {
                record.msg =
                    json!({"status": if record.seq == 10_000 { "done" } else { "running" }});
            }
            Ok(batch)
        },
        |record| plan.apply(record),
    )
    .unwrap();
    assert_eq!((work.reduced, work.pages, work.largest_page), (10_000, 25, 400));
    assert_eq!(plan.transitions.len(), 2);
    assert_eq!(plan.transitions[0].state.status, "running");
    assert_eq!(plan.transitions[1].state.status, "done");
    assert_eq!(plan.duration, 999_900);
}

use super::*;

fn candidate(
    key: u64,
    kind: AttentionKind,
    level: AttentionLevel,
    age: u64,
) -> AttentionCandidate<u64> {
    AttentionCandidate { key, kind, level, age, position: key as usize }
}

fn keys(queue: &[AttentionCandidate<u64>]) -> Vec<u64> {
    queue.iter().map(|entry| entry.key).collect()
}

#[test]
fn attention_queue_puts_blocked_first_then_errors_then_unread_each_oldest_first() {
    let queue = attention_queue([
        candidate(1, AttentionKind::Unread, AttentionLevel::Info, 5),
        candidate(2, AttentionKind::Blocked, AttentionLevel::Warning, 900),
        candidate(3, AttentionKind::Unread, AttentionLevel::Error, 7),
        candidate(4, AttentionKind::Requested, AttentionLevel::Warning, 100),
        candidate(5, AttentionKind::Unread, AttentionLevel::Info, 2),
        candidate(6, AttentionKind::Unread, AttentionLevel::Warning, 6),
    ]);
    assert_eq!(keys(&queue), vec![4, 2, 6, 3, 5, 1]);
}

#[test]
fn attention_queue_keeps_one_entry_per_tab_with_its_strongest_reason() {
    let queue = attention_queue([
        candidate(1, AttentionKind::Unread, AttentionLevel::Info, 1),
        candidate(1, AttentionKind::Blocked, AttentionLevel::Warning, 50),
        candidate(2, AttentionKind::Unread, AttentionLevel::Info, 3),
    ]);
    assert_eq!(keys(&queue), vec![1, 2]);
    assert_eq!(queue[0].kind, AttentionKind::Blocked);
}

#[test]
fn attention_queue_breaks_age_ties_by_tree_position() {
    let mut later = candidate(9, AttentionKind::Blocked, AttentionLevel::Warning, 10);
    later.position = 0;
    let earlier = candidate(3, AttentionKind::Blocked, AttentionLevel::Warning, 10);
    assert_eq!(keys(&attention_queue([earlier, later])), vec![9, 3]);
}

/// W5-Q (bench r4 #5): blocked, then a finished agent turn nobody has
/// viewed, then any other unread notification (a bell), each tier oldest
/// first.
#[test]
fn w5q_attention_queue_puts_a_finished_turn_before_other_unread() {
    let queue = attention_queue([
        candidate(1, AttentionKind::Unread, AttentionLevel::Info, 5),
        candidate(2, AttentionKind::Done, AttentionLevel::Info, 50),
        candidate(3, AttentionKind::Blocked, AttentionLevel::Warning, 900),
        candidate(4, AttentionKind::Done, AttentionLevel::Info, 40),
    ]);
    assert_eq!(keys(&queue), vec![3, 4, 2, 1]);
    assert_eq!(AttentionKind::Done.as_str(), "done");
}

#[test]
fn next_attention_cycles_after_the_focused_tab_and_wraps() {
    let queue = attention_queue([
        candidate(1, AttentionKind::Blocked, AttentionLevel::Warning, 1),
        candidate(2, AttentionKind::Blocked, AttentionLevel::Warning, 2),
        candidate(3, AttentionKind::Unread, AttentionLevel::Info, 3),
    ]);
    assert_eq!(next_attention(&queue, None).map(|entry| entry.key), Some(1));
    assert_eq!(next_attention(&queue, Some(&7)).map(|entry| entry.key), Some(1));
    assert_eq!(next_attention(&queue, Some(&1)).map(|entry| entry.key), Some(2));
    assert_eq!(next_attention(&queue, Some(&2)).map(|entry| entry.key), Some(3));
    assert_eq!(next_attention(&queue, Some(&3)).map(|entry| entry.key), Some(1));
}

#[test]
fn next_attention_is_none_for_an_empty_queue_and_stays_on_a_single_entry() {
    let empty: Vec<AttentionCandidate<u64>> = Vec::new();
    assert!(next_attention(&empty, Some(&1)).is_none());
    let single = attention_queue([candidate(4, AttentionKind::Requested, AttentionLevel::Info, 1)]);
    assert_eq!(next_attention(&single, Some(&4)).map(|entry| entry.key), Some(4));
}

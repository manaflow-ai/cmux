use super::*;

#[test]
fn the_backoff_doubles_from_its_base_up_to_half_an_hour() {
    let waits: Vec<u64> = (1..=8).map(|n| backoff_ms(n, MIN_HOLD_MS) / 1000).collect();
    assert_eq!(waits, [60, 120, 240, 480, 960, 1800, 1800, 1800]);
    assert_eq!(backoff_ms(0, MIN_HOLD_MS), MIN_HOLD_MS);
    assert_eq!(backoff_ms(u32::MAX, MIN_HOLD_MS), MAX_HOLD_MS);
    assert_eq!(backoff_ms(3, 20), 80);
}

#[test]
fn the_base_is_the_continuations_minute() {
    assert_eq!(backoff_base(&[10_000, 60_000, 300_000, 1_200_000]), 60_000);
    assert_eq!(backoff_base(&[25]), 25);
    assert_eq!(backoff_base(&[]), MIN_HOLD_MS);
}

#[test]
fn the_park_line_says_how_to_go_on() {
    let line = park_line("claude-sr2-coord", 6, Some(334_751));
    assert_eq!(
        line,
        "acpmux: claude-sr2-coord is waiting out the rate limit: its last 6 turns failed on \
             it (HTTP 429), context 334K tokens. It is parked with its queue kept and tries \
             again by itself every half hour (compacted first); `acpmux retry claude-sr2-coord` \
             or the person's own prompt sends it on now."
    );
}

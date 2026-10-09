//! The admission rules of `conversation.draft`, the agent's live reply text
//! (spec/resource-operations-v2.json). Drafts are never stored: this gate
//! only remembers, per (conversation, turn), the last published seq (so a
//! retried event is a replay) and a token bucket of 10 events per second
//! with a burst of 10. Memory only; a daemon restart forgets it, which is
//! safe because a draft is superseded by the posted message anyway.

use std::collections::HashMap;
use std::time::Instant;

/// The largest delta text (`fresh` false).
pub(crate) const MAX_DELTA_BYTES: usize = 16 * 1024;
/// The largest whole-segment text (`fresh` true).
pub(crate) const MAX_FRESH_BYTES: usize = 64 * 1024;
const RATE_PER_SECOND: f64 = 10.0;
const BURST: f64 = 10.0;
/// Turns remembered at once; the least recently used goes first.
const MAX_TURNS: usize = 256;

/// Why a draft event was refused (`details.reason`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DraftRefusal {
    RateLimited,
    TextTooLarge,
}

impl DraftRefusal {
    pub(crate) const fn reason(self) -> &'static str {
        match self {
            Self::RateLimited => "rate_limited",
            Self::TextTooLarge => "text_too_large",
        }
    }
}

#[derive(Debug)]
struct TurnGate {
    last_seq: u64,
    tokens: f64,
    refilled: Instant,
}

#[derive(Debug, Default)]
pub(crate) struct DraftGate {
    turns: HashMap<(String, String), TurnGate>,
}

impl DraftGate {
    /// Whether the draft event `seq` of `turn` is published: `Ok(false)` is a
    /// replay (its seq was already published).
    pub(crate) fn admit(
        &mut self,
        conversation: &str,
        turn: &str,
        seq: u64,
        fresh: bool,
        text_bytes: usize,
        now: Instant,
    ) -> Result<bool, DraftRefusal> {
        let limit = if fresh { MAX_FRESH_BYTES } else { MAX_DELTA_BYTES };
        if text_bytes > limit {
            return Err(DraftRefusal::TextTooLarge);
        }
        let key = (conversation.to_owned(), turn.to_owned());
        if !self.turns.contains_key(&key) && self.turns.len() >= MAX_TURNS {
            self.evict_oldest();
        }
        let gate =
            self.turns.entry(key).or_insert(TurnGate { last_seq: 0, tokens: BURST, refilled: now });
        if seq <= gate.last_seq {
            return Ok(false);
        }
        let elapsed = now.saturating_duration_since(gate.refilled);
        gate.tokens = (gate.tokens + elapsed.as_secs_f64() * RATE_PER_SECOND).min(BURST);
        gate.refilled = now;
        if gate.tokens < 1.0 {
            return Err(DraftRefusal::RateLimited);
        }
        gate.tokens -= 1.0;
        gate.last_seq = seq;
        Ok(true)
    }

    fn evict_oldest(&mut self) {
        if let Some(oldest) =
            self.turns.iter().min_by_key(|(_, gate)| gate.refilled).map(|(key, _)| key.clone())
        {
            self.turns.remove(&oldest);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    /// One second, for tests that step the clock.
    const SECOND: Duration = Duration::from_secs(1);

    #[test]
    fn a_seq_at_or_below_the_last_published_one_is_a_replay() {
        let mut gate = DraftGate::default();
        let now = Instant::now();
        assert_eq!(gate.admit("c", "t", 1, true, 3, now), Ok(true));
        assert_eq!(gate.admit("c", "t", 1, true, 3, now), Ok(false));
        assert_eq!(gate.admit("c", "t", 2, false, 3, now), Ok(true));
        assert_eq!(gate.admit("c", "t", 2, false, 3, now), Ok(false));
        assert_eq!(gate.admit("c", "other", 1, true, 3, now), Ok(true), "turns are separate");
    }

    #[test]
    fn ten_per_second_with_a_burst_of_ten() {
        let mut gate = DraftGate::default();
        let now = Instant::now();
        for seq in 1..=10 {
            assert_eq!(gate.admit("c", "t", seq, false, 1, now), Ok(true));
        }
        assert_eq!(gate.admit("c", "t", 11, false, 1, now), Err(DraftRefusal::RateLimited));
        // A refused event is not published, so its seq may be sent again.
        let later = now + SECOND / 10;
        assert_eq!(gate.admit("c", "t", 11, false, 1, later), Ok(true));
        assert_eq!(gate.admit("c", "t", 12, false, 1, later), Err(DraftRefusal::RateLimited));
        let much_later = now + SECOND * 5;
        for seq in 12..=21 {
            assert_eq!(gate.admit("c", "t", seq, false, 1, much_later), Ok(true));
        }
        assert_eq!(gate.admit("c", "t", 22, false, 1, much_later), Err(DraftRefusal::RateLimited));
    }

    #[test]
    fn deltas_above_16_kib_and_fresh_text_above_64_kib_are_refused() {
        let mut gate = DraftGate::default();
        let now = Instant::now();
        assert_eq!(gate.admit("c", "t", 1, false, MAX_DELTA_BYTES, now), Ok(true));
        assert_eq!(
            gate.admit("c", "t", 2, false, MAX_DELTA_BYTES + 1, now),
            Err(DraftRefusal::TextTooLarge)
        );
        assert_eq!(gate.admit("c", "t", 2, true, MAX_FRESH_BYTES, now), Ok(true));
        assert_eq!(
            gate.admit("c", "t", 3, true, MAX_FRESH_BYTES + 1, now),
            Err(DraftRefusal::TextTooLarge)
        );
    }

    #[test]
    fn the_gate_remembers_a_bounded_number_of_turns() {
        let mut gate = DraftGate::default();
        let start = Instant::now();
        for turn in 0..(MAX_TURNS + 10) {
            let at = start + Duration::from_millis(turn as u64);
            assert_eq!(gate.admit("c", &turn.to_string(), 1, true, 1, at), Ok(true));
        }
        assert_eq!(gate.turns.len(), MAX_TURNS);
        assert!(!gate.turns.contains_key(&("c".to_owned(), "0".to_owned())));
    }
}

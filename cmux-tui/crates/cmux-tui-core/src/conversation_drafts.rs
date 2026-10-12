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

/// One draft event to admit.
pub(crate) struct DraftAdmission<'a> {
    pub conversation: &'a str,
    pub participant: &'a str,
    pub turn: &'a str,
    pub seq: u64,
    pub fresh: bool,
    pub text_bytes: usize,
}

#[derive(Debug)]
struct TurnGate {
    last_seq: u64,
    tokens: f64,
    refilled: Instant,
}

#[derive(Debug, Default)]
pub(crate) struct DraftGate {
    /// Keyed by (conversation, participant, turn): a turn's seqs and rate
    /// belong to the agent that publishes it.
    turns: HashMap<(String, String, String), TurnGate>,
}

impl DraftGate {
    /// Whether the draft event `seq` of `turn` is published: `Ok(false)` is a
    /// replay (its seq was already published).
    pub(crate) fn admit(
        &mut self,
        draft: DraftAdmission<'_>,
        now: Instant,
    ) -> Result<bool, DraftRefusal> {
        let DraftAdmission { conversation, participant, turn, seq, fresh, text_bytes } = draft;
        let limit = if fresh { MAX_FRESH_BYTES } else { MAX_DELTA_BYTES };
        if text_bytes > limit {
            return Err(DraftRefusal::TextTooLarge);
        }
        let key = (conversation.to_owned(), participant.to_owned(), turn.to_owned());
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

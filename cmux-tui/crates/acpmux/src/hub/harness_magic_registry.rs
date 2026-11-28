//! A child of `harness_magic.rs`. Where a harness-magic feature registers itself: its row in
//! [`FEATURES`] (the gate the `harnessMagic.enabled` stamp asks, `harness_magic.rs`) and, when it
//! writes onto a settled turn's `turn_result`, its row in [`TURN_END`] (`turn_git.rs` runs them).
//!
//! Every row is one line and stands alone, and `.gitattributes` gives this file
//! `merge=cmux-insertions-v1` (`scripts/merge-insertions.py`), so two PRs that each add a feature
//! merge with both rows kept and no hand resolution; the FEATURES table and the turn-end calls
//! conflicted on most RFD 0158 PRs. A row both sides changed stays a conflict. Two sides adding a
//! row of the same name merge with both kept, and the `each_*_row_is_unique` tests turn that red.
//! Keep a row on one line, so one insertion is one whole row.

use super::{Feature, enabled};
use crate::claude_stdio as stdio;
use crate::hub as h;
use crate::hub::{Hub, Session};
use serde_json::Value;

/// The features this build carries, in the order `harnessMagic.enabled` lists them. A builder
/// adds its feature here with its gate; an empty list stamps `enabled: []` and reads no settings.
#[rustfmt::skip]
pub(crate) const FEATURES: &[Feature] = &[
    Feature { name: h::turn_rules::FEATURE, on: || enabled(h::turn_rules::FEATURE) },
    Feature { name: h::fresh_review::FEATURE, on: h::fresh_review::enabled },
    Feature { name: h::cache_alarm::FEATURE, on: || enabled(h::cache_alarm::FEATURE) },
    Feature { name: crate::spec_exec::FEATURE, on: crate::spec_exec::enabled },
    Feature { name: stdio::PATH_RULES_FEATURE, on: stdio::path_rules_enabled },
    Feature { name: "verify", on: h::verify::enabled },
    Feature { name: crate::model_router::FEATURE, on: crate::model_router::enabled },
    Feature { name: "prefetch", on: h::prefetch::enabled },
    Feature { name: h::plan_first::FEATURE, on: h::plan_first::enabled },
    Feature { name: "surgery", on: h::surgery::enabled },
    Feature { name: h::best_of_n::FEATURE, on: h::best_of_n::enabled },
    Feature { name: "dedupe", on: stdio::dedupe_enabled },
    Feature { name: crate::cited_memory::FEATURE, on: crate::cited_memory::enabled },
    Feature { name: h::sidecars::FEATURE, on: || enabled(h::sidecars::FEATURE) },
    Feature { name: "dirRules", on: stdio::dir_rules_enabled },
    Feature { name: h::idle_digest::FEATURE, on: h::idle_digest::enabled },
    Feature { name: h::turn_checkpoint::FEATURE, on: h::turn_checkpoint::enabled },
    Feature { name: "sharedCache", on: crate::ci_log_cache::enabled },
    Feature { name: "outputCaps", on: crate::harness_limits::output_caps },
    Feature { name: h::approval_review::FEATURE, on: h::approval_review::enabled },
    Feature { name: h::turn_artifacts::FEATURE, on: h::turn_artifacts::enabled },
    Feature { name: "consensus", on: h::surge_triage::consensus_enabled },
    Feature { name: "continue", on: h::stop_condition::continue_enabled },
];

/// One step a settled turn's `turn_result` goes through before it is written: a feature's
/// counters or verdict onto it. `name` only tells rows apart (the uniqueness test).
pub(in crate::hub) struct TurnEnd {
    pub name: &'static str,
    pub run: fn(&Hub, &Session, &mut Value),
}

/// The turn-end steps, run in this order by `Hub::write_turn_result` after the git fields, the
/// prefetch counters, `unread` and `pendingPermissions` are on the message.
#[rustfmt::skip]
pub(in crate::hub) const TURN_END: &[TurnEnd] = &[
    TurnEnd { name: "verify", run: |_, s, msg| map(msg, |o| h::verify::stamp(&s.id, o)) },
    TurnEnd { name: "speculative", run: |_, s, m| map(m, |o| h::speculative::stamp(&s.id, o)) },
    TurnEnd { name: "sidecars.stamp", run: |_, s, msg| h::sidecars::stamp(&s.id, msg) },
    TurnEnd { name: "harnessMagic.enabled", run: |_, _, msg| super::stamp(msg) },
    TurnEnd { name: "checkpoints", run: |_, _, msg| h::turn_checkpoint::count(msg) },
    TurnEnd { name: "cacheAlarm", run: |hub, s, msg| hub.cache_alarm(s, msg) },
    TurnEnd { name: "turnRules", run: |hub, s, msg| hub.turn_rules_end(s, msg) },
    TurnEnd { name: "planFirst", run: |hub, s, msg| hub.plan_first_end(s, msg) },
    TurnEnd { name: "sidecars.end", run: |hub, s, msg| hub.sidecars_end(s, msg) },
    TurnEnd { name: "bestOfN", run: |_, s, msg| h::best_of_n::stamp(&s.id, msg) },
    TurnEnd { name: "artifactCard", run: |_, s, msg| h::turn_artifacts::stamp(&s.id, msg) },
];

/// Runs `f` on the message's object, for the steps that write flat keys; a message that is not
/// an object is left alone.
fn map(msg: &mut Value, f: impl FnOnce(&mut serde_json::Map<String, Value>)) {
    if let Some(o) = msg.as_object_mut() {
        f(o);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn each_feature_row_is_unique() {
        let mut seen = HashSet::new();
        let doubled: Vec<&str> =
            FEATURES.iter().map(|f| f.name).filter(|n| !seen.insert(*n)).collect();
        assert!(doubled.is_empty(), "FEATURES rows kept twice (merged in twice?): {doubled:?}");
    }

    #[test]
    fn each_turn_end_row_is_unique() {
        let mut seen = HashSet::new();
        let doubled: Vec<&str> =
            TURN_END.iter().map(|t| t.name).filter(|n| !seen.insert(*n)).collect();
        assert!(doubled.is_empty(), "TURN_END rows kept twice (merged in twice?): {doubled:?}");
    }
}

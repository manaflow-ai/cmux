//! The remote origins the index refuses past its bound (`acpmux_core::hub::MAX_ORIGINS`), and
//! the daemon log's sign of them (decision 261). The hub takes a submit into its queue and its
//! writer refuses the origin later, so the `Ok` the tee gets says nothing: the tee tells a refusal
//! itself, from the index it reads, before it submits.
use acpmux_core::hub::{Hub, MAX_ORIGINS};
use std::collections::BTreeSet;

#[derive(Default)]
pub(super) struct Refused {
    /// The origins seen refused and not admitted since, at most `MAX_ORIGINS`.
    ids: BTreeSet<String>,
    /// More origins were refused than `ids` keeps.
    overflow: bool,
    /// Every refused submit this tee made, the count each warn names.
    submits: u64,
    /// Warn lines written, for the tests of their bound.
    #[cfg(test)]
    pub(super) warns: u64,
}

impl Refused {
    /// Notes a submit for `origin`, which the hub has no source for: refused when the index
    /// already holds `MAX_ORIGINS` origins and none is `origin`. An origin the writer counts
    /// toward the bound but has not yet given a record (`admit_origin`'s source and retry maps)
    /// is not seen here; then the refusal goes untold until the index fills.
    pub(super) fn note(&mut self, hub: &Hub, origin: &str) {
        let index = hub.snapshot();
        if index.origin(origin).is_some() || index.origins().count() < MAX_ORIGINS {
            return;
        }
        self.submits += 1;
        let new = !self.ids.contains(origin) && self.ids.len() < MAX_ORIGINS;
        if new {
            self.ids.insert(origin.to_owned());
        } else if !self.ids.contains(origin) {
            self.overflow = true;
        }
        // A line for each origin newly refused, and else at each doubling of the count: the
        // lines follow the number of origins and the log of the submits, not the submits.
        if new || self.submits.is_power_of_two() {
            #[cfg(test)]
            {
                self.warns += 1;
            }
            tracing::warn!(
                origin,
                refused_submits = self.submits,
                refused_origins = self.ids.len(),
                more = self.overflow,
                limit = MAX_ORIGINS,
                "v2 list: the index holds its most origins; this machine's chats are not in the \
                 v2 list until a slot frees"
            );
        }
    }

    /// `origin` has a source in the hub now: it got in.
    pub(super) fn admitted(&mut self, origin: &str) {
        self.ids.remove(origin);
    }

    pub(super) fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

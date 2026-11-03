//! The daemon's long jobs on the socket (`long_jobs` capability):
//! `jobs-list` reads them, `subscribe` pushes `jobs-changed` with the same
//! payload whenever they change (at most four times per second,
//! `crate::long_jobs`).

use std::sync::Arc;

use serde_json::{Value, json};

use crate::long_jobs::{JobsSubscription, LongJob, LongJobs};
use crate::{Mux, MuxEvent};

/// `jobs-list`: `{"jobs":[...]}`.
pub(super) fn jobs_list() -> Value {
    json!({ "jobs": LongJobs::snapshot() })
}

/// The `jobs-changed` event: `{"event":"jobs-changed","jobs":[...]}`.
pub(super) fn jobs_changed_json(jobs: &[LongJob]) -> Value {
    json!({ "event": "jobs-changed", "jobs": jobs })
}

/// Sends every change of the process's long jobs to `mux`'s subscribers as
/// `jobs-changed`, until the returned subscription drops.
pub fn forward_long_jobs(mux: &Arc<Mux>) -> JobsSubscription {
    let mux = Arc::downgrade(mux);
    LongJobs::subscribe(Arc::new(move |jobs: &[LongJob]| {
        if let Some(mux) = mux.upgrade() {
            mux.emit(MuxEvent::JobsChanged(jobs.to_vec()));
        }
    }))
}

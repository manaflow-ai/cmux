//! Placeholder until `scripts/cmux-next/gen-features.py` (task
//! p12-perf-process-090) exists: no daemon feature is registered yet.
//!
//! The generator replaces this file with the `daemon` and `both` features of
//! `schemas/features/features.d`, in registry order, and defines only:
//!
//! - `pub(crate) const TABLE: &[crate::FeatureDef]`, one entry per feature;
//! - in `pub mod feature`, one `feature_handles!(super::TABLE; NAME = "name", ...)`
//!   with a handle per entry.
//!
//! `feature_handles!` fails the build on a name `TABLE` lacks, and `lib.rs`
//! fails it on a duplicate name, so a handle can never point at the wrong entry.

/// One handle per daemon feature, for `Snapshot::is_enabled`.
pub mod feature {}

pub(crate) const TABLE: &[crate::FeatureDef] = &[];

//! Words the public CLI recognizes only to send people away from them.
//!
//! Code here matches legacy input and never prints it as cmux vocabulary, so
//! it sits under `internal/`, outside the resource-v2 public boundary scan
//! (`cmux-tui/scripts/check-resource-api-boundary.py`).

pub(super) mod classic_verbs;

//! `cmux search` code that speaks the daemon's legacy control protocol. It reads private wire
//! keys and never prints them, so it sits under `internal/`, outside the resource-v2 public
//! boundary scan (`cmux-tui/scripts/check-resource-api-boundary.py`).

pub(super) mod legacy_sidebar;

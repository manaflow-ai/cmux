//! The Windows system layer of per-terminal hosts (bead cx-ko2e,
//! plans/cmux-next/windows-terminal-hosts.md). The platform-neutral host
//! logic moves out of `mod unix` first (crate-split lane; the item list is
//! cmuxterm-hq .cmux-scratch/cx-ko2e-split-items.md); these modules are the
//! Windows side of its seams: `liveness` (Lease: LockFileEx for flock),
//! `endpoint` (EndpointPolicy: the per-user socket path), `jobs` (the named,
//! owner-only Job Object a restarted daemon checks before it reads a
//! terminal's processes), `standby` (the host process spawn: breakaway,
//! no inherited handle, no window). It sits under `sys` (the seams module):
//! its items replace the `windows_stubs` in `sys.rs` one by one.

pub mod endpoint;
pub mod jobs;
pub mod liveness;
pub mod standby;

//! The NEXT Cloud start's decisions, in Rust so the macOS app keeps only the
//! calls (Leo, 2026-11-02: Cloud logic and its tests belong in Rust, not
//! Swift). Pure: no I/O; the app reads the machine and the account, asks
//! here what to do, and does it. Served to the app over the app FFI's JSON
//! channel (`cmux-layout-reducer-ffi`, op `cloud_harness_login*`).

pub mod harness_login;

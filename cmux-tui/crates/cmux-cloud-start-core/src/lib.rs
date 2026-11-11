//! The NEXT Cloud start's decisions, in Rust so the macOS app keeps only the
//! calls (Leo, 2026-11-02: Cloud logic and its tests belong in Rust, not
//! Swift). Pure: no I/O; the app reads the machine and the account, asks
//! here what to do, and does it. Served to the app over the app FFI's JSON
//! channel (`cmux-layout-reducer-ffi`, ops `cloud_*`).

pub mod ask;
pub mod capability;
pub mod harness_login;
pub mod machine_bootstrap;
pub mod machine_config;
pub mod machine_create;
pub mod machine_login;
pub mod machine_repo;
pub mod moves;
pub mod sequence;
pub mod start;
pub mod vm_kind;

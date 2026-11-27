//! The NEXT Cloud start's decisions, in Rust so the macOS app keeps only the
//! calls (Leo, 2026-11-02: Cloud logic and its tests belong in Rust, not
//! Swift). Pure: no I/O; the app reads the machine and the account, asks
//! here what to do, and does it. Served to the app over the app FFI's JSON
//! channel (`cmux-layout-reducer-ffi`, ops `cloud_*`).

pub mod agent_check;
pub mod app_state;
pub mod approval_answer;
pub mod ask;
pub mod autosize_row;
pub mod balance;
pub mod capability;
pub mod computer_status;
pub mod create_flow;
pub mod grow_disk;
pub mod hybrid;
pub mod hybrid_gui;
pub mod hybrid_show;
pub mod hybrid_tools;
pub mod keep_count;
pub mod list_wait;
pub mod machine_bootstrap;
pub mod machine_config;
pub mod machine_create;
pub mod machine_repo;
pub mod machine_route;
pub mod moves;
pub mod one_pane;
pub mod sequence;
pub mod spare_shapes;
pub mod start;
pub mod start_session;
pub mod vm_kind;

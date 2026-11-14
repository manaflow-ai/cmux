//! NEXT Cloud's configuration rules, in Rust so the macOS app keeps only the
//! platform calls (Leo, 2026-11-04, on whether this belongs in Swift: "Yes,
//! start it"). Pure: no I/O. The app reads its bundle, its environment and the
//! Keychain, asks here, and acts on the answer; the `cmux vm` CLI links the
//! same rules in process. Served to the app over the app FFI's JSON channel
//! (`cmux-layout-reducer-ffi`, ops `cloud_config_*`, `cloud_auth_*`,
//! `cloud_identity_*`, `cloud_vm_agent_key_*`).
//!
//! - [`config`]: which Cloud a build talks to, from the runtime selection (the
//!   backend, the callback scheme, the token store's names, the sign-in URL,
//!   the VM API).
//! - [`auth`]: the rules around the stored session that are not Keychain I/O:
//!   how a launch signs in, the debug auto sign-in's account pick, the launch
//!   keys auth keeps, the active team's checks, where sign-in opens, the seat
//!   facts and invite answers.
//! - [`identity`]: the install identity's rules that are not key calls: the
//!   `cmux auth token` mint's team, token claims, transient refusals, install
//!   key names, share install origins.
//! - [`agent_key`]: `vm.agent_key.create` and `cmux vm token create`: the
//!   request a VM agent key is minted with and how the VM API's answer reads.

pub mod agent_key;
pub mod auth;
pub mod config;
pub mod identity;
pub mod origin;

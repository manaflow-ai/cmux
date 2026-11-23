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
//! - [`device_identity_slots`]: which login Keychain items hold the device
//!   hub identity, and where a renewal puts the new one when another build's
//!   items stay.
//! - [`device_list`]: which device hub records are one physical device, and
//!   which are this device's other builds (Screen Sharing's Your Devices).
//! - [`screen_picker`]: Screen Sharing's machine picker (the new tab menu's Screen Sharing ▸):
//!   which machines it lists, in what order, and why one cannot be viewed.
//! - [`identity`]: the install identity's rules that are not key calls: the
//!   `cmux auth token` mint's team, token claims, transient refusals, install
//!   key names, share install origins.
//! - [`install_key_slots`]: which login Keychain item holds an install key, and
//!   where a rotation puts the fresh key when another build's item stays.
//! - [`keychain`]: the deadline of the app's calls into its own Keychain items,
//!   and the refusal, naming the item, of a call that misses it (the app FFI's
//!   gate runs the call on its own thread).
//! - [`signin`]: the install token's owner: renew at 2/3 of its life beside the held token, wait on a mint
//!   at most its bound, and name the step of a mint that stalls (remote-cloud-durability F13).
//! - [`agent_key`]: `vm.agent_key.create` and `cmux vm token create`: the
//!   request a VM agent key is minted with and how the VM API's answer reads.

pub mod agent_key;
pub mod auth;
pub mod capture_auth;
pub mod config;
pub mod device_identity_slots;
pub mod device_list;
pub mod identity;
pub mod install_key_slots;
pub mod keychain;
pub mod origin;
pub mod screen_picker;
pub mod signin;

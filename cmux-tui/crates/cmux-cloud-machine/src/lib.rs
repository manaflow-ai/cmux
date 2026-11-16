//! NEXT Cloud's machine record as the macOS app shows it, and the rules around it, in Rust so
//! the app keeps only fields and calls (Leo, 2026-11-02: Cloud logic and its tests belong in
//! Rust, not Swift). Pure: no I/O. The app hands a server's answer or its own record here, asks
//! what it means or what to do, and acts on the answer. Served over the app FFI's JSON channel
//! (`cmux-layout-reducer-ffi`, ops `cloud_machine_*` and `cloud_model_*`).
//!
//! The record ([`record::Machine`]) is read from either server shape: the cmux-next backend's
//! `CloudMachine` (contract 1.2, cmux-cloud-wire's generated `CloudMachine`, as the Cloud app
//! server answers it; [`record::from_next`]) and the classic `/api/vm` record
//! ([`record::from_classic`]). Both become one camelCase JSON object, timestamps in epoch
//! milliseconds, which the app decodes with no rules of its own.

pub mod cap;
pub mod changes;
pub mod error;
pub mod github;
pub mod harness_copy;
mod json;
pub mod limits;
pub mod list_facts;
pub mod models;
pub mod preview;
pub mod push;
pub mod record;
pub mod refusals;
pub mod rules;
pub mod vm_host;

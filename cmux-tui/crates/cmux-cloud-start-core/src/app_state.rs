//! The app's own Cloud state machines, which `CmuxNextApp/Cloud` once kept in Swift: a New Cloud
//! Workspace's creation from the click to its open terminal (`CloudMachineCreation`,
//! `CloudCreations`, `CloudCreationFlow`, the signed-out creation's sign-in continuation), the Mac
//! tabs that show a Cloud chat in place (`CloudFrontedChats`), and a moved chat's access asks and
//! revokes (`CloudAccessAsks`, `CloudAccessRevokes`). Pure: the app keeps its tasks, its waits and
//! its views, holds each state as this module's JSON, and asks here how an event changes it and what
//! to do next. Times are milliseconds on the app's own monotonic clock. Served over the app FFI's
//! JSON channel as ops `cloud_state_*` (`cmux-layout-reducer-ffi/src/cloud_state.rs`).

pub mod access;
pub mod creation;
pub mod flow;
pub mod fronted;

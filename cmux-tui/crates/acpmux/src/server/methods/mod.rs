//! Request methods registered by file. Each `<name>.rs` in this folder is one method: a
//! `pub(super) const METHOD: &str` and a `pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn,
//! params: &Value) -> Result<Value, RpcError>` (a `<name>_tests.rs` is its tests, which `<name>.rs`
//! declares). The build script (`build.rs`, `methods_dispatch`) declares every method file as a
//! module and writes [`dispatch`], so a lane adds a method by adding its file and edits neither
//! this file nor `requests.rs`'s `match`.
//!
//! `requests.rs` asks [`dispatch`] in its last arm, after every method its `match` names and
//! before it forwards an unknown method to the session's harness.

use super::Conn;
use crate::hub::Hub;
use crate::rpc::RpcError;
use serde_json::Value;
use std::sync::Arc;

include!(concat!(env!("OUT_DIR"), "/server_methods.rs"));

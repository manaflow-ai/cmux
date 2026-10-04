//! `cmux server pair` (server.md 6.2). Red stub: the API surface only.

pub mod identity;

use std::path::PathBuf;
use std::time::Duration;

use cmux_server_core::layout::Layout;
use serde::Serialize;

use crate::error::{Error, Result};
use crate::fsx;

pub use identity::InstallIdentity;

pub const PAIRING_DIR: &str = "pairing";
pub const PENDING_FILE: &str = "pending.json";
pub const CREDENTIALS_FILE: &str = "credentials.json";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct HostInfo {
    pub name: String,
    pub platform: String,
    pub os_version: String,
    pub arch: String,
    pub cmux_version: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiTarget {
    pub base: String,
    pub environment: String,
    pub allow_http: bool,
}

impl ApiTarget {
    pub fn production() -> ApiTarget {
        ApiTarget { base: String::new(), environment: String::new(), allow_http: false }
    }

    pub fn url(&self, _path: &str) -> Result<String> {
        Err(Error::internal("not implemented"))
    }

    pub fn ws_url(&self, _path: &str) -> Result<String> {
        Err(Error::internal("not implemented"))
    }
}

pub fn pairing_dir(layout: &Layout) -> PathBuf {
    fsx::local(&layout.state).join(PAIRING_DIR)
}

pub struct PairRequest<'a> {
    pub layout: &'a Layout,
    pub api: &'a ApiTarget,
    pub info: HostInfo,
    pub wait: bool,
    pub timeout: Option<Duration>,
    pub now_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Started {
    pub code: String,
    pub expires_at: u64,
    pub words: [String; 4],
    pub qr_payload: String,
    pub resumed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paired {
    pub host: String,
    pub team: String,
}

#[derive(Debug)]
pub enum PairOutcome {
    Pending(Started),
    Paired(Paired),
    AlreadyPaired(Paired),
}

pub fn run(_req: &PairRequest<'_>, _on_started: &mut dyn FnMut(&Started)) -> Result<PairOutcome> {
    Err(Error::internal("not implemented"))
}

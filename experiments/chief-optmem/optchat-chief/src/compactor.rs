//! The compactor's model through acpmux (stub; see the next commit).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use optchat_host::{CompactModel, CompactRequest, Config, Followup, ModelError, Reply};
use serde_json::Value;

use crate::acpmux::AgentPort;

/// The permission policy of every compactor session.
pub const POLICY: &str = "deny-all";

/// How compactor sessions start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompactorSpec {
    pub name: String,
    pub cwd: PathBuf,
    pub harness: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub timeout: Duration,
    pub jobs: usize,
}

pub struct AcpmuxCompactor {
    _port: Arc<dyn AgentPort>,
    _spec: CompactorSpec,
}

impl AcpmuxCompactor {
    pub fn new(port: Arc<dyn AgentPort>, spec: CompactorSpec) -> AcpmuxCompactor {
        AcpmuxCompactor {
            _port: port,
            _spec: spec,
        }
    }
}

impl CompactModel for AcpmuxCompactor {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Err(ModelError::new("not implemented"))
    }
}

pub fn request_blocks(_request: &CompactRequest) -> Vec<Value> {
    Vec::new()
}

/// Which model builds the compactor's nodes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompactRoute {
    Acpmux,
    Api,
}

pub fn compact_route(_choice: Option<&str>, _config: &Config) -> Result<CompactRoute, String> {
    Ok(CompactRoute::Api)
}

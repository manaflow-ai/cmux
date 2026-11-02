//! The session topology in the app control socket's `snapshot.get` shape
//! (`control-topology-v1`). Red step: the commands exist and answer nothing
//! yet; the next commit maps the tree (control_topology_tests.rs).
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;
use serde_json::json;

use crate::Mux;

pub(crate) const MAX_VIEW_BYTES: usize = 1 << 20;
pub(crate) const MAX_VIEW_STRING_BYTES: usize = 4096;

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub(crate) struct ControlView {
    #[serde(default)]
    pub(crate) panes: BTreeMap<String, Value>,
    #[serde(default)]
    pub(crate) page_titles: BTreeMap<String, String>,
}

impl ControlView {
    pub(crate) fn parse(value: Value) -> anyhow::Result<Self> {
        Ok(serde_json::from_value(value).unwrap_or_default())
    }
}

#[derive(Debug, Default)]
pub(crate) struct DaemonFacts {
    pub(crate) tree: Value,
    pub(crate) personal_groups: Option<Vec<Value>>,
    pub(crate) agents: HashMap<u64, (String, Option<String>)>,
    pub(crate) marked_tabs: std::collections::HashSet<String>,
}

pub(super) fn set_view(_mux: &Arc<Mux>, _client: u64, _view: Value) -> anyhow::Result<Value> {
    Ok(json!({}))
}

pub(super) fn topology(_mux: &Arc<Mux>, _client: u64) -> anyhow::Result<Value> {
    Ok(json!({}))
}

pub(crate) fn valid_attention(_value: &Value) -> bool {
    false
}

pub(crate) fn topology_json(_facts: &DaemonFacts, _view: &ControlView) -> Value {
    json!({})
}

pub(crate) fn terminal_title_text(raw: &str) -> String {
    raw.to_string()
}

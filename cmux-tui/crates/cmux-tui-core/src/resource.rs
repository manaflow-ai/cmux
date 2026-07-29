//! Opaque public resource identities and protocol-v1 shared types.

use std::collections::{HashMap, VecDeque};
use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const PROTOCOL: &str = "cmux.protocol/1";
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
pub const STREAM_EVENT_CAPACITY: usize = 256;
pub const STREAM_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
pub const JOURNAL_CAPACITY: usize = 4096;

macro_rules! public_id {
    ($name:ident, $prefix:literal) => {
        #[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub const PREFIX: &'static str = $prefix;

            pub fn random() -> anyhow::Result<Self> {
                let mut bytes = [0u8; 16];
                getrandom::fill(&mut bytes)
                    .map_err(|_| anyhow::anyhow!("could not allocate {} identity", $prefix))?;
                Ok(Self(format!("{}_{}", $prefix, encode_hex(bytes))))
            }

            pub fn parse(value: impl Into<String>) -> Result<Self, ResourceError> {
                let value = value.into();
                let payload = value
                    .strip_prefix(concat!($prefix, "_"))
                    .ok_or_else(|| ResourceError::invalid_id(stringify!($name), &value))?;
                if payload.len() != 32
                    || !payload
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                {
                    return Err(ResourceError::invalid_id(stringify!($name), &value));
                }
                Ok(Self(value))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.debug_tuple(stringify!($name)).field(&self.0).finish()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: serde::Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                Self::parse(value).map_err(serde::de::Error::custom)
            }
        }
    };
}

public_id!(MachinePublicId, "machine");
public_id!(SessionPublicId, "session");
public_id!(WorkspacePublicId, "ws");
public_id!(ScreenPublicId, "screen");
public_id!(PanePublicId, "pane");
public_id!(TabPublicId, "tab");
public_id!(TerminalPublicId, "term");
public_id!(BrowserPublicId, "browser");
public_id!(ClientPublicId, "client");
public_id!(SplitPublicId, "split");
public_id!(StreamPublicId, "stream");
public_id!(NotificationPublicId, "notification");
public_id!(AgentPublicId, "agent");
public_id!(ProjectionPublicId, "projection");
public_id!(PairingRequestPublicId, "pairing");
public_id!(SidebarViewPublicId, "sidebar_view");
public_id!(SidebarPluginPublicId, "sidebar_plugin");

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "lowercase")]
pub enum ContentPublicId {
    Terminal(TerminalPublicId),
    Browser(BrowserPublicId),
}

impl ContentPublicId {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Terminal(id) => id.as_str(),
            Self::Browser(id) => id.as_str(),
        }
    }
}

fn encode_hex(bytes: [u8; 16]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(32);
    for byte in bytes {
        output.push(char::from(HEX[(byte >> 4) as usize]));
        output.push(char::from(HEX[(byte & 0x0f) as usize]));
    }
    output
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceError {
    pub code: String,
    pub message: String,
    pub details: Value,
    pub retryable: bool,
}

impl ResourceError {
    pub fn new(
        code: impl Into<String>,
        message: impl Into<String>,
        details: Value,
        retryable: bool,
    ) -> Self {
        Self { code: code.into(), message: message.into(), details, retryable }
    }

    fn invalid_id(kind: &str, value: &str) -> Self {
        Self::new(
            "selector.invalid",
            format!("invalid {kind} {value:?}"),
            json!({"kind":kind,"selector":value}),
            false,
        )
    }

    pub fn not_found(kind: &str, selector: &str) -> Self {
        Self::new(
            "selector.not_found",
            format!("no {kind} matches {selector:?}"),
            json!({"kind":kind,"selector":selector}),
            false,
        )
    }

    pub fn ambiguous(kind: &str, selector: &str, candidates: Vec<String>) -> Self {
        Self::new(
            "selector.ambiguous",
            format!("more than one {kind} is named {selector:?}"),
            json!({"kind":kind,"selector":selector,"candidates":candidates}),
            false,
        )
    }
}

impl fmt::Display for ResourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ResourceError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selector {
    Current,
    Id(String),
    Name(String),
}

impl Selector {
    pub fn parse(value: &str) -> Self {
        if let Some(name) = value.strip_prefix("name:") {
            return Self::Name(name.to_string());
        }
        if value == "current" {
            return Self::Current;
        }
        if is_registered_public_id(value) {
            return Self::Id(value.to_string());
        }
        Self::Name(value.to_string())
    }
}

fn is_registered_public_id(value: &str) -> bool {
    let Some((prefix, payload)) = value.rsplit_once('_') else {
        return false;
    };
    matches!(
        prefix,
        "machine"
            | "session"
            | "ws"
            | "screen"
            | "pane"
            | "tab"
            | "term"
            | "browser"
            | "client"
            | "split"
            | "stream"
            | "notification"
            | "agent"
            | "projection"
            | "pairing"
            | "sidebar_view"
            | "sidebar_plugin"
    ) && payload.len() == 32
        && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn resolve_name<T: Clone>(
    kind: &str,
    selector: &str,
    candidates: impl IntoIterator<Item = (String, Option<String>, T)>,
) -> Result<T, ResourceError> {
    let mut matches = candidates
        .into_iter()
        .filter(|(_, name, _)| name.as_deref() == Some(selector))
        .collect::<Vec<_>>();
    match matches.len() {
        0 => Err(ResourceError::not_found(kind, selector)),
        1 => Ok(matches.pop().expect("one match").2),
        _ => Err(ResourceError::ambiguous(
            kind,
            selector,
            matches.into_iter().map(|(id, _, _)| id).collect(),
        )),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceDelta {
    pub revision: u64,
    pub sequence: u32,
    pub event: String,
    pub data: Value,
}

/// Bounded contiguous journal. One commit advances the resource revision
/// exactly once and may append several ordered deltas at that revision.
#[derive(Debug)]
pub struct ResourceJournal {
    generation: String,
    revision: u64,
    deltas: VecDeque<ResourceDelta>,
    capacity: usize,
}

impl ResourceJournal {
    pub fn new(generation: String, revision: u64) -> Self {
        Self { generation, revision, deltas: VecDeque::new(), capacity: JOURNAL_CAPACITY }
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn commit(&mut self, events: Vec<(String, Value)>) -> anyhow::Result<u64> {
        self.revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        for (sequence, (event, data)) in events.into_iter().enumerate() {
            self.deltas.push_back(ResourceDelta {
                revision: self.revision,
                sequence: u32::try_from(sequence)
                    .map_err(|_| anyhow::anyhow!("too many deltas in one resource transaction"))?,
                event,
                data,
            });
        }
        while self.deltas.len() > self.capacity {
            self.deltas.pop_front();
        }
        Ok(self.revision)
    }

    pub fn after(&self, revision: u64) -> Result<Vec<ResourceDelta>, ResourceError> {
        if revision > self.revision {
            return Err(ResourceError::new(
                "stream.cursor_ahead",
                "resume cursor is ahead of the session revision",
                json!({"cursor":revision,"revision":self.revision,"generation":self.generation}),
                false,
            ));
        }
        let oldest = self.deltas.front().map_or(self.revision, |delta| delta.revision);
        if revision.saturating_add(1) < oldest {
            return Err(ResourceError::new(
                "stream.gap",
                "resume cursor is no longer retained",
                json!({
                    "cursor":revision,
                    "oldest_revision":oldest,
                    "revision":self.revision,
                    "generation":self.generation
                }),
                true,
            ));
        }
        Ok(self.deltas.iter().filter(|delta| delta.revision > revision).cloned().collect())
    }
}

#[derive(Debug, Default)]
pub struct PublicSlotIndexes {
    pub workspaces: HashMap<WorkspacePublicId, crate::WorkspaceId>,
    pub screens: HashMap<ScreenPublicId, crate::ScreenId>,
    pub panes: HashMap<PanePublicId, crate::PaneId>,
    pub tabs: HashMap<TabPublicId, crate::SurfaceId>,
    pub content: HashMap<ContentPublicId, crate::SurfaceId>,
    pub workspace_ids: HashMap<crate::WorkspaceId, WorkspacePublicId>,
    pub screen_ids: HashMap<crate::ScreenId, ScreenPublicId>,
    pub pane_ids: HashMap<crate::PaneId, PanePublicId>,
    pub tab_ids: HashMap<crate::SurfaceId, TabPublicId>,
    pub content_ids: HashMap<crate::SurfaceId, ContentPublicId>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_reject_uppercase_wrong_prefix_and_wrong_width() {
        let id = WorkspacePublicId::random().unwrap();
        assert_eq!(WorkspacePublicId::parse(id.to_string()).unwrap(), id);
        assert!(WorkspacePublicId::parse(format!("ws_{}", "A".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("term_{}", "a".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("ws_{}", "a".repeat(31))).is_err());
    }

    #[test]
    fn name_escape_selects_reserved_and_id_shaped_names() {
        assert_eq!(Selector::parse("current"), Selector::Current);
        assert_eq!(Selector::parse("name:current"), Selector::Name("current".into()));
        assert!(matches!(
            Selector::parse(&WorkspacePublicId::random().unwrap().to_string()),
            Selector::Id(_)
        ));
        assert_eq!(
            Selector::parse(&format!("name:ws_{}", "a".repeat(32))),
            Selector::Name(format!("ws_{}", "a".repeat(32)))
        );
        assert_eq!(Selector::parse("hello_world"), Selector::Name("hello_world".into()));
    }

    #[test]
    fn duplicate_names_return_every_candidate_without_selecting() {
        let result = resolve_name(
            "workspace",
            "api",
            [("ws_1".into(), Some("api".into()), 1), ("ws_2".into(), Some("api".into()), 2)],
        )
        .unwrap_err();
        assert_eq!(result.code, "selector.ambiguous");
        assert_eq!(result.details["candidates"], json!(["ws_1", "ws_2"]));
    }

    #[test]
    fn journal_revision_is_per_atomic_commit_and_detects_gaps() {
        let mut journal = ResourceJournal::new("generation".into(), 8);
        assert_eq!(
            journal
                .commit(vec![
                    ("pane.created".into(), json!({"id":"pane"})),
                    ("tab.created".into(), json!({"id":"tab"})),
                ])
                .unwrap(),
            9
        );
        let deltas = journal.after(8).unwrap();
        assert_eq!(deltas.len(), 2);
        assert!(deltas.iter().all(|delta| delta.revision == 9));
        assert_eq!(deltas[0].sequence, 0);
        assert_eq!(deltas[1].sequence, 1);
    }
}

//! One capability manifest for App Store apps: what an app can read and do,
//! per op, typed here once (plans/cmux-next/extensibility-DESIGN.md
//! section 13).
//!
//! Two tables meet here. `cmux-app-host/generated/scopes.json` says which
//! scope each op needs and which ops no app reaches (`never`);
//! `cmux-app-host/schema/v2/scope-classes.json` says how risky each scope is
//! and what the consent sheet says about its class. Before this module the
//! daemon's per-call check (cmux-tui-core `apps/grants.rs`) read the first and
//! the install-time check (`rules.rs`) read the second, and nothing checked
//! one against the other. Now both read [`Capabilities`] and
//! [`scope_info`], and [`cross_check`] is the test that ties them: every op
//! scope resolves to one rule, every rule is used.
//!
//! The daemon serves [`Capabilities::manifest_json`] as `apps-capabilities`
//! (`cmux ext capabilities`), with the typed app global (`cmux-app.d.ts`) and
//! the API version, so a JS extension, the CLI and an SDK read the same table.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};

use crate::scopes::{SCOPE_CLASSES, ScopeClass, ScopeInfo};

/// The op table: scope and class per op, and the ops apps never reach.
pub const SCOPES_JSON: &str = include_str!("../../cmux-app-host/generated/scopes.json");

/// The typed `cmux` global apps code against (`cmux ext new` writes it into
/// a new extension; `cmux ext dev` refreshes it from the daemon).
pub const APP_TYPES: &str = include_str!("../../cmux-app-host/generated/cmux-app.d.ts");

/// The SHA-256 of [`APP_TYPES`], hex: `cmux ext dev` compares it to learn
/// whether the running cmux's typed global differs from the one it wrote.
pub fn types_digest() -> &'static str {
    static DIGEST: OnceLock<String> = OnceLock::new();
    DIGEST.get_or_init(|| hex::encode(Sha256::digest(APP_TYPES.as_bytes())))
}

/// How an op runs (`class` in scopes.json).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpClass {
    Read,
    Mutation,
    /// Host runtime ops whose scope depends on the call (`net.fetch`).
    Runtime,
    /// Opens a stream (`stream_open`).
    Stream,
}

impl OpClass {
    /// An unknown class reads as a mutation: the stricter answer.
    fn parse(raw: Option<&str>) -> Self {
        match raw {
            Some("read") => Self::Read,
            Some("runtime") => Self::Runtime,
            Some("stream_open") => Self::Stream,
            _ => Self::Mutation,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Mutation => "mutation",
            Self::Runtime => "runtime",
            Self::Stream => "stream_open",
        }
    }
}

/// The scope an op needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpScope {
    /// `none`: a local, non-network op every installed app may call
    /// (`toast.show`); no grant to hold.
    Ungated,
    /// One named scope, for example `workspace:read`.
    Named(String),
    /// `net:<host>`: the call's URL host decides; any `net:` grant lists it.
    NetHost,
    /// `integration:<provider>`: the call's provider decides, and a GET may
    /// use `integration:<provider>:read`.
    IntegrationProvider,
}

impl OpScope {
    fn parse(raw: &str) -> Self {
        match raw {
            "none" => Self::Ungated,
            "net:<host>" => Self::NetHost,
            "integration:<provider>" => Self::IntegrationProvider,
            scope => Self::Named(scope.to_string()),
        }
    }

    /// The spelling in scopes.json and on the wire.
    pub fn wire(&self) -> &str {
        match self {
            Self::Ungated => "none",
            Self::Named(scope) => scope,
            Self::NetHost => "net:<host>",
            Self::IntegrationProvider => "integration:<provider>",
        }
    }

    /// Concrete scopes this op scope stands for, to classify it: a template
    /// becomes one example of each scope an app may hold for it.
    pub fn examples(&self) -> Vec<String> {
        match self {
            Self::Ungated => Vec::new(),
            Self::Named(scope) => vec![scope.clone()],
            Self::NetHost => vec!["net:example.com".to_string()],
            Self::IntegrationProvider => {
                vec!["integration:github".to_string(), "integration:github:read".to_string()]
            }
        }
    }

    /// Whether the op reaches the network or another service: a sandboxed
    /// app is refused it.
    pub fn external(&self) -> bool {
        match self {
            Self::Ungated => false,
            Self::NetHost | Self::IntegrationProvider => true,
            Self::Named(scope) => {
                scope.starts_with("net:")
                    || scope.starts_with("integration:")
                    || scope.ends_with(":external")
            }
        }
    }
}

/// A stronger scope an op needs for some of its params.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Escalation {
    /// The scope the call needs instead.
    pub scope: &'static str,
    /// Any of these params present escalates.
    pub when_params: &'static [&'static str],
}

/// A workspace, screen, pane or terminal tab created with a command runs it,
/// as `workspace.run` does: it needs `workspace:execute`.
const LAUNCH_OPS: &[&str] =
    &["workspace.create", "screen.create", "pane.create", "pane.split", "tab.create_terminal"];
const LAUNCH: Escalation =
    Escalation { scope: "workspace:execute", when_params: &["argv", "shell"] };

/// Catalog ops that change view state (focus, selection, scroll, zoom,
/// navigation; js/ABI.md "One rule for use"). From an app they run only with
/// a live gesture token, which they spend, so automation never moves what the
/// user sees (OWNERSHIP-PRINCIPLES). `action.run` is decided in the daemon's
/// `actions.rs`.
pub const VIEW_STATE_OPS: &[&str] = &[
    "browser.activate",
    "browser.navigate",
    "pane.focus",
    "pane.focus_direction",
    "pane.zoom",
    "screen.focus",
    "tab.focus",
    "terminal.input.focus",
    "terminal.viewport.scroll",
    "workspace.focus",
];

/// Provider ops that open UI (a file panel) need a gesture the same way.
/// Listed here before the provider's op joins scopes.json, so a VM can never
/// open a panel without one.
pub const PANEL_OPS: &[&str] = &["fs.pick"];

/// Ops that change what the person has seen or chosen about their chats: an app
/// marks a chat read or pins it only in answer to a tap, never on its own.
pub const PERSON_MARK_OPS: &[&str] = &["chat.mark_read", "chat.pin"];

/// Whether an app call of `op` needs a live user gesture.
pub fn needs_gesture(op: &str) -> bool {
    VIEW_STATE_OPS.contains(&op) || PANEL_OPS.contains(&op) || PERSON_MARK_OPS.contains(&op)
}

/// The escalation of `op`, if it has one.
pub fn escalation(op: &str) -> Option<Escalation> {
    LAUNCH_OPS.contains(&op).then_some(LAUNCH)
}

/// The risk class of `scope` (scope-classes.json, first matching rule), or
/// `None` when no rule knows it: an unknown scope is refused, fail closed.
/// The validator, the supervisor's consent sheet and the store all ask here.
pub fn scope_info(scope: &str) -> Option<ScopeInfo> {
    crate::scopes::scope_info(scope)
}

/// One op as an app sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpCapability {
    pub scope: OpScope,
    pub class: OpClass,
}

impl OpCapability {
    /// The class of the scope an app holds for this op (the first example of
    /// a template); `None` for an ungated op.
    pub fn risk(&self) -> Option<ScopeInfo> {
        self.scope.examples().first().and_then(|scope| scope_info(scope))
    }
}

/// The capability manifest: every op an app may name, and the ops it never
/// reaches.
#[derive(Debug, Default)]
pub struct Capabilities {
    pub api_version: String,
    ops: BTreeMap<String, OpCapability>,
    never: BTreeSet<String>,
}

impl Capabilities {
    /// The embedded table. When it does not load (a broken build; a test
    /// loads it) this is an empty table: no op is known, every call is
    /// refused, fail closed. [`Capabilities::load_error`] says why.
    pub fn get() -> &'static Capabilities {
        &loaded().0
    }

    /// Why the embedded table did not load, if it did not.
    pub fn load_error() -> Option<&'static str> {
        loaded().1.as_deref()
    }

    /// Parses a scopes.json document.
    pub fn parse(raw: &str) -> Result<Self, String> {
        let doc: Value =
            serde_json::from_str(raw).map_err(|e| format!("scopes.json is not JSON: {e}"))?;
        let ops = doc
            .get("ops")
            .and_then(Value::as_object)
            .ok_or("scopes.json has no ops")?
            .iter()
            .map(|(name, entry)| {
                let scope = entry
                    .get("scope")
                    .and_then(Value::as_str)
                    .ok_or_else(|| format!("{name} has no scope"))?;
                let class = OpClass::parse(entry.get("class").and_then(Value::as_str));
                Ok((name.clone(), OpCapability { scope: OpScope::parse(scope), class }))
            })
            .collect::<Result<_, String>>()?;
        let never = doc
            .get("never")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();
        let api_version =
            doc.get("apiVersion").and_then(Value::as_str).unwrap_or_default().to_string();
        Ok(Self { api_version, ops, never })
    }

    pub fn op(&self, name: &str) -> Option<&OpCapability> {
        self.ops.get(name)
    }

    pub fn is_never(&self, name: &str) -> bool {
        self.never.contains(name)
    }

    /// Every op an app may name, sorted.
    pub fn ops(&self) -> impl Iterator<Item = (&str, &OpCapability)> {
        self.ops.iter().map(|(name, op)| (name.as_str(), op))
    }

    /// The ops no app reaches, sorted.
    pub fn never(&self) -> impl Iterator<Item = &str> {
        self.never.iter().map(String::as_str)
    }

    /// One op's row: scope, class, risk class, consent text, gesture,
    /// escalation. `None` when `name` is neither an app op nor a never op.
    pub fn describe(&self, name: &str) -> Option<Value> {
        if self.is_never(name) {
            return Some(json!({
                "op": name,
                "never": true,
                "consent": "No app may call this op; it is the person's own (cmux's UI and CLI).",
            }));
        }
        let op = self.op(name)?;
        let risk = op.risk();
        let consent = match (&op.scope, risk) {
            (OpScope::Ungated, _) => Some("No grant: every installed app may call it.".to_string()),
            (_, Some(info)) => class_description(info.class).map(str::to_string),
            (_, None) => None,
        };
        let escalation =
            escalation(name).map(|e| json!({ "scope": e.scope, "whenParams": e.when_params }));
        Some(json!({
            "op": name,
            "scope": op.scope.wire(),
            "class": op.class.as_str(),
            "risk": risk.map(|info| class_name(info.class)),
            "serverOnly": risk.is_some_and(|info| info.server_only),
            "consent": consent,
            "gesture": needs_gesture(name),
            "external": op.scope.external(),
            "escalation": escalation,
            "never": false,
        }))
    }

    /// The short answer (`apps-capabilities {brief: true}`): the API version
    /// and the typed global's digest, for a dev loop that checks on every
    /// save whether to fetch the whole manifest.
    pub fn summary_json(&self) -> Value {
        json!({ "apiVersion": self.api_version, "typesDigest": types_digest() })
    }

    /// The manifest `apps-capabilities` answers: every op's row, the never
    /// list, the class texts, the API version and the typed global. With
    /// `only`, that op's row alone (`None` when it is not an op).
    pub fn manifest_json(&self, only: Option<&str>) -> Option<Value> {
        if let Some(name) = only {
            let row = self.describe(name)?;
            return Some(json!({
                "apiVersion": self.api_version,
                "typesDigest": types_digest(),
                "ops": [row],
            }));
        }
        let ops: Vec<Value> = self.ops.keys().filter_map(|name| self.describe(name)).collect();
        let classes: Map<String, Value> = [
            ScopeClass::Standard,
            ScopeClass::Sensitive,
            ScopeClass::Restricted,
            ScopeClass::Elevated,
        ]
        .into_iter()
        .map(|class| {
            (class_name(class).to_string(), json!(class_description(class).unwrap_or_default()))
        })
        .collect();
        Some(json!({
            "apiVersion": self.api_version,
            "ops": ops,
            "never": self.never.iter().collect::<Vec<_>>(),
            "classes": classes,
            "types": APP_TYPES,
            "typesDigest": types_digest(),
        }))
    }
}

fn loaded() -> &'static (Capabilities, Option<String>) {
    static TABLE: OnceLock<(Capabilities, Option<String>)> = OnceLock::new();
    TABLE.get_or_init(|| match Capabilities::parse(SCOPES_JSON) {
        Ok(table) => (table, None),
        Err(e) => (Capabilities::default(), Some(e)),
    })
}

pub fn class_name(class: ScopeClass) -> &'static str {
    match class {
        ScopeClass::Standard => "standard",
        ScopeClass::Sensitive => "sensitive",
        ScopeClass::Restricted => "restricted",
        ScopeClass::Elevated => "elevated",
    }
}

/// What the consent sheet says about a class (`classes` in
/// scope-classes.json).
pub fn class_description(class: ScopeClass) -> Option<&'static str> {
    static TEXTS: OnceLock<Option<Value>> = OnceLock::new();
    TEXTS
        .get_or_init(|| serde_json::from_str::<Value>(SCOPE_CLASSES).ok())
        .as_ref()?
        .get("classes")?
        .get(class_name(class))?
        .as_str()
}

/// A rule whose pattern names its scopes literally (no character classes or
/// repetition): an explicit exception, which may shadow a later generic rule.
fn literal(pattern: &str) -> bool {
    !pattern.contains(['[', ']', '{', '}', '*', '+', '?', '\\', '.'])
}

/// Checks the op table against the scope classes and returns every problem
/// (empty when they agree):
/// - every op scope (each example of a template) matches a rule; when it
///   matches more than one, the first (the one that decides) is a literal
///   exception that names the scope, so no scope is decided by which of two
///   generic rules comes first;
/// - every rule is used by an op scope, or says in `gates` what it gates
///   outside the op table (a server's spawn, an interface).
pub fn cross_check(capabilities: &Capabilities, classes_json: &str) -> Vec<String> {
    let mut problems = Vec::new();
    let table: Value = match serde_json::from_str(classes_json) {
        Ok(table) => table,
        Err(e) => return vec![format!("scope-classes.json is not JSON: {e}")],
    };
    let mut rules = Vec::new();
    for rule in table.get("rules").and_then(Value::as_array).into_iter().flatten() {
        let pattern = rule.get("pattern").and_then(Value::as_str).unwrap_or_default();
        match Regex::new(pattern) {
            Ok(re) => rules.push((pattern, re, rule.get("gates").is_some())),
            Err(e) => problems.push(format!("rule {pattern:?} does not compile: {e}")),
        }
    }
    let mut used = vec![false; rules.len()];
    let scopes: BTreeSet<String> =
        capabilities.ops().flat_map(|(_, op)| op.scope.examples()).collect();
    for scope in &scopes {
        let matching: Vec<(usize, &str)> = rules
            .iter()
            .enumerate()
            .filter(|(_, (_, re, _))| re.is_match(scope))
            .map(|(i, (pattern, _, _))| (i, *pattern))
            .collect();
        let Some(&(first, first_pattern)) = matching.first() else {
            problems.push(format!("{scope} matches no rule in scope-classes.json"));
            continue;
        };
        if let Some(flag) = used.get_mut(first) {
            *flag = true;
        }
        if matching.len() > 1 && !literal(first_pattern) {
            let patterns: Vec<&str> = matching.iter().map(|(_, pattern)| *pattern).collect();
            problems.push(format!(
                "{scope} matches {} rules {patterns:?}; the first is generic, so rule order decides its class: add a literal rule for it first",
                matching.len()
            ));
        }
    }
    for ((pattern, _, gates), used) in rules.iter().zip(used) {
        if !used && !gates {
            problems.push(format!(
                "rule {pattern:?} classifies no op scope and has no `gates`: say what it gates, or remove it"
            ));
        }
    }
    problems
}

#[cfg(test)]
mod tests;

//! Extension signal sources (`cmux.signal.source/1`, extensions DESIGN.md section 7): an
//! extension declares a source with a value schema and a floor; other extensions watch it under
//! its scope.
//!
//! - **Declared.** `implements["cmux.signal.source/1"].options.sources.<key>` of an installed,
//!   enabled app (none in safe mode) is the source `<app namespace>.<key>` (`acme/tickets`
//!   declares `open`, watched as `acme.tickets.open`). The namespace comes from the app id
//!   (`cmux_app_manifest::app_namespace`), so no app can declare or spoof another app's source.
//! - **Scoped.** A reader needs `<app namespace>:read` (`acme.tickets:read`, a standard read
//!   scope it asks for in its own `scopes`); the declaring app reads its own sources.
//! - **Published.** `signal.publish {name, value}` from the declaring app only. The value must
//!   pass the source's JSON Schema and be at most [`MAX_VALUE_BYTES`]; the daemon keeps the
//!   last one per source, one copy for every reader.
//! - **Floored.** Readers hear `<name>.changed` (an empty invalidation, like every app stream)
//!   at most once per `pollFloorSeconds`: a publish inside the floor is kept and told once when
//!   the floor ends, so a source that publishes per frame still costs readers one read a floor.
//! - **Read.** `signal.read {name}` -> `{value, updatedAt, stale}` (`value` and `updatedAt`
//!   null before the first publish; `stale` once the value is older than `staleAfterSeconds`).
//!   `signal.sources.list {}` lists every source with whether the caller may read it.

use std::collections::HashMap;
use std::sync::{Arc, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::grants::Grant;
use super::supervisor::{Inner, Supervisor, now_ms};

pub(super) const INTERFACE: &str = "cmux.signal.source/1";
pub(super) const PUBLISH: &str = "signal.publish";
pub(super) const READ: &str = "signal.read";
pub(super) const LIST: &str = "signal.sources.list";
/// The largest published value, as JSON.
pub(super) const MAX_VALUE_BYTES: usize = 64 * 1024;
const STREAM_SUFFIX: &str = ".changed";

/// Whether the supervisor answers `op` itself (no provider, no router).
pub(super) fn owns(op: &str) -> bool {
    matches!(op, PUBLISH | READ | LIST)
}

/// One declared source.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Source {
    pub app: String,
    pub name: String,
    pub scope: String,
    pub docs: String,
    pub value: Value,
    pub floor: Duration,
    pub stale_after: Option<Duration>,
}

impl Source {
    pub(super) fn stream(&self) -> String {
        format!("{}{STREAM_SUFFIX}", self.name)
    }

    /// Whether a caller of `app` holding `grant` may read it.
    pub(super) fn readable(&self, app: &str, grant: &Grant) -> bool {
        app == self.app || grant.scopes.contains(&self.scope)
    }

    fn json(&self, readable: bool) -> Value {
        json!({
            "name": self.name, "app": self.app, "scope": self.scope, "docs": self.docs,
            "value": self.value, "pollFloorSeconds": self.floor.as_secs(),
            "staleAfterSeconds": self.stale_after.map(|d| d.as_secs()), "readable": readable,
        })
    }
}

/// The sources `app`'s manifest declares, in key order; an entry the options schema would
/// refuse (no value schema, a floor outside 1..=86400 s) is skipped.
pub(super) fn sources_of(app: &str, manifest: &Value) -> Vec<Source> {
    let namespace = cmux_app_manifest::app_namespace(app);
    let Some(sources) =
        manifest.pointer(&format!("/implements/{}/options/sources", INTERFACE.replace('/', "~1")))
    else {
        return Vec::new();
    };
    let mut out: Vec<Source> = sources
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(key, _)| valid_key(key))
        .filter_map(|(key, def)| {
            let floor =
                def.get("pollFloorSeconds")?.as_u64().filter(|s| (1..=86_400).contains(s))?;
            let value = def.get("value").filter(|v| v.is_object())?.clone();
            Some(Source {
                app: app.to_string(),
                name: format!("{namespace}.{key}"),
                scope: format!("{namespace}:read"),
                docs: def.get("docs").and_then(Value::as_str).unwrap_or_default().to_string(),
                value,
                floor: Duration::from_secs(floor),
                stale_after: def
                    .get("staleAfterSeconds")
                    .and_then(Value::as_u64)
                    .filter(|s| *s > 0)
                    .map(Duration::from_secs),
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn valid_key(key: &str) -> bool {
    let mut chars = key.chars();
    key.len() <= 32
        && chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// What a publish did for its readers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Tell {
    /// Readers are told now.
    Now,
    /// Inside the floor: readers are told after this (the caller schedules it).
    After(Duration),
    /// Inside the floor with a tell already scheduled: it carries this value too.
    Queued,
}

struct Kept {
    app: String,
    value: Value,
    updated_ms: u64,
    updated: Instant,
    told: Option<Instant>,
    pending: bool,
}

/// The last value of every published source and its floor state (one copy for every reader).
#[derive(Default)]
pub struct SignalSources {
    kept: HashMap<String, Kept>,
    /// Compiled value schemas by source name, with the schema they were compiled from.
    validators: HashMap<String, (Value, Arc<jsonschema::Validator>)>,
}

fn refusal(code: &str, message: impl Into<String>) -> Value {
    json!({ "code": code, "message": message.into(), "retryable": false })
}

impl SignalSources {
    /// Checks `value` against `source` and keeps it; says when readers hear of it.
    pub(super) fn publish(
        &mut self,
        source: &Source,
        value: Value,
        now: Instant,
        now_ms: u64,
    ) -> Result<Tell, Value> {
        let size = serde_json::to_vec(&value).map_or(usize::MAX, |b| b.len());
        if size > MAX_VALUE_BYTES {
            return Err(refusal(
                "app.limit",
                format!("{}: a value is at most {MAX_VALUE_BYTES} bytes, not {size}", source.name),
            ));
        }
        let validator = self.validator(source)?;
        let errors: Vec<String> = validator
            .iter_errors(&value)
            .take(4)
            .map(|e| format!("{}: {e}", e.instance_path))
            .collect();
        if !errors.is_empty() {
            return Err(refusal(
                "validation.invalid",
                format!("{}: {}", source.name, errors.join("; ")),
            ));
        }
        let kept = self.kept.entry(source.name.clone()).or_insert_with(|| Kept {
            app: source.app.clone(),
            value: Value::Null,
            updated_ms: 0,
            updated: now,
            told: None,
            pending: false,
        });
        if kept.app != source.app {
            // Another app's leftover under this name (an uninstall that did not clear it).
            kept.app = source.app.clone();
            kept.told = None;
            kept.pending = false;
        }
        kept.value = value;
        kept.updated_ms = now_ms;
        kept.updated = now;
        if kept.pending {
            return Ok(Tell::Queued);
        }
        match kept.told.map(|t| now.saturating_duration_since(t)) {
            Some(since) if since < source.floor => {
                kept.pending = true;
                Ok(Tell::After(source.floor - since))
            }
            _ => {
                kept.told = Some(now);
                Ok(Tell::Now)
            }
        }
    }

    /// A scheduled tell is due: true when readers should hear of the kept value now.
    pub(super) fn due(&mut self, name: &str, now: Instant) -> bool {
        let Some(kept) = self.kept.get_mut(name).filter(|k| k.pending) else { return false };
        kept.pending = false;
        kept.told = Some(now);
        true
    }

    /// `{value, updatedAt, stale}` of `source`.
    pub(super) fn read(&self, source: &Source, now: Instant) -> Value {
        match self.kept.get(&source.name).filter(|k| k.app == source.app) {
            Some(kept) => json!({
                "value": kept.value,
                "updatedAt": kept.updated_ms,
                "stale": source
                    .stale_after
                    .is_some_and(|after| now.saturating_duration_since(kept.updated) >= after),
            }),
            None => json!({ "value": null, "updatedAt": null, "stale": false }),
        }
    }

    /// Drops every value `app` published (its uninstall).
    pub(super) fn forget_app(&mut self, app: &str) {
        self.kept.retain(|_, k| k.app != app);
        let prefix = format!("{}.", cmux_app_manifest::app_namespace(app));
        self.validators.retain(|name, _| !name.starts_with(&prefix));
    }

    fn validator(&mut self, source: &Source) -> Result<Arc<jsonschema::Validator>, Value> {
        if let Some((schema, v)) = self.validators.get(&source.name)
            && *schema == source.value
        {
            return Ok(v.clone());
        }
        let v = jsonschema::draft202012::new(&source.value).map(Arc::new).map_err(|e| {
            refusal(
                "validation.invalid",
                format!("{}: the value schema does not compile: {e}", source.name),
            )
        })?;
        self.validators.insert(source.name.clone(), (source.value.clone(), v.clone()));
        Ok(v)
    }
}

impl Supervisor {
    /// Every source of installed, enabled apps (none in safe mode), in name order.
    pub(super) fn signal_sources_locked(inner: &Inner) -> Vec<Source> {
        if inner.safe_mode.is_some() {
            return Vec::new();
        }
        let mut out: Vec<Source> = inner
            .mirror
            .apps
            .iter()
            .filter(|(_, record)| record.installed && record.enabled)
            .filter_map(|(app, _)| {
                Some(sources_of(app, &inner.catalog.packages.get(app)?.manifest))
            })
            .flatten()
            .collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    /// The source named `name`, if an installed, enabled app declares it.
    pub(super) fn signal_source_locked(inner: &Inner, name: &str) -> Option<Source> {
        if inner.safe_mode.is_some() {
            return None;
        }
        let (namespace, _) = name.rsplit_once('.')?;
        inner
            .mirror
            .apps
            .iter()
            .filter(|(app, record)| {
                record.installed
                    && record.enabled
                    && cmux_app_manifest::app_namespace(app) == namespace
            })
            .find_map(|(app, _)| {
                sources_of(app, &inner.catalog.packages.get(app)?.manifest)
                    .into_iter()
                    .find(|s| s.name == name)
            })
    }

    /// The source whose change stream is `stream` (`acme.tickets.open.changed`).
    pub(super) fn signal_source_for_stream(inner: &Inner, stream: &str) -> Option<Source> {
        Self::signal_source_locked(inner, stream.strip_suffix(STREAM_SUFFIX)?)
    }

    /// `signal.publish`, `signal.read` and `signal.sources.list` for `app` holding `grant`.
    pub(super) fn signal_call(
        &self,
        app: &str,
        op: &str,
        params: &Value,
        grant: &Grant,
    ) -> Result<Value, Value> {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if op == LIST {
            let sources = Self::signal_sources_locked(&inner)
                .iter()
                .map(|s| s.json(s.readable(app, grant)))
                .collect::<Vec<_>>();
            return Ok(json!({ "sources": sources }));
        }
        let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
        let Some(source) = Self::signal_source_locked(&inner, name) else {
            return Err(refusal(
                "signal.unknown",
                format!("no extension declares the signal source {name:?}"),
            ));
        };
        if op == READ {
            if !source.readable(app, grant) {
                return Err(json!({
                    "code": "scope.missing",
                    "message": format!("this app needs {} to watch {name}", source.scope),
                    "details": { "scopes": [source.scope] }, "retryable": false,
                }));
            }
            return Ok(inner.signal_sources.read(&source, Instant::now()));
        }
        if source.app != app {
            return Err(refusal("scope.missing", format!("only {} publishes {name}", source.app)));
        }
        let value = params.get("value").cloned().unwrap_or(Value::Null);
        let tell = inner.signal_sources.publish(&source, value, Instant::now(), now_ms())?;
        match tell {
            Tell::Now => Self::publish_stream_locked(&inner, &source.stream(), json!({})),
            Tell::After(after) => {
                let me = self.me.clone();
                let name = source.name;
                self.timers.schedule(after, move || {
                    if let Some(me) = me.upgrade() {
                        me.signal_source_due(&name);
                    }
                });
            }
            Tell::Queued => {}
        }
        drop(inner);
        Ok(json!({ "told": tell == Tell::Now }))
    }

    /// A floored tell is due: readers hear the source's kept value, if it is still declared.
    fn signal_source_due(&self, name: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if !inner.signal_sources.due(name, Instant::now()) {
            return;
        }
        if let Some(source) = Self::signal_source_locked(&inner, name) {
            Self::publish_stream_locked(&inner, &source.stream(), json!({}));
        }
    }
}

#[cfg(test)]
#[path = "signal_sources_tests.rs"]
mod tests;

//! Part of `Hub`; see `hub/mod.rs`. The guarded receive of a moved chat (`transfer_in.rs`):
//! `_acpmux/transfer_receive {manifest, guard: {control, roots}}`, for a chat from a daemon this
//! one does not take as its own user (Move to Cloud: a Mac's chat on a cloud machine, or a cloud
//! machine's chat coming back to the Mac). Still the local socket only; the caller builds the
//! guard itself and never takes it from the other side.
//!
//! - `control`: `peer` or `web`, the rules the chat's queued prompts run under here (`web`
//!   also gates them on folder trust, `server/trust_gate.rs`).
//! - `roots`: existing folders strictly under the home folder the chat may work in: not the home
//!   folder, not one in a hidden folder of it, and none holding `~/.claude`, `~/.codex` or
//!   acpmux's own home.
//!
//! The guard is stored with the receive (`guard.json`), so `transfer_write` and
//! `transfer_finish` are held to it whatever they are sent. A guarded receive takes only the
//! bundle's own files and at most `native::MAX_GUARDED_FILES` agent store files ([`bundle_path_kind`]),
//! never a terminal agent, and for `web` never a family the Web does not drive. A guarded finish
//! ([`Hub::guard_session`]) refuses, never downgrades, a `web` chat that would run without asking,
//! and the queue it brings runs under the guard's control ([`guarded_record`]).

use super::*;
use crate::config::HarnessKind;
use cmux_json::JsonSet as _;

/// The longest `from` (serialized) a guarded finish records.
const MAX_FROM: usize = 4 << 10;
const MAX_ROOTS: usize = 16;
const GUARD_FILE: &str = "guard.json";

fn guard_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// A guarded import (`transfer.rs` `import_into`): the guard, and whether the chat's agent file
/// replaces its moved-away copy's.
#[derive(Clone, Copy)]
pub(super) struct GuardedImport<'a> {
    pub(super) guard: &'a Guard,
    pub(super) replace_native: bool,
}

/// A receive's guard.
pub(super) struct Guard {
    pub(super) control: Control,
    pub(super) roots: Vec<PathBuf>,
}

impl Guard {
    /// `_acpmux/transfer_receive`'s `guard`, checked: exactly `{control, roots}`.
    pub(super) async fn parse(v: &Value) -> Result<Guard, RpcError> {
        let bad = |m: String| guard_error("guard", m);
        let obj = v.as_object().ok_or_else(|| bad("must be {control, roots}".into()))?;
        if let Some(k) = obj.keys().find(|k| !matches!(k.as_str(), "control" | "roots")) {
            return Err(bad(format!("unknown key {k:?}")));
        }
        let control = match obj.get("control").and_then(Value::as_str) {
            Some("peer") => Control::Peer,
            Some("web") => Control::Web,
            other => {
                return Err(bad(format!("control must be \"peer\" or \"web\", not {other:?}")));
            }
        };
        let raw = obj
            .get("roots")
            .and_then(Value::as_array)
            .filter(|r| !r.is_empty() && r.len() <= MAX_ROOTS)
            .ok_or_else(|| bad(format!("roots must be 1 to {MAX_ROOTS} folders")))?;
        let home = match dirs::home_dir() {
            Some(h) => {
                let spelling = spelled(&h).await;
                spelling.unwrap_or(h)
            }
            None => return Err(bad("this daemon has no home folder".into())),
        };
        let mut stores = Vec::new();
        for store in [home.join(".claude"), home.join(".codex"), crate::config::home()] {
            let spelling = spelled(&store).await;
            stores.push(spelling.unwrap_or(store));
        }
        let mut roots = Vec::new();
        for r in raw {
            let s = r.as_str().ok_or_else(|| bad(format!("root {r} is not a path")))?;
            let root = checked_root(s, &home, &stores)
                .await
                .map_err(|why| bad(format!("root {s:?} {why}")))?;
            if !roots.contains(&root) {
                roots.push(root);
            }
        }
        Ok(Guard { control, roots })
    }

    pub(super) fn to_value(&self) -> Value {
        json!({"control": self.control.as_str(), "roots": self.roots})
    }

    pub(super) fn store(&self, dir: &Path) -> std::io::Result<()> {
        std::fs::write(dir.join(GUARD_FILE), serde_json::to_vec(&self.to_value())?)
    }

    /// The guard a receive stored, or None for an unguarded receive.
    pub(super) fn stored(dir: &Path) -> Result<Option<Guard>, RpcError> {
        let raw = match std::fs::read(dir.join(GUARD_FILE)) {
            Ok(raw) => raw,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(guard_error("guard", e)),
        };
        let v: Value = serde_json::from_slice(&raw).map_err(|e| guard_error("guard", e))?;
        let control = match v["control"].as_str() {
            Some("peer") => Control::Peer,
            Some("web") => Control::Web,
            _ => return Err(guard_error("guard", "the stored guard is unreadable")),
        };
        let roots: Vec<PathBuf> = v["roots"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|r| r.as_str().map(PathBuf::from))
            .collect();
        if roots.is_empty() {
            return Err(guard_error("guard", "the stored guard has no roots"));
        }
        Ok(Some(Guard { control, roots }))
    }

    /// The canonical form of `path` when it is a folder under one of the roots.
    pub(super) async fn folder(&self, path: &str) -> Option<PathBuf> {
        if !Path::new(path).is_absolute() {
            return None;
        }
        let canonical = spelled(Path::new(path)).await?;
        let inside = canonical.is_dir() && self.roots.iter().any(|r| canonical.starts_with(r));
        inside.then_some(canonical)
    }
}

/// `path` resolved and spelled as the filesystem stores it (`remote_guard.rs`).
async fn spelled(path: &Path) -> Option<PathBuf> {
    crate::server::remote_guard::fs_spelling(&path.to_string_lossy()).await
}

async fn checked_root(s: &str, home: &Path, stores: &[PathBuf]) -> Result<PathBuf, &'static str> {
    if !Path::new(s).is_absolute() {
        return Err("is not absolute");
    }
    let root = spelled(Path::new(s)).await.ok_or("does not exist")?;
    if !root.is_dir() {
        return Err("is not a folder");
    }
    let rel = root.strip_prefix(home).map_err(|_| "is not under the home folder")?;
    let first = rel.components().next().ok_or("is the home folder")?;
    if first.as_os_str().to_string_lossy().starts_with('.') {
        return Err("is in a hidden folder of the home folder");
    }
    if stores.iter().any(|s| s.starts_with(&root)) {
        return Err("holds an agent's store or acpmux's home");
    }
    Ok(root)
}

/// Whether a guarded move takes the bundle file `path`: `Some(true)` for an agent store file,
/// `Some(false)` for the bundle's own (`session.json`, `manifest.json`, `events/*.ndjson`).
pub(super) fn bundle_path_kind(path: &str) -> Option<bool> {
    let parts: Vec<String> = Path::new(path)
        .components()
        .map(|c| match c {
            std::path::Component::Normal(p) => p.to_string_lossy().into_owned(),
            _ => String::new(),
        })
        .collect();
    let parts: Vec<&str> = parts.iter().map(String::as_str).collect();
    let jsonl = |f: &str| f.len() > ".jsonl".len() && f.ends_with(".jsonl");
    match parts.as_slice() {
        ["session.json"] | ["manifest.json"] => Some(false),
        ["events", f] if f.len() > ".ndjson".len() && f.ends_with(".ndjson") => Some(false),
        ["harness", "journal.ndjson"] | ["harness", "session.jsonl"] => Some(false),
        ["native", "claude-project", ".claude", "projects", dir, f]
            if !dir.is_empty() && jsonl(f) =>
        {
            Some(true)
        }
        ["native", "codex-rollout", ".codex", "sessions", rest @ ..]
            if (1..=5).contains(&rest.len())
                && rest.iter().all(|p| !p.is_empty())
                && rest.last().is_some_and(|f| jsonl(f)) =>
        {
            Some(true)
        }
        _ => None,
    }
}

/// A plain agent session id: the only kind a guarded chat resumes or restores a file for.
pub(super) fn plain_agent_session(id: &str) -> bool {
    (8..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// A bundle record whose prompt runs later here (queued, edited, or started before the move)
/// runs under the guard's control; `web` also gates it on folder trust. No record keeps a
/// prompt's provenance: only this daemon's unix socket says an agent sent a prompt.
pub(super) fn guarded_record(rec: &mut EventRecord, control: Control) {
    if matches!(rec.kind.as_str(), "queued" | "queue_updated" | "user_message")
        && let Some(meta) = rec.msg.get_mut("_meta").and_then(Value::as_object_mut)
    {
        meta.remove("provenance");
    }
    if matches!(rec.kind.as_str(), "queued" | "queue_updated" | "turn_started")
        && rec.msg.is_object()
    {
        rec.msg.set("control", json!(control.as_str()));
        if control == Control::Web {
            rec.msg.set("trustGate", json!(true));
        }
    }
}

impl Hub {
    /// What a guarded receive takes, from its manifest: a configured agent that is not a
    /// terminal one (and for `web`, of a family the Web drives), and only bundle files.
    pub(super) async fn guarded_receive_check(
        &self,
        guard: &Guard,
        manifest: &Value,
    ) -> Result<(), RpcError> {
        let harness = manifest["session"]["harness"].as_str().unwrap_or("");
        let family = {
            let cfg = self.config.read().await;
            let profile = cfg.harnesses.get(harness).filter(|p| p.kind != HarnessKind::Terminal);
            let profile = profile.ok_or_else(|| {
                guard_error("harness", format!("agent {harness:?} does not run here as a chat"))
            })?;
            crate::config::derive_family(harness, profile)
        };
        if guard.control == Control::Web && self.web_modes().refused().contains(&family) {
            return Err(guard_error(
                "family",
                format!("a {family} chat is never driven from a remote connection"),
            ));
        }
        let (mut native, mut native_bytes) = (0usize, 0u64);
        for f in manifest["files"].as_array().into_iter().flatten() {
            let path = f["path"].as_str().unwrap_or("");
            match bundle_path_kind(path) {
                None => {
                    return Err(guard_error(
                        "path",
                        format!("{path:?} is not a file a guarded move takes"),
                    ));
                }
                Some(true) => {
                    native += 1;
                    native_bytes =
                        native_bytes.saturating_add(f["size"].as_u64().unwrap_or(u64::MAX));
                }
                Some(false) => {}
            }
        }
        if native > crate::native::MAX_GUARDED_FILES
            || native_bytes > crate::native::MAX_GUARDED_BYTES
        {
            return Err(guard_error(
                "native",
                format!("{native} agent store files, {native_bytes} bytes"),
            ));
        }
        Ok(())
    }

    /// Rewrites a guarded receive's `session.json` to the chat it may be here, before the import,
    /// or refuses it: its folder (`cwd`, else its own) under a root, spelled canonically; its
    /// family from this daemon's profile; no policy is `ask`, and under `web` its policy,
    /// rules, mode and options asking; no preset, session env, store roots, argv or tags, and a remote origin (no
    /// preset args, no cmux MCP servers); a model only when the profile declares it; a Claude
    /// profile only when configured; and its agent store files exactly its session's. It keeps
    /// its agent session only with its file, which must not be here already unless it is the
    /// session of the chat's own moved-away copy (`replaceable`). Answers the chat and whether
    /// its file replaces that copy's.
    pub(super) async fn guard_session(
        &self,
        bundle: &Path,
        guard: &Guard,
        cwd: Option<&str>,
        from: &Value,
        replaceable: Option<&str>,
    ) -> Result<(SessionMeta, bool), RpcError> {
        if !serde_json::to_vec(from).is_ok_and(|f| f.len() <= MAX_FROM) {
            return Err(guard_error("from", format!("from is over {MAX_FROM} bytes")));
        }
        let path = bundle.join("session.json");
        let raw = std::fs::read(&path)
            .map_err(|e| RpcError::invalid_params(format!("read session.json: {e}")))?;
        let mut meta: SessionMeta = serde_json::from_slice(&raw)
            .map_err(|e| RpcError::invalid_params(format!("parse session.json: {e}")))?;
        // An approve-all an older daemon or a vmHost machine gave asks here (`policy_source.rs`).
        super::policy_source::settle_imported_grant(&mut meta);
        let wanted = cwd.map_or_else(|| meta.cwd.to_string_lossy().into_owned(), str::to_owned);
        meta.cwd = guard.folder(&wanted).await.ok_or_else(|| {
            guard_error("cwd", format!("{wanted:?} is not a folder under the move's roots"))
        })?;
        {
            let cfg = self.config.read().await;
            let profile =
                cfg.harnesses.get(&meta.harness).filter(|p| p.kind != HarnessKind::Terminal);
            let profile = profile.ok_or_else(|| {
                guard_error(
                    "harness",
                    format!("agent {:?} does not run here as a chat", meta.harness),
                )
            })?;
            meta.family = Some(crate::config::derive_family(&meta.harness, profile));
            meta.model_request = meta
                .model_request
                .take()
                .filter(|m| profile.models.iter().any(|d| d.id() == m.as_str()));
            meta.claude_profile =
                meta.claude_profile.take().filter(|p| cfg.harnesses.contains_key(p));
        }
        let policy = meta.permission_policy.get_or_insert_with(|| "ask".to_owned());
        // Under the Web's control everything must ask. A peer guard moves the person's chat
        // between their own machines, and a peer's prompts have no mode rule at dispatch, so it
        // keeps its policy, rules and mode (`hub/web_control.rs`).
        if guard.control == Control::Web {
            if !person::asking_policy_value(Some(&json!(policy))) {
                return Err(guard_error(
                    "policy",
                    format!("policy {policy} does not ask before it acts"),
                ));
            }
            if !person::rules_cannot_auto_approve(meta.permission_rules.as_ref()) {
                return Err(guard_error(
                    "policy",
                    "its permission rules could approve without asking",
                ));
            }
            self.web_guard_modes(&meta)?;
        }
        meta.preset = None;
        meta.session_env.clear();
        meta.workspace_id = None;
        meta.harness_roots.clear();
        meta.harness_argv.clear();
        meta.spawn_argv = None;
        meta.launch_digest = None;
        meta.tags.clear();
        meta.remote_origin = true;
        if let Some(sid) = meta.agent_session_id.as_deref()
            && !plain_agent_session(sid)
        {
            return Err(guard_error(
                "native",
                format!("agent session id {sid:?} is not a plain id"),
            ));
        }
        let plan =
            crate::native::guarded_plan(bundle, &meta).map_err(|e| guard_error("native", e))?;
        // The chat resumes only an agent session it brings: with no file of it, its agent starts
        // fresh (with its acpmux history), never on a session that happens to be here. That
        // history still names the old root, so it stays retired, not a worker.
        if plan.is_empty() && meta.harness != "cmux-harness" {
            meta.retire_agent_session_id();
        }
        // One that is here already is another chat's, or this chat's from before it moved away:
        // only the latter gives way.
        let home = dirs::home_dir().unwrap_or_default();
        let taken = plan.iter().any(|(_, rel)| std::fs::symlink_metadata(home.join(rel)).is_ok());
        let own = replaceable.is_some() && replaceable == meta.agent_session_id.as_deref();
        if taken && !own {
            return Err(guard_error(
                "session",
                "the chat's agent session is here already and is not this chat's",
            ));
        }
        let written = serde_json::to_vec_pretty(&meta)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| Ok(std::fs::write(&path, bytes)?));
        written.map_err(|e| RpcError::internal(format!("transfer: {e}")))?;
        Ok((meta, taken))
    }

    /// A web-guarded chat's mode, and every option that is not a model, effort or speed choice
    /// (`FREE_CONFIG_IDS`, `CARRIED_CONFIG_IDS`), must be
    /// one this daemon's table lists as asking for its family, never of a family the Web does not
    /// drive. A chat of a family with asking modes must have a recorded mode: a Web prompt for a
    /// chat with none passes dispatch on its policy (`session_asks_now`), and its agent could
    /// start in a mode that does not ask.
    fn web_guard_modes(&self, meta: &SessionMeta) -> Result<(), RpcError> {
        let table = self.web_modes();
        let family = crate::web_modes::family_of(meta);
        let listed = |mode: &str| table.modes(&family).iter().any(|m| m == mode);
        let mode = crate::web_modes::mode_of(meta);
        let refused = table.refused().contains(&family);
        // Dispatch takes a Web prompt for a chat with no recorded mode on its policy alone
        // (`remote_floor.rs` `session_asks_now`), so a family with asking modes must name one.
        let unnamed = table.modes(&family).is_empty();
        if refused || mode.as_deref().map_or(!unnamed, |m| !listed(m)) {
            let shown = mode.as_deref().unwrap_or("(none)");
            return Err(guard_error(
                "mode",
                format!("mode {shown} does not ask before it acts for a {family} chat here"),
            ));
        }
        let options = meta.config_options.as_ref().and_then(Value::as_array);
        for o in options.into_iter().flatten() {
            let id = o.get("id").and_then(Value::as_str).unwrap_or("");
            let value = o.get("currentValue").and_then(Value::as_str);
            let asks = crate::web_modes::FREE_CONFIG_IDS.contains(&id)
                || crate::web_modes::CARRIED_CONFIG_IDS.contains(&id)
                || (id == "mode" && value.is_some_and(&listed));
            if !asks {
                return Err(guard_error(
                    "mode",
                    format!("option {id:?} = {value:?} is not known to ask before it acts"),
                ));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod durable_harness_tests {
    use super::bundle_path_kind;

    #[test]
    fn durable_harness_journal_is_a_bundle_file() {
        assert_eq!(bundle_path_kind("harness/journal.ndjson"), Some(false));
        assert_eq!(bundle_path_kind("harness/session.jsonl"), Some(false));
        assert_eq!(bundle_path_kind("harness/owner.sqlite"), None);
        assert_eq!(bundle_path_kind("harness/../journal.ndjson"), None);
    }
}

#[cfg(test)]
mod retired_root_tests {
    use super::*;

    /// Review of #27851: a guarded move with no agent file starts its agent fresh, but its
    /// acpmux history still names the old root, so that root stays retired (never a worker).
    #[tokio::test]
    async fn a_guarded_move_without_its_agent_file_retires_the_old_root() {
        let dir = std::env::temp_dir().join(format!("acpmux-test-{}", uuid::Uuid::now_v7()));
        let work = dir.join("work");
        std::fs::create_dir_all(&work).unwrap();
        let work = std::fs::canonicalize(&work).unwrap();
        let profile = crate::config::HarnessProfile {
            kind: Default::default(),
            argv: vec!["true".into()],
            env: Default::default(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        let mut cfg = crate::config::Config::default();
        cfg.harnesses.insert("codex".into(), profile);
        cfg.store.mode = crate::config::StoreMode::Local;
        let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
        let bundle = dir.join("bundle");
        std::fs::create_dir_all(&bundle).unwrap();
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": uuid::Uuid::now_v7().to_string(),
            "name": "moved", "harness": "codex", "cwd": work, "agentSessionId": "root-now",
            "retiredAgentSessionIds": ["root-before"],
            "status": "idle", "createdAt": 1, "updatedAt": 1,
        });
        std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
        let guard = Guard { control: Control::Peer, roots: vec![work] };
        let (meta, taken) =
            hub.guard_session(&bundle, &guard, None, &json!({}), None).await.unwrap();
        assert!(!taken);
        assert_eq!(meta.agent_session_id, None, "no agent file: the agent starts fresh");
        assert_eq!(meta.retired_agent_session_ids, ["root-before", "root-now"]);
        assert!(meta.previous_agent_session_ids.is_empty(), "never transcript authority");
        let written: SessionMeta =
            serde_json::from_slice(&std::fs::read(bundle.join("session.json")).unwrap()).unwrap();
        assert_eq!(written.retired_agent_session_ids, ["root-before", "root-now"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

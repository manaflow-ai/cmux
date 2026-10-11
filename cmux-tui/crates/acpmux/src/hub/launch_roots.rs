//! Part of `Hub`; see `hub/mod.rs`. Launch roots (ALL-CHATS-ON-DEVICE C3):
//! every spawn records in its session meta the chat store roots its own env
//! names (after `${cwd}` / `~` expansion), and hands the built-in ones to
//! the device chat index as recorded roots.
//!
//! Built-in harness homes come from the chat index's own resolver
//! (`cmux_chat_index::discover`), fed only the spawn's env, so the rules for
//! `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_DATA_HOME`, `PI_CODING_AGENT_DIR`,
//! `GEMINI_CLI_HOME` and a changed `HOME` live in one place. A profile's
//! `sessions.roots` entries that name a spawn env variable add the profile's
//! own roots. Only absolute, existing folders outside guarded locations are
//! recorded; no other env value is ever stored.

use super::*;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, DiscoveryInput, RootSource, RootSpec, discover};

use crate::store::HarnessRoot;

impl Hub {
    /// Records the launch roots of `profile` (as spawned) on `session` and
    /// gives the built-in ones to the chat index. Best effort: a failure is
    /// logged and never stops the spawn.
    pub(super) async fn record_launch_roots(&self, session: &Session, profile: &HarnessProfile) {
        let meta = session.meta();
        let sessions_roots = {
            let cfg = self.config.read().await;
            cfg.profile_meta
                .get(&meta.harness)
                .and_then(|m| m.sessions.as_ref())
                .map(|s| s.roots.clone())
                .unwrap_or_default()
        };
        let Some(home) = dirs::home_dir() else { return };
        let acpmux_home = crate::config::home();
        let env = profile.env.clone();
        let id = meta.harness.clone();
        let found = tokio::task::spawn_blocking(move || {
            let refuse = |p: &Path| crate::chats::refusal(p, &home, &acpmux_home);
            launch_roots(&env, &home, &sessions_roots, &id, &refuse)
        })
        .await;
        let Ok(roots) = found else { return };
        if let Some(chats) = self.chats.get() {
            let specs: Vec<RootSpec> = roots
                .iter()
                .filter_map(|r| {
                    let harness = AdapterKind::from_id(&r.harness)?;
                    Some(RootSpec { harness, path: r.path.clone(), label: None })
                })
                .collect();
            if !specs.is_empty() {
                let chats = chats.clone();
                let _ =
                    tokio::task::spawn_blocking(move || chats.record_launch_roots(&specs)).await;
            }
        }
        if roots == meta.harness_roots {
            return;
        }
        let saved = {
            let mut m = session.meta.lock().unwrap_or_else(|p| p.into_inner());
            m.harness_roots = roots;
            m.clone()
        };
        if let Err(e) = self.store.save(&saved) {
            tracing::warn!(session = %session.id, "save launch roots: {e:#}");
        }
    }
}

/// The chat store roots that a spawn env names, sorted by path.
pub fn launch_roots(
    env: &BTreeMap<String, String>,
    home: &Path,
    sessions_roots: &[String],
    profile_id: &str,
    refuse: &dyn Fn(&Path) -> Option<String>,
) -> Vec<HarnessRoot> {
    // A changed HOME moves every default home with it.
    let child_home =
        env.get("HOME").map(PathBuf::from).filter(|h| h.is_absolute() && h.as_path() != home);
    let lookup = |key: &str| env.get(key).cloned();
    let found = discover(&DiscoveryInput {
        home: child_home.as_deref().unwrap_or(home),
        env: &lookup,
        refuse,
        recorded: &[],
        user: &[],
    });
    let mut out: Vec<HarnessRoot> = found
        .roots
        .into_iter()
        .filter(|root| {
            root.source == RootSource::Env
                || (child_home.is_some() && root.source == RootSource::Default)
        })
        .map(|root| HarnessRoot { harness: root.harness.id().to_owned(), path: root.path })
        .collect();
    for entry in sessions_roots {
        let Some(path) = expand_spawn_root(entry, env, child_home.as_deref().unwrap_or(home))
        else {
            continue;
        };
        if path.is_absolute() && path.is_dir() && refuse(&path).is_none() {
            let root = HarnessRoot { harness: profile_id.to_owned(), path };
            if !out.contains(&root) {
                out.push(root);
            }
        }
    }
    out.sort_by(|a, b| a.path.cmp(&b.path).then_with(|| a.harness.cmp(&b.harness)));
    out
}

/// A `sessions.roots` entry with `${VAR}` / `${VAR:-default}` read from the
/// spawn env and a leading `~/` from `home`. None when the entry names no
/// spawn variable (the device index already resolves it from the login
/// env) or a variable it names is unset.
fn expand_spawn_root(entry: &str, env: &BTreeMap<String, String>, home: &Path) -> Option<PathBuf> {
    let mut out = String::new();
    let mut rest = entry;
    let mut named = false;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let end = rest[start..].find('}')? + start;
        let inner = &rest[start + 2..end];
        let (key, default) = match inner.split_once(":-") {
            Some((k, d)) => (k, Some(d)),
            None => (inner, None),
        };
        match env.get(key).filter(|v| !v.is_empty()) {
            Some(value) => {
                named = true;
                out.push_str(value);
            }
            None => out.push_str(default?),
        }
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    if !named {
        return None;
    }
    Some(match out.strip_prefix("~/") {
        Some(tail) => home.join(tail),
        None => PathBuf::from(out),
    })
}

//! Live model lists from Claude Code's and Codex's own CLIs (Lawrence
//! 2026-10-08: "copy monocode's live model list"). The curated catalog names a
//! model only after a catalog update; the CLIs know theirs the day they ship.
//!
//! - **Claude Code**: the harness's own `claude` in stream-json mode, the SDK's
//!   `initialize` control request, then `list_models` ([`claude`]).
//! - **Codex**: `codex app-server`, `initialize`, then paged `model/list`
//!   ([`codex`]). The `codex` harness itself runs through the codex-acp
//!   adapter, which reports bare ids without efforts or speed tiers.
//!
//! Each probe is one short-lived child, killed as soon as the list arrives,
//! under its own deadline ([`PROBE_TIMEOUT`]). The hub runs every probe at
//! once beside the ACP probes (`hub/live_models.rs`). The last good list per
//! harness is kept under `$ACPMUX_HOME/live-models/` ([`Cache`]), keyed by the
//! program's real path, size and modification time, so a restarted daemon
//! serves it before any probe runs and a CLI update discards it.
//!
//! The protocol knowledge (the requests, their reply shapes, how efforts and
//! speed tiers map) follows MonoCode's catalog probes
//! (src/integrations/harness/providers/claude/claudeCatalog.ts and
//! codex/codexCatalog.ts, https://github.com/hardbeat920/monocode).
//! Portions adapted from MonoCode, Copyright (c) 2026 Nick, MIT License
//! (see THIRD_PARTY_LICENSES.md).

pub mod claude;
pub mod codex;

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

/// One probe's deadline, start to list. The CLIs answer in well under a second
/// once they run; this bounds a hung or interactive one.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(15);

/// A model as the CLI lists it, in `_acpmux/models` terms.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveModel {
    /// The id the harness takes (`--model`, `set_model`).
    pub id: String,
    pub name: String,
    /// Reasoning efforts the model takes; empty when the CLI names none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub efforts: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_effort: Option<String>,
    /// Whether the model has a fast mode (Claude) or a faster service tier
    /// (Codex); unset when the CLI does not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<bool>,
    /// The CLI's default model.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_default: bool,
}

/// Which CLI a harness's live list comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cli {
    Claude,
    Codex,
}

/// Runs the probe for `cli`: `argv` starts the CLI (for Codex, through
/// `app-server`), `env` is the harness's own. Errors carry the CLI's message
/// (a Codex that is not signed in says so).
pub async fn probe(
    cli: Cli,
    argv: &[String],
    env: &BTreeMap<String, String>,
    cwd: &Path,
    timeout: Duration,
) -> Result<Vec<LiveModel>> {
    let mut child = Probe::spawn(cli, argv, env, cwd)?;
    let listed = tokio::time::timeout(timeout, async {
        match cli {
            Cli::Claude => claude::list(&mut child).await,
            Cli::Codex => codex::list(&mut child).await,
        }
    })
    .await;
    child.kill().await;
    listed.map_err(|_| anyhow!("the model list did not arrive within {} s", timeout.as_secs()))?
}

/// A probe child: line-oriented JSON on stdin and stdout, stderr dropped.
pub(crate) struct Probe {
    child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
}

impl Probe {
    fn spawn(
        cli: Cli,
        argv: &[String],
        env: &BTreeMap<String, String>,
        cwd: &Path,
    ) -> Result<Self> {
        let (program, rest) = argv.split_first().ok_or_else(|| anyhow!("no program to run"))?;
        let mut cmd = Command::new(program);
        crate::login_env::apply_tokio(&mut cmd);
        crate::config::scrub_nested_claude_env_tokio(&mut cmd);
        cmd.args(rest)
            .args(match cli {
                Cli::Claude => claude::args(),
                Cli::Codex => codex::args(),
            })
            .envs(env)
            .current_dir(cwd)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        let mut child = cmd.spawn().with_context(|| format!("cannot start {program}"))?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("{program} has no stdin"))?;
        let stdout = child.stdout.take().ok_or_else(|| anyhow!("{program} has no stdout"))?;
        Ok(Self { child, stdin, lines: BufReader::new(stdout).lines() })
    }

    /// Writes one JSON line.
    pub(crate) async fn send(&mut self, message: &Value) -> Result<()> {
        let mut line = serde_json::to_vec(message)?;
        line.push(b'\n');
        self.stdin.write_all(&line).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    /// The next JSON object the child writes; other lines are skipped.
    pub(crate) async fn next(&mut self) -> Result<Value> {
        loop {
            let line = self.lines.next_line().await?.ok_or_else(|| anyhow!("the CLI exited"))?;
            if let Ok(v @ Value::Object(_)) = serde_json::from_str::<Value>(&line) {
                return Ok(v);
            }
        }
    }

    async fn kill(mut self) {
        let _ = self.child.kill().await;
    }
}

/// A string field, when present and not empty.
pub(crate) fn text<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty())
}

/// The program's identity for the cache: its real path, size and
/// modification time. Unset when the program cannot be read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CacheKey {
    pub program: PathBuf,
    pub len: u64,
    pub modified_ns: u64,
}

impl CacheKey {
    pub fn of(program: &Path) -> Option<Self> {
        let program = std::fs::canonicalize(program).ok()?;
        let meta = std::fs::metadata(&program).ok()?;
        let since = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?;
        let modified_ns = u64::try_from(since.as_nanos()).ok()?;
        Some(Self { program, len: meta.len(), modified_ns })
    }
}

#[derive(Serialize, Deserialize)]
struct CacheFile<M> {
    key: CacheKey,
    models: M,
}

/// The last good live list per harness, one file each.
pub struct Cache {
    dir: PathBuf,
}

impl Cache {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// `$ACPMUX_HOME/live-models`.
    pub fn default_dir() -> PathBuf {
        crate::config::home().join("live-models")
    }

    fn path(&self, harness: &str) -> PathBuf {
        // Profile ids are `[a-z0-9-]`; anything else is kept out of the path.
        let safe: String = harness
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' })
            .collect();
        self.dir.join(format!("{safe}.json"))
    }

    /// Every cached list whose program is unchanged, by harness.
    pub fn load_all(&self) -> BTreeMap<String, Vec<LiveModel>> {
        let mut out = BTreeMap::new();
        let Ok(entries) = std::fs::read_dir(&self.dir) else { return out };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(harness) = path
                .file_stem()
                .and_then(|s| s.to_str())
                .filter(|_| path.extension().is_some_and(|e| e == "json"))
            else {
                continue;
            };
            if let Some(models) = self.load(harness, None) {
                out.insert(harness.to_owned(), models);
            }
        }
        out
    }

    /// The cached list for `harness` when its program is unchanged (and is
    /// `program`, when given).
    pub fn load(&self, harness: &str, program: Option<&Path>) -> Option<Vec<LiveModel>> {
        let file: CacheFile<Vec<LiveModel>> =
            serde_json::from_slice(&std::fs::read(self.path(harness)).ok()?).ok()?;
        let current = CacheKey::of(program.unwrap_or(&file.key.program))?;
        (current == file.key && !file.models.is_empty()).then_some(file.models)
    }

    /// Keeps `models` for `harness` (write to a temporary file, then rename).
    pub fn store(
        &self,
        harness: &str,
        key: &CacheKey,
        models: &[LiveModel],
    ) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        let path = self.path(harness);
        let tmp = path.with_extension("json.tmp");
        let body = serde_json::to_vec(&CacheFile { key: key.clone(), models })?;
        std::fs::write(&tmp, body)?;
        std::fs::rename(&tmp, &path)
    }
}

/// The live fields of `live` over the `_acpmux/models` entries with the same
/// id or alias: efforts, default effort and fast mode come from the CLI, which knows
/// the version it runs. The CLI's default model moves first (after Claude
/// Code's own "default" choice).
pub fn overlay(models: &mut [Value], live: &[LiveModel]) {
    for entry in models.iter_mut() {
        // By id, or by an alias the curated entry lists (`opus` for `claude-opus-5-5`).
        let names = |m: &LiveModel| {
            entry["id"] == m.id.as_str()
                || entry["aliases"].as_array().is_some_and(|a| a.iter().any(|x| x == m.id.as_str()))
        };
        let Some(model) = live.iter().find(|m| names(m)) else {
            continue;
        };
        if !model.efforts.is_empty() {
            entry["efforts"] = json!(model.efforts);
        }
        if let Some(effort) = &model.default_effort {
            entry["defaultEffort"] = json!(effort);
        }
        if let Some(fast) = model.fast {
            entry["fast"] = json!(fast);
        }
    }
    if let Some(default) = live.iter().find(|m| m.is_default)
        && let Some(at) = models.iter().position(|m| m["id"] == default.id.as_str())
    {
        let first = usize::from(models.first().is_some_and(|m| m["id"] == "default"));
        if at > first {
            models[first..=at].rotate_right(1);
        }
    }
}

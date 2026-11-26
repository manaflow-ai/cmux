//! Part of `Hub`; see `hub/mod.rs`. Context surgery: a Claude chat's old tool output is masked
//! instead of summarized by a model (harness magic, Leo 2026-11-24: "let's get fucking
//! researched up! let's RFD AND FUCKING GOOOOO").
//!
//! JetBrains' "The Complexity Trap" (2025) found that masking old tool outputs while keeping the
//! agent's reasoning and actions halves cost at an equal or better solve rate than an LLM
//! summary, which lengthens trajectories and makes the agent read again. `/compact` is one full
//! context model call and loses detail; this spends no model tokens.
//!
//! How ([`mask_claude`]): a copy of the chat's Claude Code transcript
//! (`<CLAUDE_CONFIG_DIR>/projects/<slug>/<sid>.jsonl`) under a new session id, beside the
//! original, which is never changed or deleted. In the copy, every `tool_result` older than the
//! last [`KEEP_TURNS`] person prompts and larger than [`MIN_CHARS`] gets a stub in its place
//! (`[masked by harness: Read /a/b.rs, 18234 chars; you saw it in full then; removed since to
//! save context, re-run or Read to see it again]`; a stub that does not say the agent saw the
//! output makes it disown its earlier answers, measured in the PR). No record is
//! added or removed, so the `parentUuid` chain and every `tool_use`/`tool_result` pair stay as
//! they were; prompts, assistant text, thinking blocks (with their signatures) and tool inputs are
//! copied verbatim. Records before the last `compact_boundary` are not sent to the model and are
//! left alone. A transcript that does not parse, or one with a tool call that has no result yet,
//! is refused: the chat keeps its original.
//!
//! Swap ([`Hub::surgery`]): only between turns (no turn, permission or work below it, the turn
//! lock free). The chat's harness ends, its native id moves to the copy (the old one stays in
//! `previous_agent_session_ids`, so transcript reads follow it) and its harness starts again with
//! `claude --resume <copy>` as a route switch does (`route_switch.rs`): the chat keeps its
//! identity and history in the app. Proven by hand with `claude -p --resume` on a rewritten copy
//! (PR body). Any failure keeps or restores the original id.
//!
//! When: rewriting old content rewrites the prompt cache's prefix, so surgery runs when the cache
//! is cold anyway. Three triggers: `_acpmux/surgery` (the app, other lanes, cold wake's choice
//! instead of `/compact`); and our own default ([`Hub::surgery_on_update`]): a live
//! `usage_update` at [`TRIGGER_SHARE`] of the window or more arms one timer that fires just after
//! the cache's expiry (`_meta.acpmux.cacheExpiresAt`), and masks then if the chat is still idle
//! on the same turn. `cache_compact.rs` (its own lane) decides when `/compact` runs; a completed
//! compaction here disarms the timer, and its smaller usage arms none.
//!
//! Measured: each surgery appends a `harness_surgery` record and puts
//! `harnessMagic.surgery.{runs,tokensBefore,tokensAfter,maskedResults}` on the next
//! `turn_result`; for the [`REFETCH_TURNS`] turns after it, `harnessMagic.surgery.refetched`
//! counts the masked results the agent fetched again (the same path read or command run), the
//! masking-regret rate. `harnessMagic.surgery.fallbacks` counts the compaction triggers
//! (`cache_compact.rs`, `cold_wake.rs`, `auto_resume/compact_first.rs`) that tried surgery first
//! ([`Hub::surgery_before_compact`]) and sent `/compact` after all.
//!
//! Switch: `agents.harnessMagic.surgery.enabled` in the settings file, or `ACPMUX_HM_SURGERY=0`
//! in the daemon's environment; unset, it is on only under the fleet policy
//! (`crate::compaction_policy`, since 2026-11-26).
//!
//! Codex: its rollout (`~/.codex/sessions/**/rollout-*.jsonl`) keeps `function_call_output`
//! items that a copy could mask the same way, but a resumed thread rebuilds from `compacted`
//! replacement history when it has one and the thread id lives in the file name and
//! `session_meta`; not built here.

use super::*;
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

pub const SETTING_ENABLED: &str = "agents.harnessMagic.surgery.enabled";
pub const SETTING_KEEP_TURNS: &str = "agents.harnessMagic.surgery.keepTurns";
pub const SETTING_MIN_CHARS: &str = "agents.harnessMagic.surgery.minChars";
/// The kill switch: `0` (or `false`, `off`) turns the feature off whatever the settings say.
pub const KILL_ENV: &str = "ACPMUX_HM_SURGERY";
/// The person prompts whose tool output stays whole.
pub const KEEP_TURNS: usize = 3;
/// A tool result shorter than this (its content as JSON) is never masked. Claude Code already
/// moves outputs over about 30 KB to a file with a 2 KB preview, so the results this pays for
/// are the 2-30 KB reads, searches and command logs.
pub const MIN_CHARS: usize = 2048;
/// The share of the context window at which our own timer masks.
pub const TRIGGER_SHARE: f64 = 0.6;
/// The turns after a surgery whose refetches of masked results are counted.
pub const REFETCH_TURNS: u8 = 5;
/// How long after the cache's expiry the timer fires: the cache is surely cold by then.
const COLD_GRACE_MS: u64 = 5_000;
/// The stub's prefix; a result that starts with it is masked already.
const STUB_PREFIX: &str = "[masked by harness:";
/// The longest args summary a stub carries.
const ARGS_MAX: usize = 120;
const COUNTER: &str = "harnessMagic.surgery";

/// What a surgery keeps whole.
#[derive(Debug, Clone, Copy)]
pub struct MaskOptions {
    pub keep_turns: usize,
    pub min_chars: usize,
}

impl Default for MaskOptions {
    fn default() -> Self {
        Self { keep_turns: KEEP_TURNS, min_chars: MIN_CHARS }
    }
}

/// A masked copy of a transcript, before or after it is written.
#[derive(Debug, Clone, Default)]
pub struct Masked {
    /// The copy's session id.
    pub id: String,
    /// The copy's records, one JSON line each.
    pub lines: Vec<String>,
    pub masked: usize,
    /// The characters of tool output the stubs replaced (net of the stubs).
    pub chars_masked: usize,
    /// The context the last call read, from its stored `usage`.
    pub tokens_before: Option<u64>,
    /// What masked results are refetched by ([`refetch_key`]).
    pub keys: Vec<String>,
}

impl Masked {
    /// About four characters a token: the context the copy leaves.
    pub fn tokens_after(&self) -> Option<u64> {
        self.tokens_before.map(|b| b.saturating_sub((self.chars_masked / 4) as u64))
    }
}

/// Whether the feature is on: the kill switch, then the settings key; unset, on only under the
/// fleet policy (`crate::compaction_policy`; `fleet` is its environment value).
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>, fleet: Option<&str>) -> bool {
    if env.is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off"))
    {
        return false;
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED))
        .and_then(|v| v.as_bool())
        .unwrap_or_else(|| crate::compaction_policy::fleet_with(doc, |_| fleet.map(str::to_owned)))
}

fn settings_doc() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    }
}

pub(crate) fn enabled() -> bool {
    let fleet = std::env::var(crate::compaction_policy::ENV_FLEET).ok();
    enabled_with(settings_doc().as_ref(), std::env::var(KILL_ENV).ok().as_deref(), fleet.as_deref())
}

/// The options the settings name, else the defaults.
pub(crate) fn options_with(doc: Option<&Value>) -> MaskOptions {
    let get = |key: &str| doc.and_then(|d| crate::user_settings::value(d, key));
    let n = |key: &str, default: usize, range: (u64, u64)| {
        get(key).and_then(|v| v.as_u64()).map_or(default, |v| v.clamp(range.0, range.1) as usize)
    };
    MaskOptions {
        keep_turns: n(SETTING_KEEP_TURNS, KEEP_TURNS, (1, 50)),
        min_chars: n(SETTING_MIN_CHARS, MIN_CHARS, (256, 1_000_000)),
    }
}

fn is_prompt(record: &Value) -> bool {
    let flag = |key: &str| record.get(key).and_then(Value::as_bool).unwrap_or(false);
    if record.get("type").and_then(Value::as_str) != Some("user")
        || flag("isMeta")
        || flag("isSidechain")
        || flag("isCompactSummary")
    {
        return false;
    }
    match record.pointer("/message/content") {
        Some(Value::String(_)) => true,
        Some(Value::Array(blocks)) => {
            !blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
        }
        _ => false,
    }
}

fn is_boundary(record: &Value) -> bool {
    record.get("type").and_then(Value::as_str) == Some("system")
        && record.get("subtype").and_then(Value::as_str) == Some("compact_boundary")
}

/// What a refetch of a tool call with `input` would repeat: the file it read, the command it
/// ran, the search it made, the page it fetched.
pub(crate) fn refetch_key(input: &Value) -> Option<String> {
    let s = |k: &str| input.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    if let Some(path) = s("file_path").or_else(|| s("notebook_path")) {
        return Some(format!("path:{path}"));
    }
    if let Some(cmd) = s("command") {
        return Some(format!("cmd:{}", cmd.trim()));
    }
    if let Some(url) = s("url") {
        return Some(format!("url:{url}"));
    }
    if let Some(pattern) = s("pattern") {
        return Some(format!("search:{pattern}@{}", s("path").unwrap_or(".")));
    }
    None
}

/// A short, one-line account of a tool call's input for its stub.
fn args_summary(input: &Value) -> String {
    let s = |k: &str| input.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    let text = s("file_path")
        .or_else(|| s("notebook_path"))
        .or_else(|| s("command"))
        .or_else(|| s("url"))
        .map(str::to_owned)
        .or_else(|| s("pattern").map(|p| format!("{p} in {}", s("path").unwrap_or("."))))
        .or_else(|| input.as_object()?.values().find_map(|v| v.as_str().map(str::to_owned)))
        .unwrap_or_default();
    let line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > ARGS_MAX {
        format!("{}...", line.chars().take(ARGS_MAX).collect::<String>())
    } else {
        line
    }
}

pub(crate) fn stub(tool: &str, input: Option<&Value>, chars: usize) -> String {
    let args = input.map(args_summary).unwrap_or_default();
    let call = if args.is_empty() { tool.to_owned() } else { format!("{tool} {args}") };
    format!(
        "{STUB_PREFIX} {call}, {chars} chars; you saw it in full then; removed since to save context, re-run or Read to see it again]"
    )
}

fn content_chars(content: &Value) -> usize {
    match content {
        Value::String(s) => s.len(),
        other => serde_json::to_string(other).map_or(0, |s| s.len()),
    }
}

fn already_masked(content: &Value) -> bool {
    content.as_str().is_some_and(|s| s.starts_with(STUB_PREFIX))
}

/// The context the call that wrote assistant record `record` read and wrote.
fn context_of(record: &Value) -> Option<u64> {
    let usage = record.pointer("/message/usage")?;
    let n = |k: &str| usage.get(k).and_then(Value::as_u64).unwrap_or(0);
    let total = n("input_tokens")
        + n("cache_read_input_tokens")
        + n("cache_creation_input_tokens")
        + n("output_tokens");
    (total > 0).then_some(total)
}

/// The masked copy of transcript `file` (module docs), not written yet. None: nothing to mask.
/// An error: the transcript is not one to rewrite (a line that does not parse, a tool call with
/// no result, no record that names the session).
pub fn mask_claude(file: &Path, opts: MaskOptions) -> anyhow::Result<Option<Masked>> {
    let mut records = Vec::new();
    for line in BufReader::new(std::fs::File::open(file)?).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        records.push(serde_json::from_str::<Value>(&line)?);
    }
    mask_records(records, opts)
}

pub(crate) fn mask_records(
    mut records: Vec<Value>,
    opts: MaskOptions,
) -> anyhow::Result<Option<Masked>> {
    let start = records.iter().rposition(is_boundary).map_or(0, |i| i + 1);
    // Tool calls by id, and any without a result (a turn still running: never cut).
    let mut calls: HashMap<String, (String, Value)> = HashMap::new();
    let mut open: HashSet<String> = HashSet::new();
    let mut tokens_before = None;
    let mut named = false;
    for record in records.iter().skip(start) {
        named |= record.get("sessionId").is_some_and(Value::is_string);
        let sidechain = record.get("isSidechain").and_then(Value::as_bool) == Some(true);
        if record.get("type").and_then(Value::as_str) == Some("assistant") && !sidechain {
            tokens_before = context_of(record).or(tokens_before);
        }
        let Some(Value::Array(blocks)) = record.pointer("/message/content") else { continue };
        for b in blocks {
            match b.get("type").and_then(Value::as_str) {
                Some("tool_use") => {
                    if let Some(id) = b.get("id").and_then(Value::as_str) {
                        let name = b.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = b.get("input").cloned().unwrap_or(Value::Null);
                        calls.insert(id.to_owned(), (name.to_owned(), input));
                        if !sidechain {
                            open.insert(id.to_owned());
                        }
                    }
                }
                Some("tool_result") => {
                    if let Some(id) = b.get("tool_use_id").and_then(Value::as_str) {
                        open.remove(id);
                    }
                }
                _ => {}
            }
        }
    }
    anyhow::ensure!(named, "no record names the session");
    anyhow::ensure!(open.is_empty(), "a tool call has no result yet: the turn is not over");
    let prompts: Vec<usize> = records
        .iter()
        .enumerate()
        .skip(start)
        .filter(|(_, r)| is_prompt(r))
        .map(|(i, _)| i)
        .collect();
    let Some(&cutoff) =
        prompts.len().checked_sub(opts.keep_turns).filter(|&k| k > 0).and_then(|k| prompts.get(k))
    else {
        return Ok(None);
    };
    let id = uuid::Uuid::now_v7().to_string();
    let mut out = Masked { id: id.clone(), tokens_before, ..Masked::default() };
    for (i, record) in records.iter_mut().enumerate() {
        if i >= start && i < cutoff && mask_record(record, &calls, opts.min_chars, &mut out) {
            // The copy's view of the result: Claude Code renders it from `toolUseResult` on a
            // resume; the model reads `message.content`.
            if let Some(stub) = record.get("toolUseResult").map(|_| {
                record
                    .pointer("/message/content/0/content")
                    .and_then(Value::as_str)
                    .unwrap_or(STUB_PREFIX)
                    .to_owned()
            }) {
                record["toolUseResult"] = Value::String(stub);
            }
        }
        if record.get("sessionId").is_some_and(Value::is_string) {
            record["sessionId"] = Value::String(id.clone());
        }
        out.lines.push(serde_json::to_string(record)?);
    }
    Ok((out.masked > 0).then_some(out))
}

/// Masks the large tool results of one `user` record; whether it masked one.
fn mask_record(
    record: &mut Value,
    calls: &HashMap<String, (String, Value)>,
    min_chars: usize,
    out: &mut Masked,
) -> bool {
    if record.get("type").and_then(Value::as_str) != Some("user")
        || record.get("isSidechain").and_then(Value::as_bool) == Some(true)
    {
        return false;
    }
    let Some(Value::Array(blocks)) = record.pointer_mut("/message/content") else { return false };
    let mut any = false;
    for b in blocks.iter_mut() {
        if b.get("type").and_then(Value::as_str) != Some("tool_result") {
            continue;
        }
        let Some(content) = b.get("content") else { continue };
        let chars = content_chars(content);
        if chars < min_chars || already_masked(content) {
            continue;
        }
        let call = b.get("tool_use_id").and_then(Value::as_str).and_then(|id| calls.get(id));
        let text = stub(call.map_or("tool", |(n, _)| n.as_str()), call.map(|(_, i)| i), chars);
        out.chars_masked += chars.saturating_sub(text.len());
        out.masked += 1;
        if let Some(key) = call.and_then(|(_, input)| refetch_key(input)) {
            out.keys.push(key);
        }
        b["content"] = Value::String(text);
        any = true;
    }
    any
}

/// Writes `masked` beside `original` as `<id>.jsonl`, never over a file.
pub fn write_beside(original: &Path, masked: &Masked) -> anyhow::Result<std::path::PathBuf> {
    let path = original.with_file_name(format!("{}.jsonl", masked.id));
    let mut file =
        crate::home_fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
    for line in &masked.lines {
        writeln!(file, "{line}")?;
    }
    file.sync_all()?;
    Ok(path)
}

/// One session's surgery counters, waiting for its next `turn_result`, and the refetch watch.
#[derive(Debug, Default)]
struct Track {
    runs: u64,
    tokens_before: u64,
    tokens_after: u64,
    masked: u64,
    keys: HashSet<String>,
    counted: HashSet<String>,
    turns_left: u8,
    refetched: u64,
    fallbacks: u64,
}

static TRACKS: std::sync::LazyLock<StdMutex<HashMap<String, Track>>> =
    std::sync::LazyLock::new(Default::default);
static TIMERS: std::sync::LazyLock<StdMutex<HashMap<String, (u64, tokio::task::AbortHandle)>>> =
    std::sync::LazyLock::new(Default::default);
static GENERATION: AtomicU64 = AtomicU64::new(0);

fn tracks() -> std::sync::MutexGuard<'static, HashMap<String, Track>> {
    TRACKS.lock().unwrap_or_else(|e| e.into_inner())
}

fn note_run(session: &str, m: &Masked) {
    let mut tracks = tracks();
    let t = tracks.entry(session.to_owned()).or_default();
    t.runs += 1;
    t.tokens_before += m.tokens_before.unwrap_or(0);
    t.tokens_after += m.tokens_after().unwrap_or(0);
    t.masked += m.masked as u64;
    t.keys.extend(m.keys.iter().cloned());
    t.turns_left = REFETCH_TURNS;
}

/// A compaction trigger of `session` tried surgery first and sent `/compact` after all.
pub(crate) fn note_fallback(session: &str) {
    tracks().entry(session.to_owned()).or_default().fallbacks += 1;
}

/// A tool call of `session` with `input`: a refetch of a masked result counts once.
pub(crate) fn note_tool_input(session: &str, input: &Value) {
    let Some(key) = refetch_key(input) else { return };
    let mut tracks = tracks();
    let Some(t) = tracks.get_mut(session).filter(|t| t.turns_left > 0) else { return };
    if t.keys.contains(&key) && t.counted.insert(key) {
        t.refetched += 1;
    }
}

/// The counters a `turn_result` of `session` carries; one turn of the refetch watch ends.
pub(crate) fn turn_fields(session: &str) -> serde_json::Map<String, Value> {
    let mut fields = serde_json::Map::new();
    let mut tracks = tracks();
    let Some(t) = tracks.get_mut(session) else { return fields };
    let key = |name: &str| format!("{COUNTER}.{name}");
    if t.runs > 0 {
        fields.insert(key("runs"), json!(t.runs));
        fields.insert(key("tokensBefore"), json!(t.tokens_before));
        fields.insert(key("tokensAfter"), json!(t.tokens_after));
        fields.insert(key("maskedResults"), json!(t.masked));
        fields.insert(key("tokensSaved"), json!(t.tokens_before.saturating_sub(t.tokens_after)));
        (t.runs, t.tokens_before, t.tokens_after, t.masked) = (0, 0, 0, 0);
    }
    if t.fallbacks > 0 {
        fields.insert(key("fallbacks"), json!(t.fallbacks));
        t.fallbacks = 0;
    }
    if t.turns_left > 0 {
        fields.insert(key("refetched"), json!(t.refetched));
        t.refetched = 0;
        t.turns_left -= 1;
    }
    if t.turns_left == 0 && t.runs == 0 {
        tracks.remove(session);
    }
    fields
}

fn refused(reason: &str) -> Value {
    json!({"applied": false, "reason": reason})
}

impl Hub {
    /// A compaction trigger's surgery first: a dry run, then the real run when masking alone
    /// takes `session` under `line` tokens. True when it applied; the caller then sends no
    /// `/compact`. False (off, not a stored Claude conversation, too little to mask, refused,
    /// failed) keeps the caller's `/compact`, counted in `harnessMagic.surgery.fallbacks` while
    /// surgery is on. `trigger` names the caller in the log.
    pub(crate) async fn surgery_before_compact(
        self: &Arc<Self>,
        session: &Arc<Session>,
        line: u64,
        trigger: &'static str,
    ) -> bool {
        if !enabled() {
            return false;
        }
        let dry = self.surgery(session, None, true).await;
        let applied = if super::cold_wake::surgery_suffices(&dry, line) {
            let answer = self.surgery(session, None, false).await;
            let applied = super::cold_wake::surgery_applied(&answer);
            tracing::info!(session = %session.id, trigger, line, applied, outcome = ?answer.as_ref().map_err(|e| &e.message), "surgery before compaction");
            applied
        } else {
            tracing::info!(session = %session.id, trigger, line, outcome = ?dry.as_ref().map_err(|e| &e.message), "surgery before compaction skipped");
            false
        };
        if !applied {
            note_fallback(&session.id);
        }
        applied
    }

    /// `_acpmux/surgery`, cold wake's choice and our own timer: mask `session`'s old tool output
    /// and resume it on the copy (module docs). `dry_run` counts what it would mask and writes
    /// nothing. Answers `{applied, ...}`; a chat it may not touch now answers `applied: false`
    /// with the reason, and keeps its transcript.
    pub async fn surgery(
        self: &Arc<Self>,
        session: &Arc<Session>,
        opts: Option<MaskOptions>,
        dry_run: bool,
    ) -> Result<Value, RpcError> {
        if !enabled() {
            return Ok(refused("off"));
        }
        if self.shutting_down() {
            return Err(super::shutdown::shutting_down_error());
        }
        let opts = opts.unwrap_or_else(|| options_with(settings_doc().as_ref()));
        let meta = session.meta();
        let (is_claude, env) = self.harness_env(&meta).await;
        let sid = meta.agent_session_id.clone().filter(|s| crate::adopt::is_bare_id(s));
        let (true, Some(sid)) =
            (is_claude && meta.agent_session_family.as_deref().is_none_or(|f| f == "claude"), sid)
        else {
            return Ok(refused("not a stored Claude conversation"));
        };
        // Between turns only: the turn lock held through it, so no turn starts meanwhile, and
        // nothing open that ending the harness would cut.
        let idle = session.turn().is_none()
            && session.pending_permissions().is_empty()
            && !self.holds_work_below(session);
        let Some(_turn) = idle.then(|| session.turn_lock.try_lock().ok()).flatten() else {
            return Ok(refused("mid-turn"));
        };
        let Some(file) =
            crate::adopt::find_claude(&self.harness_homes().with_env(&[&env]).claude, &sid)
        else {
            return Ok(refused("no transcript"));
        };
        // A look first, writing nothing: a chat with nothing to mask keeps its harness running.
        let look = file.clone();
        let found = tokio::task::spawn_blocking(move || mask_claude(&look, opts))
            .await
            .map_err(anyhow::Error::from)
            .and_then(|r| r);
        let m = match found {
            Ok(Some(m)) => m,
            Ok(None) => return Ok(refused("nothing to mask")),
            Err(e) => return Ok(refused(&e.to_string())),
        };
        if dry_run {
            return Ok(
                json!({"applied": false, "dryRun": true, "maskedResults": m.masked, "charsMasked": m.chars_masked, "tokensBefore": m.tokens_before, "tokensAfter": m.tokens_after()}),
            );
        }
        // The harness ends first, so nothing it still writes is lost from the copy; with no
        // copy it starts again on the original, as after an idle hibernation.
        let had_child = session.child.lock().await.is_some();
        if had_child {
            self.detach_child(session).await;
        }
        let read = file.clone();
        let made = tokio::task::spawn_blocking(move || -> anyhow::Result<Option<(Masked, _)>> {
            let Some(m) = mask_claude(&read, opts)? else { return Ok(None) };
            let path = write_beside(&read, &m)?;
            Ok(Some((m, path)))
        })
        .await
        .map_err(anyhow::Error::from)
        .and_then(|r| r);
        let (masked, path) = match made {
            Ok(Some(made)) => made,
            outcome => {
                let reason = match outcome {
                    Err(e) => e.to_string(),
                    _ => "nothing to mask".to_owned(),
                };
                if had_child {
                    let _ = self.child_for(session).await;
                }
                return Ok(refused(&reason));
            }
        };
        self.surgery_switch(session, Some(masked.id.clone()), &sid);
        if had_child && let Err(e) = self.child_for(session).await {
            // Fail open: back on the original conversation.
            tracing::warn!(session = %session.id, error = %e.message, "surgery: the masked copy did not start; back on the original");
            self.surgery_switch(session, Some(sid.clone()), &masked.id);
            let _ = self.child_for(session).await;
            return Ok(refused(&format!("resume failed: {}", e.message)));
        }
        note_run(&session.id, &masked);
        let report = json!({
            "applied": true,
            "agentSessionId": masked.id,
            "previousAgentSessionId": sid,
            "original": file.display().to_string(),
            "masked": path.display().to_string(),
            "maskedResults": masked.masked,
            "charsMasked": masked.chars_masked,
            "tokensBefore": masked.tokens_before,
            "tokensAfter": masked.tokens_after(),
            "keepTurns": opts.keep_turns,
            "minChars": opts.min_chars,
        });
        self.append(session, "mux", "harness_surgery", report.clone());
        tracing::info!(session = %session.id, masked = masked.masked, chars = masked.chars_masked, "surgery: masked old tool output");
        Ok(report)
    }

    /// Moves `session`'s native id to `to`, keeping `from` out of its transcript history when it
    /// is a copy given up (a failed resume).
    fn surgery_switch(&self, session: &Session, to: Option<String>, from: &str) {
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let back = m.previous_agent_session_ids.iter().any(|id| Some(id) == to.as_ref());
            m.set_agent_session_id(to, "claude");
            if back {
                m.previous_agent_session_ids.retain(|id| id != from);
            }
        }
        self.save_meta(session);
    }

    /// A live `usage_update` of `session` (`permissions.rs`, beside `on_update_cache`): arms our
    /// own timer when the context is at [`TRIGGER_SHARE`] or more and the cache has an expiry;
    /// any other update of it, and a completed compaction, ends the armed one.
    pub(in crate::hub) fn surgery_on_update(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Option<&Value>,
        replayed: bool,
    ) {
        let Some(update) = params.and_then(|p| p.get("update")).filter(|_| !replayed) else {
            return;
        };
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        let compacted = kind == Some("compaction")
            && update.get("state").and_then(Value::as_str) == Some("completed");
        if kind != Some("usage_update") && !compacted {
            return;
        }
        let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((_, timer)) = timers.remove(&session.id) {
            timer.abort();
        }
        if compacted {
            return;
        }
        let now = now_ms();
        let Some(wait) = trigger_wait_ms(update, now) else { return };
        if !enabled() {
            return;
        }
        let deadline = self.clock_now().saturating_add(wait.saturating_mul(1_000_000));
        let clock = self.clock.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let generation = GENERATION.fetch_add(1, Ordering::SeqCst);
        let (hub, weak, id) = (Arc::downgrade(self), Arc::downgrade(session), session.id.clone());
        let task = self.scope.spawn_named("surgery-timer", async move {
            clock.sleep_until(std::time::Duration::from_nanos(deadline)).await;
            let own = {
                let mut timers = TIMERS.lock().unwrap_or_else(|e| e.into_inner());
                let own = timers.get(&id).is_some_and(|(g, _)| *g == generation);
                if own {
                    timers.remove(&id);
                }
                own
            };
            let (true, Some(hub), Some(session)) = (own, hub.upgrade(), weak.upgrade()) else {
                return;
            };
            // Still idle: a later turn's usage would have replaced this timer, and the
            // surgery itself refuses a chat mid-turn.
            if !hub.idle_eligible(&session) {
                return;
            }
            match hub.surgery(&session, None, false).await {
                Ok(v) => tracing::debug!(session = %session.id, outcome = %v, "surgery timer"),
                Err(e) => {
                    tracing::info!(session = %session.id, error = %e.message, "surgery timer")
                }
            }
        });
        timers.insert(session.id.clone(), (generation, task.abort_handle()));
    }

    /// A tool call update of `session` (`stalled_turn.rs`): its input, for the refetch count.
    pub(in crate::hub) fn surgery_note_tool(&self, session: &Session, update: &Value) {
        if let Some(input) = update.get("rawInput").filter(|v| v.is_object()) {
            note_tool_input(&session.id, input);
        }
    }
}

/// How long from `now_ms` until our timer masks after usage `update`: just after its cache's
/// expiry, when the context is at [`TRIGGER_SHARE`] of its window or more. None: no timer.
pub(crate) fn trigger_wait_ms(update: &Value, now_ms: u64) -> Option<u64> {
    let expires = update.pointer("/_meta/acpmux/cacheExpiresAt").and_then(Value::as_u64)?;
    let used = update.get("used").and_then(Value::as_u64)?;
    let size = update.get("size").and_then(Value::as_u64).filter(|s| *s > 0)?;
    if (used as f64 / size as f64) < TRIGGER_SHARE {
        return None;
    }
    Some(expires.saturating_add(COLD_GRACE_MS).saturating_sub(now_ms).max(1))
}

#[cfg(test)]
#[path = "surgery_tests.rs"]
mod tests;

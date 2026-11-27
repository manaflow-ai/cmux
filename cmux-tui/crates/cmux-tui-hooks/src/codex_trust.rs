//! Codex hook trust state: the `hooks.state` trusted-hash entries cmux writes
//! into `$CODEX_HOME/config.toml` beside hooks.json so codex runs cmux's hooks,
//! and the locked, preflighted, rollback-safe write of that file.

use super::*;

/// codex 0.150 executes an unmanaged hooks.json handler only when the user
/// config layer carries `hooks.state."<hooks.json path>:<event>:<group>:<handler>"`
/// whose `trusted_hash` equals codex's normalized-identity hash; otherwise it
/// parses the file and silently skips every handler (codex-rs/hooks/src/engine/
/// discovery.rs). The installer therefore mirrors that hash and writes the
/// trust state into `$CODEX_HOME/config.toml` alongside hooks.json.
pub(super) const CODEX_CONFIG_FILE: &str = "config.toml";

/// Hook-state event label used in codex's persisted trust keys
/// (codex-rs/hooks/src/lib.rs `hook_event_key_label`).
pub(super) fn codex_event_state_label(event: &str) -> anyhow::Result<&'static str> {
    Ok(match event {
        "PreToolUse" => "pre_tool_use",
        "PermissionRequest" => "permission_request",
        "PostToolUse" => "post_tool_use",
        "PreCompact" => "pre_compact",
        "PostCompact" => "post_compact",
        "SessionStart" => "session_start",
        "SessionEnd" => "session_end",
        "UserPromptSubmit" => "user_prompt_submit",
        "SubagentStart" => "subagent_start",
        "SubagentStop" => "subagent_stop",
        "Stop" => "stop",
        other => anyhow::bail!("codex hook event {other:?} has no trust-state label"),
    })
}

/// codex clamps SessionEnd timeouts (default 1s, cap 3s) and floors all other
/// timeouts (default 600s) before hashing, so the trusted hash must cover the
/// normalized value, not the configured one
/// (codex-rs/hooks/src/engine/discovery.rs `normalize_command_hook`).
pub(super) fn codex_normalized_timeout(state_label: &str, timeout: Option<u64>) -> u64 {
    if state_label == "session_end" {
        timeout.unwrap_or(1).clamp(1, 3)
    } else {
        timeout.unwrap_or(600).max(1)
    }
}

/// codex forces the matcher to None for events that do not support one
/// (codex-rs/hooks/src/events/common.rs `matcher_pattern_for_event`).
fn codex_normalized_matcher<'a>(state_label: &str, matcher: Option<&'a str>) -> Option<&'a str> {
    match state_label {
        "user_prompt_submit" | "stop" => None,
        _ => matcher,
    }
}

/// codex keeps `additionalContextLimit` only for events that can emit
/// additional context, and drops the explicit default before hashing
/// (codex-rs/hooks/src/engine/discovery.rs, DEFAULT_HOOK_OUTPUT_TOKEN_LIMIT
/// in codex-rs/hooks/src/output_spill.rs).
fn codex_normalized_context_limit(state_label: &str, limit: Option<u64>) -> Option<u64> {
    const DEFAULT_HOOK_OUTPUT_TOKEN_LIMIT: u64 = 2_500;
    match state_label {
        "pre_tool_use" | "post_tool_use" | "session_start" | "user_prompt_submit"
        | "subagent_start" => limit.filter(|limit| *limit != DEFAULT_HOOK_OUTPUT_TOKEN_LIMIT),
        _ => None,
    }
}

/// Reproduces codex's per-hook trust hash: sha256 over sorted-key compact JSON
/// of the normalized hook identity (codex-rs/hooks/src/engine/discovery.rs
/// `hook_hash` plus codex-rs/config/src/fingerprint.rs `version_for_toml`).
/// Absent optional fields (matcher, commandWindows, statusMessage,
/// additionalContextLimit) are omitted, exactly as codex's TOML round trip
/// omits them. Keys are inserted in sorted order to match the canonical form.
fn codex_identity_trust_hash(
    state_label: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: Option<u64>,
    asynchronous: bool,
    status_message: Option<&str>,
    additional_context_limit: Option<u64>,
) -> String {
    use sha2::Digest as _;
    let mut handler = Map::new();
    if let Some(limit) = codex_normalized_context_limit(state_label, additional_context_limit) {
        handler.insert("additionalContextLimit".into(), Value::from(limit));
    }
    handler.insert("async".into(), Value::Bool(asynchronous));
    handler.insert("command".into(), Value::String(command.into()));
    if let Some(message) = status_message {
        handler.insert("statusMessage".into(), Value::String(message.into()));
    }
    handler.insert("timeout".into(), Value::from(codex_normalized_timeout(state_label, timeout)));
    handler.insert("type".into(), Value::String("command".into()));
    let mut identity = Map::new();
    identity.insert("event_name".into(), Value::String(state_label.into()));
    identity.insert("hooks".into(), Value::Array(vec![Value::Object(handler)]));
    if let Some(matcher) = codex_normalized_matcher(state_label, matcher) {
        identity.insert("matcher".into(), Value::String(matcher.into()));
    }
    let encoded = serde_json::to_vec(&Value::Object(identity))
        .expect("codex hook identity serializes to JSON");
    format!("sha256:{:x}", sha2::Sha256::digest(encoded))
}

/// Trust hash of the canonical hook shape the installer writes.
pub(super) fn codex_trust_hash(state_label: &str, command: &str, timeout: u64) -> String {
    codex_identity_trust_hash(state_label, None, command, Some(timeout), false, None, None)
}

/// codex canonicalizes `CODEX_HOME` when the environment variable is set and
/// uses `~/.codex` verbatim otherwise (codex-rs/utils/home-dir/src/lib.rs
/// `find_codex_home`), and its trust keys embed that resolved path. Mirror the
/// resolution so the keys match what the codex process computes.
pub(super) fn codex_state_key_hooks_path(path: &Path, from_env_override: bool) -> PathBuf {
    if !from_env_override {
        return path.to_path_buf();
    }
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return path.to_path_buf();
    };
    match fs::canonicalize(parent) {
        Ok(parent) => parent.join(name),
        Err(_) => path.to_path_buf(),
    }
}

/// The cmux-owned handler as (group index, hook index, group, handler). codex
/// keys trust by BOTH positions, so a foreign entry before ours in the same
/// group shifts the key just like a preceding group does.
fn codex_owned_hook_entry<'a>(
    root: &'a Map<String, Value>,
    event: &str,
) -> Option<(usize, usize, &'a Value, &'a Value)> {
    let groups = root.get("hooks")?.get(event)?.as_array()?;
    groups.iter().enumerate().find_map(|(group_index, group)| {
        let hooks = group.get("hooks").and_then(Value::as_array)?;
        let handler_index = hooks.iter().position(|hook| {
            hook.get("command").and_then(Value::as_str).is_some_and(is_owned_command)
        })?;
        Some((group_index, handler_index, group, &hooks[handler_index]))
    })
}

#[cfg(test)]
pub(super) fn codex_owned_hook_position(
    root: &Map<String, Value>,
    event: &str,
) -> Option<(usize, usize)> {
    codex_owned_hook_entry(root, event)
        .map(|(group_index, handler_index, _, _)| (group_index, handler_index))
}

/// The trust entries codex requires for the hooks ACTUALLY present in `root`:
/// keyed by the owned handler's real position and hashed over that handler's
/// real fields. For a freshly rewritten install this equals the canonical
/// shape; for status it reflects any hand edits, so a user-modified command
/// or timeout (which codex would hash differently and skip) fails to verify.
pub(super) fn codex_expected_trust_entries(
    key_hooks_path: &Path,
    root: &Map<String, Value>,
) -> anyhow::Result<BTreeMap<String, String>> {
    let entries = codex_present_expected_trust_entries(key_hooks_path, root)?;
    for event in CODEX_EVENTS {
        if codex_owned_hook_entry(root, event).is_none() {
            anyhow::bail!("installed codex hook for {event} is missing");
        }
    }
    Ok(entries)
}

/// Trust entries for the cmux-owned hooks that are actually present in
/// `root`. Session overrides can run while an install is partially complete,
/// so unlike the strict verifier this intentionally skips missing events.
pub(super) fn codex_present_expected_trust_entries(
    key_hooks_path: &Path,
    root: &Map<String, Value>,
) -> anyhow::Result<BTreeMap<String, String>> {
    let mut entries = BTreeMap::new();
    for event in CODEX_EVENTS {
        let label = codex_event_state_label(event)?;
        let Some((group_index, handler_index, group, handler)) =
            codex_owned_hook_entry(root, event)
        else {
            continue;
        };
        let key = format!("{}:{label}:{group_index}:{handler_index}", key_hooks_path.display());
        let command = if cfg!(windows) {
            handler
                .get("commandWindows")
                .and_then(Value::as_str)
                .or_else(|| handler.get("command").and_then(Value::as_str))
        } else {
            handler.get("command").and_then(Value::as_str)
        }
        .with_context(|| format!("installed codex hook for {event} has no command"))?;
        let hash = codex_identity_trust_hash(
            label,
            group.get("matcher").and_then(Value::as_str),
            command,
            handler.get("timeout").and_then(Value::as_u64),
            handler.get("async").and_then(Value::as_bool).unwrap_or(false),
            handler.get("statusMessage").and_then(Value::as_str),
            handler.get("additionalContextLimit").and_then(Value::as_u64),
        );
        entries.insert(key, hash);
    }
    Ok(entries)
}

/// Every trust hash the current and previous installer shapes can produce. Entries carrying
/// one of these hashes are cmux-owned regardless of their positional key.
pub(super) fn codex_owned_trust_hashes() -> anyhow::Result<BTreeSet<String>> {
    CODEX_EVENTS
        .iter()
        .map(|event| {
            let label = codex_event_state_label(event)?;
            let timeout = codex_hook_timeout(event);
            Ok([
                codex_trust_hash(label, &hook_command("codex", event), timeout),
                codex_trust_hash(label, &journal_hook_command("codex", event), timeout),
                codex_trust_hash(label, &legacy_hook_command("codex", event), timeout),
                // Trust identities emitted before PreToolUse became a gate.
                codex_trust_hash(
                    label,
                    &journal_hook_command("codex", event),
                    COMMAND_HOOK_TIMEOUT_SECONDS,
                ),
                codex_trust_hash(
                    label,
                    &legacy_hook_command("codex", event),
                    COMMAND_HOOK_TIMEOUT_SECONDS,
                ),
            ])
        })
        .collect::<anyhow::Result<Vec<_>>>()
        .map(|pairs| pairs.into_iter().flatten().collect())
}

/// Dotfile managers commonly symlink `config.toml`; the atomic rename must
/// land in the link's TARGET so the link survives and codex keeps editing the
/// same file. A link that cannot be resolved is refused instead of replaced.
fn resolve_codex_config_path(config_path: PathBuf) -> anyhow::Result<PathBuf> {
    match fs::symlink_metadata(&config_path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(config_path),
        Err(error) => Err(error).with_context(|| format!("inspect {}", config_path.display())),
        Ok(metadata) if !metadata.file_type().is_symlink() => Ok(config_path),
        Ok(_) => fs::canonicalize(&config_path).with_context(|| {
            format!(
                "{} is a symlink that does not resolve; refusing to replace it",
                config_path.display()
            )
        }),
    }
}

/// The ONE way every config.toml consumer (status, preflight, commit re-read)
/// loads the file. A separate stat-then-read would race a concurrent
/// replacement with a FIFO or huge file, so this opens the file once, fstats
/// the OPENED descriptor (regular file, size cap), and does a bounded read
/// from that same descriptor. The open itself is safe: `O_NONBLOCK` is a
/// no-op for regular files and stops a FIFO open from blocking on a missing
/// writer, and a FIFO descriptor opened that way is rejected by the fstat
/// before anything reads it.
pub(super) fn read_codex_config_text(config_path: &Path) -> anyhow::Result<Option<String>> {
    let mut options = fs::File::options();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = match options.open(config_path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("open {}", config_path.display()));
        }
    };
    let metadata = file.metadata().with_context(|| format!("inspect {}", config_path.display()))?;
    anyhow::ensure!(
        metadata.is_file(),
        "{} is not a regular file; refusing to read it",
        config_path.display()
    );
    anyhow::ensure!(metadata.len() <= MAX_CONFIG_BYTES, "{} exceeds 16 MiB", config_path.display());
    let mut bytes = Vec::new();
    file.take(MAX_CONFIG_BYTES + 1)
        .read_to_end(&mut bytes)
        .with_context(|| format!("read {}", config_path.display()))?;
    anyhow::ensure!(
        bytes.len() as u64 <= MAX_CONFIG_BYTES,
        "{} exceeds 16 MiB",
        config_path.display()
    );
    Ok(Some(
        String::from_utf8(bytes)
            .with_context(|| format!("{} is not valid UTF-8", config_path.display()))?,
    ))
}

fn read_codex_config_document(
    config_path: &Path,
) -> anyhow::Result<(Option<String>, toml_edit::DocumentMut)> {
    let original = read_codex_config_text(config_path)?;
    let document = original
        .as_deref()
        .unwrap_or_default()
        .parse::<toml_edit::DocumentMut>()
        .with_context(|| format!("{} is not valid TOML", config_path.display()))?;
    Ok((original, document))
}

fn codex_state_table_mut<'a>(
    document: &'a mut toml_edit::DocumentMut,
    config_path: &Path,
    create: bool,
) -> anyhow::Result<Option<&'a mut dyn toml_edit::TableLike>> {
    let root = document.as_table_mut();
    let hooks_is_inline = match root.get("hooks") {
        Some(hooks) if hooks.as_table_like().is_none() => {
            // A scalar `hooks` key (for example `hooks = true`) makes
            // `hooks.state` unreachable for codex itself; installing over it
            // would corrupt the config, so surface it instead.
            anyhow::ensure!(
                !create,
                "hooks key in {} is not a table, so codex cannot read hook trust state; remove it and reinstall",
                config_path.display()
            );
            return Ok(None);
        }
        Some(hooks) => hooks.as_value().is_some(),
        None if create => {
            let mut table = toml_edit::Table::new();
            table.set_implicit(true);
            root.insert("hooks", toml_edit::Item::Table(table));
            false
        }
        None => return Ok(None),
    };
    let hooks = root
        .get_mut("hooks")
        .and_then(toml_edit::Item::as_table_like_mut)
        .with_context(|| format!("hooks table in {} is unusable", config_path.display()))?;
    match hooks.get("state") {
        Some(state) if state.as_table_like().is_none() => {
            anyhow::ensure!(
                !create,
                "hooks.state in {} is not a table; remove it and reinstall",
                config_path.display()
            );
            return Ok(None);
        }
        Some(_) => {}
        None if create => {
            // Match the parent's representation: a subtable dropped into an
            // inline `hooks = { ... }` must itself be an inline value, or
            // TableLike::insert silently discards it.
            let state = if hooks_is_inline {
                toml_edit::Item::Value(toml_edit::InlineTable::new().into())
            } else {
                toml_edit::Item::Table(toml_edit::Table::new())
            };
            hooks.insert("state", state);
        }
        None => return Ok(None),
    }
    hooks
        .get_mut("state")
        .and_then(toml_edit::Item::as_table_like_mut)
        .with_context(|| format!("hooks.state in {} could not be created", config_path.display()))
        .map(Some)
}

/// The validated inputs of one trust-state edit, kept alongside the rendered
/// document so the commit can re-render against fresh file content when
/// config.toml changed between the preflight and the commit.
struct CodexTrustEdit {
    config_path: PathBuf,
    key_prefix: String,
    desired: BTreeMap<String, String>,
    /// Positional keys of the cmux-owned hooks in hooks.json BEFORE this
    /// operation rewrote it. These entries are deleted regardless of their
    /// hash value: codex persists a NEW hash when a user reviews and accepts
    /// a modified cmux hook, so hash matching alone would leave that entry
    /// behind to pollute a later hook at the same positional key.
    removal_keys: BTreeSet<String>,
    owned_hashes: BTreeSet<String>,
    install: bool,
}

/// Positional trust keys of every cmux-owned handler occurrence in `root`.
pub(super) fn codex_owned_entry_keys(
    key_hooks_path: &Path,
    root: &Map<String, Value>,
) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object) else {
        return keys;
    };
    for (event, groups) in hooks {
        let Ok(label) = codex_event_state_label(event) else {
            continue;
        };
        let Some(groups) = groups.as_array() else {
            continue;
        };
        for (group_index, group) in groups.iter().enumerate() {
            let Some(handlers) = group.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            for (handler_index, handler) in handlers.iter().enumerate() {
                if handler.get("command").and_then(Value::as_str).is_some_and(is_owned_command) {
                    keys.insert(format!(
                        "{}:{label}:{group_index}:{handler_index}",
                        key_hooks_path.display()
                    ));
                }
            }
        }
    }
    keys
}

/// A fully validated, pre-rendered config.toml trust-state write. Producing
/// one performs every step that can fail for content reasons (read, parse,
/// shape validation, rendering, target-directory writability), so the caller
/// can sequence it BEFORE mutating hooks.json and commit it afterwards.
pub(super) struct PreparedCodexTrustWrite {
    edit: CodexTrustEdit,
    /// `config.toml.cmux-lock` beside the unresolved config.toml (see
    /// `lock_codex_config`).
    lock_path: PathBuf,
    original: Option<String>,
    updated: String,
    mode: u32,
}

/// Reads the config and renders the trust edit against its current content,
/// preserving unrelated keys, comments, and formatting. Returns the file's
/// current text plus the rendered replacement, or `None` when the current
/// content already satisfies the edit.
fn render_codex_trust_document(
    edit: &CodexTrustEdit,
) -> anyhow::Result<(Option<String>, Option<String>)> {
    let (original, mut document) = read_codex_config_document(&edit.config_path)?;

    if let Some(state) = codex_state_table_mut(&mut document, &edit.config_path, edit.install)? {
        let stale: Vec<String> = state
            .iter()
            .filter(|(key, entry)| {
                // Primary removal follows the hooks this operation removes
                // from hooks.json: their exact positional keys are deleted
                // regardless of hash, covering entries codex re-trusted after
                // a user edit. The canonical-hash sweep stays as secondary
                // cleanup for orphaned keys from prior layouts.
                key.starts_with(&edit.key_prefix)
                    && !edit.desired.contains_key(*key)
                    && (edit.removal_keys.contains(*key)
                        || entry
                            .as_table_like()
                            .and_then(|entry| entry.get("trusted_hash"))
                            .and_then(toml_edit::Item::as_str)
                            .is_some_and(|hash| edit.owned_hashes.contains(hash)))
            })
            .map(|(key, _)| key.to_string())
            .collect();
        for key in stale {
            state.remove(&key);
        }
        for (key, hash) in &edit.desired {
            match state.get_mut(key).and_then(toml_edit::Item::as_table_like_mut) {
                Some(entry) => {
                    entry.insert("trusted_hash", toml_edit::value(hash.clone()));
                }
                None => {
                    let mut entry = toml_edit::InlineTable::new();
                    entry.insert("trusted_hash", toml_edit::Value::from(hash.clone()));
                    state.insert(key, toml_edit::Item::Value(entry.into()));
                }
            }
        }
        // Uninstall NEVER removes tables, only the trust entries whose hashes
        // prove cmux ownership. Empty-and-undecorated cannot distinguish an
        // installer-created table from a user-created placeholder across
        // processes, so an empty [hooks]/[hooks.state] skeleton is left
        // behind instead of guessing; it is harmless to codex.
    }

    let updated = document.to_string();
    if Some(updated.as_str()) == original.as_deref() || (original.is_none() && updated.is_empty()) {
        return Ok((original, None));
    }
    Ok((original, Some(updated)))
}

/// Preflights the cmux-owned `hooks.state` trust-entry edit of the codex user
/// config next to `hooks_path`. Returns `None` when the config already
/// matches.
pub(super) fn prepare_codex_trust_state(
    hooks_path: &Path,
    from_env_override: bool,
    root: &Map<String, Value>,
    previous_root: &Map<String, Value>,
    install: bool,
) -> anyhow::Result<Option<PreparedCodexTrustWrite>> {
    let parent = hooks_path.parent().context("codex hooks path has no parent")?;
    // Resolve a symlinked config.toml to its target so the later atomic
    // rename edits the real file instead of detaching the link.
    let config_path = resolve_codex_config_path(parent.join(CODEX_CONFIG_FILE))?;
    let key_hooks_path = codex_state_key_hooks_path(hooks_path, from_env_override);
    let desired = if install {
        codex_expected_trust_entries(&key_hooks_path, root)?
    } else {
        BTreeMap::new()
    };
    if !install && !config_path.exists() {
        return Ok(None);
    }
    let edit = CodexTrustEdit {
        key_prefix: format!("{}:", key_hooks_path.display()),
        removal_keys: codex_owned_entry_keys(&key_hooks_path, previous_root),
        owned_hashes: codex_owned_trust_hashes()?,
        config_path,
        desired,
        install,
    };
    let (original, updated) = render_codex_trust_document(&edit)?;
    let Some(updated) = updated else {
        return Ok(None);
    };
    // Probe where the rename will actually land: the resolved target's
    // directory, not necessarily the codex home.
    let target_parent =
        edit.config_path.parent().context("codex config path has no parent")?.to_path_buf();
    ensure_writable_directory(&target_parent)?;
    Ok(Some(PreparedCodexTrustWrite {
        lock_path: parent.join(CODEX_CONFIG_LOCK_FILE),
        mode: existing_file_mode(&edit.config_path).unwrap_or(0o600),
        edit,
        original,
        updated,
    }))
}

pub(super) fn commit_codex_trust_state(write: &PreparedCodexTrustWrite) -> anyhow::Result<()> {
    // The re-read, compare and rename below run under the lock every other
    // cmux writer of this config.toml takes, so neither write is built on a
    // read the other one replaced. Released when `_lock` drops.
    let _lock = lock_codex_config(&write.lock_path);
    // Close the preflight-to-commit window: if config.toml changed in between
    // (codex's own trust review or a user edit), re-render against the fresh
    // content instead of clobbering the concurrent edit with the stale
    // preflight document. A re-render failure propagates, so the caller's
    // rollback restores hooks.json.
    let current = read_codex_config_text(&write.edit.config_path)?;
    if current == write.original {
        return atomic_write(&write.edit.config_path, write.updated.as_bytes(), Some(write.mode));
    }
    match render_codex_trust_document(&write.edit)? {
        (_, Some(updated)) => {
            let mode = existing_file_mode(&write.edit.config_path).unwrap_or(0o600);
            atomic_write(&write.edit.config_path, updated.as_bytes(), Some(mode))
        }
        // The concurrent edit already satisfies the trust entries.
        (_, None) => Ok(()),
    }
}

/// The lock every cmux writer of a codex config.toml takes for its read-modify-rename
/// (`cmux_tui_platform::codex_config_lock`): this installer, `acpmux desktop link` and the Cloud
/// devbox shell-start merge.
const CODEX_CONFIG_LOCK_FILE: &str = cmux_tui_platform::codex_config_lock::LOCK_FILE;

use cmux_tui_platform::codex_config_lock::lock as lock_codex_config;

/// Captures a file's rollback snapshot (bytes and mode) before mutation.
/// Only a genuine NotFound maps to None; any other read error fails the whole
/// operation up front, because rolling back against a false None would delete
/// a pre-existing file as if it had been absent.
pub(super) fn snapshot_file(path: &Path) -> anyhow::Result<Option<(Vec<u8>, u32)>> {
    match fs::read(path) {
        Ok(bytes) => {
            let mode = existing_file_mode(path).unwrap_or(0o600);
            Ok(Some((bytes, mode)))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => {
            Err(error).with_context(|| format!("snapshot {} for rollback", path.display()))
        }
    }
}

/// Restores hooks.json to its pre-operation content (or absence) after a
/// failed trust-state commit, so a config.toml write failure cannot leave a
/// half-applied install or uninstall behind.
fn restore_hooks_file(path: &Path, previous: Option<(Vec<u8>, u32)>) -> anyhow::Result<()> {
    match previous {
        Some((bytes, mode)) => atomic_write(path, &bytes, Some(mode)),
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).with_context(|| format!("remove {}", path.display())),
        },
    }
}

/// Applies a preflighted trust write after hooks.json was already updated,
/// rolling hooks.json back (best effort) if the commit itself still fails.
pub(super) fn commit_codex_trust_state_or_rollback(
    write: &PreparedCodexTrustWrite,
    hooks_path: &Path,
    previous_hooks: Option<Option<(Vec<u8>, u32)>>,
) -> anyhow::Result<()> {
    let Err(commit_error) = commit_codex_trust_state(write) else {
        return Ok(());
    };
    if let Some(previous) = previous_hooks
        && let Err(rollback_error) = restore_hooks_file(hooks_path, previous)
    {
        return Err(commit_error.context(format!(
            "additionally, restoring {} failed: {rollback_error:#}",
            hooks_path.display()
        )));
    }
    Err(commit_error)
}

/// Verifies the directory accepts new files before any mutation happens, so
/// preflight failures surface while both target files are still untouched.
fn ensure_writable_directory(parent: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    let mut random = [0_u8; 8];
    getrandom::fill(&mut random).context("allocate preflight file identity")?;
    let suffix = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let probe = parent.join(format!(".cmux-tui-preflight-{suffix}"));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .with_context(|| format!("preflight write access to {}", parent.display()))?;
    fs::remove_file(&probe).with_context(|| format!("remove {}", probe.display()))?;
    Ok(())
}

fn existing_file_mode(path: &Path) -> Option<u32> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::metadata(path).ok().map(|metadata| metadata.permissions().mode() & 0o777)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Whether every installed codex hook is trusted by the sibling config.toml.
/// Read-only; parse failures and absent files report as unverified.
pub(super) fn codex_trust_state_verified(
    hooks_path: &Path,
    from_env_override: bool,
    root: &Map<String, Value>,
) -> bool {
    let Some(parent) = hooks_path.parent() else {
        return false;
    };
    let key_hooks_path = codex_state_key_hooks_path(hooks_path, from_env_override);
    let Ok(expected) = codex_expected_trust_entries(&key_hooks_path, root) else {
        return false;
    };
    let config_path = parent.join(CODEX_CONFIG_FILE);
    // The shared open-once/fstat/bounded-read helper, so status can never be
    // stalled by a FIFO or oversized file, even one swapped in concurrently.
    let Ok(Some(text)) = read_codex_config_text(&config_path) else {
        return false;
    };
    let Ok(config) = text.parse::<toml_edit::DocumentMut>() else {
        return false;
    };
    let Some(state) = config
        .as_table()
        .get("hooks")
        .and_then(toml_edit::Item::as_table_like)
        .and_then(|hooks| hooks.get("state"))
        .and_then(toml_edit::Item::as_table_like)
    else {
        return false;
    };
    expected.iter().all(|(key, hash)| {
        state
            .get(key)
            .and_then(toml_edit::Item::as_table_like)
            .and_then(|entry| entry.get("trusted_hash"))
            .and_then(toml_edit::Item::as_str)
            == Some(hash.as_str())
    })
}

//! Part of `Hub`; see `hub/mod.rs`. A restricted chat: Claude Code in a folder the person
//! answered "Not now" for, instead of a chat that can never run (Leo 2026-10-21: no dead
//! ends). Off unless the cmux setting `agents.trust.restrictedChats` is on; with it off the
//! trust gate refuses such a folder's prompts as before (`server/trust_gate.rs`).
//!
//! Only Claude Code as acpmux runs it (`HarnessKind::ClaudeStdio`) runs restricted, because
//! acpmux builds its whole command line; the app's pane only (never a Web client, a peer or a
//! preset's chat). Every other harness keeps the refusal: acpmux has no reviewed way to keep
//! the folder's own config out of it.
//!
//! What a restricted chat is:
//! - Claude Code reads the person's own settings only (`--setting-sources user`): the folder's
//!   `.claude/settings*.json` (its hooks, env, `apiKeyHelper`, permissions, plugins) never load.
//!   No MCP server starts (`--strict-mcp-config` with an empty `--mcp-config`, which also leaves
//!   out cmux's own tools, `agent_tools::left_out`), and no skill or slash command
//!   (`--disable-slash-commands`).
//! - Every acting tool asks (inline `--settings`: `remote_sandbox::ask_every_tool`, whose ask
//!   rules beat the person's own allow rules), bypass mode is disabled, Bash never runs
//!   unasked inside Claude's own sandbox, and the process is never given
//!   `--allow-dangerously-skip-permissions`. It runs in Normal or Plan only (`MODES`).
//! - A profile argv that already shapes any of that is refused (`remote_sandbox::refused_arg`).
//!   The program is one of Claude Code's own launchers (`LAUNCHERS`), never an interpreter that
//!   would load a script, module or preload from the folder; it is looked up on the absolute
//!   folders of PATH and never inside the chat's folder, and no argument or env value of the
//!   profile's names a path there (`ZDOTDIR=.` would have a zsh launcher source the folder's
//!   `.zshenv`). Env that makes an interpreter or shell load code starts blank (`BLANKED_ENV`).
//! - git, which Claude Code runs in the folder, gets `core.fsmonitor=false` and
//!   `core.hooksPath=/dev/null` through `GIT_CONFIG_COUNT` (other git config in the folder,
//!   such as a filter driver, still applies: see the PR's risks).
//! - Nothing widens it: the policy is `ask`, and a request that would let anything run without
//!   asking is refused (`refuse_widening`, `Hub::set_mode`); the remote floor holds every
//!   permission request to a person (`remote_floor.rs` `web_turn`). It never takes a pooled
//!   agent (`pool/`), and a pooled one is never started for its folder.
//!
//! A fork, a side chat, a handoff target and a sub-session of a restricted chat are restricted
//! too. Trusting the folder later (`acp.trust.set`) ends a restricted chat's agent once it is
//! idle, so its next prompt starts Claude Code without the restrictions; a chat busy then lifts
//! at its next prompt (`server/trust_gate.rs`).

use super::*;

use crate::config::HarnessKind;
use crate::user_settings::{self, Settings};
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};

/// The cmux setting that turns restricted chats on (`schemas/settings/source/trust.json`).
pub const SETTING: &str = "agents.trust.restrictedChats";

/// The shared settings source the default comes from.
const CATALOG_SOURCE: &str = include_str!("../../../../../schemas/settings/source/trust.json");

/// The Claude Code modes a restricted chat runs in, its start mode first: both ask before
/// acting (`web_modes::ASKING_MODES`).
pub(crate) const MODES: &[&str] = &["default", "plan"];

/// The empty MCP server list a restricted Claude Code starts with.
const NO_MCP_SERVERS: &str = r#"{"mcpServers":{}}"#;

/// What a restricted chat's git gets in its env (`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`).
const GIT_CONFIG: &[(&str, &str)] = &[("core.fsmonitor", "false"), ("core.hooksPath", "/dev/null")];

/// Whether the setting is on now: the settings file over the catalog default (off). A file
/// that cannot be read, and a value that is not a boolean, are off: the folder keeps refusing.
pub fn enabled() -> bool {
    match user_settings::read() {
        Settings::Missing => catalog_default(),
        Settings::Unreadable(_) => false,
        Settings::Parsed(doc) => enabled_in(&doc),
    }
}

/// `enabled` for one settings document.
pub(crate) fn enabled_in(doc: &Value) -> bool {
    match user_settings::value(doc, SETTING) {
        None => catalog_default(),
        Some(value) => value.as_bool().unwrap_or(false),
    }
}

fn catalog_default() -> bool {
    static DEFAULT: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *DEFAULT.get_or_init(|| {
        let doc: Value = serde_json::from_str(CATALOG_SOURCE).unwrap_or(Value::Null);
        doc["lists"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|list| list["rows"].as_array().into_iter().flatten())
            .find(|row| row["key"] == SETTING)
            .and_then(|row| row["default"].as_bool())
            .unwrap_or(false)
    })
}

/// Whether a chat of `profile` can run restricted: Claude Code as acpmux runs it.
pub(crate) fn supports(profile: &HarnessProfile) -> bool {
    profile.kind == HarnessKind::ClaudeStdio
}

/// Whether a restricted chat can start on `profile`: Claude Code through one of its launchers,
/// whose argv shapes none of the restricted command line (`restricted_plan` refuses the rest at
/// spawn).
pub(crate) fn starts_restricted(profile: &HarnessProfile) -> bool {
    supports(profile)
        && profile.argv.first().is_some_and(|p| launcher(p).is_ok())
        && super::remote_sandbox::refused_arg(&profile.argv).is_none()
}

/// `mode` as a restricted chat runs it: an asking mode, else Claude Code's default.
pub(crate) fn asking_mode(mode: String) -> String {
    if MODES.contains(&mode.as_str()) { mode } else { MODES[0].to_owned() }
}

/// The inline `--settings` of a restricted Claude Code: every acting tool asks, bypass mode is
/// off, and Bash in Claude's own sandbox asks too.
pub(crate) fn claude_settings() -> String {
    json!({
        "sandbox": {"autoAllowBashIfSandboxed": false},
        "permissions": super::remote_sandbox::ask_every_tool(),
        "enableAllProjectMcpServers": false,
    })
    .to_string()
}

/// The restricted command line from `plan` (`claude_stdio::spawn_plan`'s) for a profile whose
/// spawn argv is `argv`: refused when that argv already shapes it.
pub(crate) fn command_line(
    argv: &[String],
    mut plan: crate::claude_stdio::SpawnPlan,
) -> Result<crate::claude_stdio::SpawnPlan, String> {
    if let Some(bad) = super::remote_sandbox::refused_arg(argv) {
        return Err(format!("a restricted chat never runs Claude Code with {bad}"));
    }
    plan.args.retain(|a| a != crate::claude_stdio::ALLOW_BYPASS_FLAG);
    match plan.args.iter().position(|a| a == "--permission-mode") {
        Some(i) => match plan.args.get_mut(i + 1) {
            Some(mode) if !MODES.contains(&mode.as_str()) => *mode = MODES[0].to_owned(),
            Some(_) => {}
            None => plan.args.push(MODES[0].to_owned()),
        },
        None => plan.args.extend(["--permission-mode".to_owned(), MODES[0].to_owned()]),
    }
    plan.args.extend([
        "--setting-sources".to_owned(),
        "user".to_owned(),
        "--strict-mcp-config".to_owned(),
        "--mcp-config".to_owned(),
        NO_MCP_SERVERS.to_owned(),
        "--disable-slash-commands".to_owned(),
        "--settings".to_owned(),
        claude_settings(),
    ]);
    Ok(plan)
}

/// `env` with `GIT_CONFIG` added after the git config entries it (or the env it inherits,
/// `inherited`: `GIT_CONFIG_COUNT`) already passes, so later entries win.
pub(crate) fn add_git_config(env: &mut BTreeMap<String, String>, inherited: Option<&str>) {
    let count = env.get("GIT_CONFIG_COUNT").map(String::as_str).or(inherited);
    let first = count.and_then(|c| c.trim().parse::<usize>().ok()).unwrap_or(0);
    for (i, (key, value)) in GIT_CONFIG.iter().enumerate() {
        env.insert(format!("GIT_CONFIG_KEY_{}", first + i), (*key).to_owned());
        env.insert(format!("GIT_CONFIG_VALUE_{}", first + i), (*value).to_owned());
    }
    env.insert("GIT_CONFIG_COUNT".to_owned(), (first + GIT_CONFIG.len()).to_string());
}

/// The programs a restricted chat starts, by file name: Claude Code itself and the launchers
/// acpmux finds that run it (`config/discover.rs`: `sr claude proxy`, CodeRouter). Any other
/// program may be an interpreter, which loads code its arguments find in the chat's folder
/// before anything asks (`python3 -m`, `node --require`).
const LAUNCHERS: &[&str] = &["claude", "sr", "coderouter", "cr"];

/// Refuses a `program` whose file name is not one of `LAUNCHERS`.
fn launcher(program: &str) -> Result<(), String> {
    let name = Path::new(program).file_name().and_then(OsStr::to_str).unwrap_or(program);
    if LAUNCHERS.contains(&name) {
        return Ok(());
    }
    Err(format!("a restricted chat starts Claude Code ({}), not {name}", LAUNCHERS.join(", ")))
}

/// The program to exec: `program` when absolute, else the first match on PATH's absolute
/// folders (a relative folder such as `.` would find one in the chat's folder). Never a
/// program inside `cwd`, unless `cwd` holds the person's home.
fn frozen_program(program: &str, cwd: &Path) -> Result<String, String> {
    let path = Path::new(program);
    let found = if path.is_absolute() {
        path.to_path_buf()
    } else if program.contains('/') {
        return Err(format!("{program} is a relative path"));
    } else {
        let search = crate::login_env::path().or_else(|| std::env::var_os("PATH"));
        search
            .iter()
            .flat_map(std::env::split_paths)
            .filter(|dir| dir.is_absolute())
            .map(|dir| dir.join(program))
            .find(|candidate| candidate.is_file())
            .ok_or_else(|| format!("{program} is not on PATH"))?
    };
    let real = std::fs::canonicalize(&found).map_err(|e| format!("{}: {e}", found.display()))?;
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    // A folder that holds the person's home (the home itself, `/`) holds their own install of
    // Claude Code too (`~/.local/bin`): that is not one the folder planted.
    if real.starts_with(&cwd) && held_home(&cwd).is_none() {
        return Err(format!("{} is inside the chat's folder", real.display()));
    }
    Ok(found.to_string_lossy().into_owned())
}

/// Refuses an argument of the profile's own `args` (a flag's `=value` too) that names a path
/// inside the chat's folder `cwd`: absolute, or relative with a `/` and there, since Claude Code
/// starts in it. A bare word (`--model default`) is a value: only an interpreter looks one up
/// in the folder, and `launcher` refuses those. Allowed when `cwd` holds the person's home.
fn folder_args(args: &[String], cwd: &Path) -> Result<(), String> {
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    if held_home(&cwd).is_some() {
        return Ok(());
    }
    let words = args.iter().flat_map(|a| [Some(a.as_str()), a.split_once('=').map(|(_, v)| v)]);
    for word in words.flatten().filter(|w| !w.is_empty()) {
        if in_folder(word, &cwd) {
            return Err(format!("{word} is inside the chat's folder"));
        }
    }
    Ok(())
}

/// Refuses a value of the profile's `env` (the spawn's, `${cwd}` already expanded) that names a
/// path inside the chat's folder `cwd`, as `folder_args` does: an entry of a `:` list, the value
/// of an `=` option, a word, or the folder's own path anywhere in it (a path with a space). A
/// launcher's shell or interpreter reads it before anything asks. Keys the restricted chat sets
/// itself (`BLANKED_ENV`, PATH) or checks (`SETTINGS_ROOTS`) are left to that. Allowed when `cwd`
/// holds the person's home.
fn folder_env(env: &BTreeMap<String, String>, cwd: &Path) -> Result<(), String> {
    let given = cwd.to_string_lossy().into_owned();
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    if held_home(&cwd).is_some() {
        return Ok(());
    }
    let folders = [given, cwd.to_string_lossy().into_owned()];
    let set_here = |key: &str| {
        key == "PATH" || BLANKED_ENV.contains(&key) || SETTINGS_ROOTS.iter().any(|(k, _)| *k == key)
    };
    for (key, value) in env.iter().filter(|(key, _)| !set_here(key.as_str())) {
        // A value that is a Keychain item is a secret, not a path.
        let Ok(value) = env_refs_read(key, value) else { continue };
        let entries = value.split(':').flat_map(|e| [Some(e), e.split_once('=').map(|(_, v)| v)]);
        let words = value.split(|c: char| c == ':' || c == '=' || c.is_whitespace());
        let mut words = entries.flatten().chain(words);
        if let Some(word) = words.find(|w| !w.is_empty() && in_folder(w, &cwd)) {
            return Err(format!("{key}={word} is inside the chat's folder"));
        }
        if folders.iter().any(|folder| holds_path(&value, folder)) {
            return Err(format!("{key}={value} names the chat's folder"));
        }
    }
    Ok(())
}

/// Whether `text` holds the absolute path `folder` whole: not as part of a longer name
/// (`/a/chat2`) or a deeper path (`/x/a/chat`).
fn holds_path(text: &str, folder: &str) -> bool {
    let folder = folder.trim_end_matches('/');
    let name = |c: char| c.is_alphanumeric() || "._-~+@".contains(c);
    !folder.is_empty()
        && text.match_indices(folder).any(|(at, _)| {
            let before = text[..at].chars().next_back();
            let after = text[at + folder.len()..].chars().next();
            before.is_none_or(|c| !name(c) && c != '/') && after.is_none_or(|c| !name(c))
        })
}

/// Refuses an inherited `ZDOTDIR` (the daemon's or the login shell's, which the spawn hands to
/// zsh: `login_env::agent_shell_env`) that is relative or inside the chat's folder `cwd`: a zsh
/// launcher sources the `.zshenv` there before anything asks. Allowed when `cwd` holds the
/// person's home.
fn inherited_zdotdir<'v>(
    values: impl IntoIterator<Item = &'v str>,
    cwd: &Path,
) -> Result<(), String> {
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let home = held_home(&cwd);
    for value in values.into_iter().filter(|v| !v.is_empty()) {
        if !Path::new(value).is_absolute() {
            return Err(format!("ZDOTDIR={value} is a relative path"));
        }
        if home.is_none() && in_folder(value, &cwd) {
            return Err(format!("ZDOTDIR={value} is inside the chat's folder"));
        }
    }
    Ok(())
}

/// Whether `word` names a path inside `cwd` (canonical): absolute, or relative (`.`, or with a
/// `/`) and there, since Claude Code starts in it. A bare word is a value.
fn in_folder(word: &str, cwd: &Path) -> bool {
    let path = Path::new(word);
    if path.is_absolute() {
        resolved(path).starts_with(cwd)
    } else {
        (word == "." || word.contains('/')) && cwd.join(path).symlink_metadata().is_ok()
    }
}

/// Refuses `mode` for a restricted chat unless it asks (`MODES`): `Hub::set_mode` and the
/// mode config option of `Hub::set_config`, whoever asks.
pub(crate) fn refuse_mode(meta: &SessionMeta, mode: Option<&str>) -> Result<(), RpcError> {
    match mode {
        _ if !meta.restricted => Ok(()),
        Some(mode) if MODES.contains(&mode) => Ok(()),
        mode => Err(RpcError::invalid_params(format!(
            "restricted.widening: a restricted chat runs in Normal or Plan, not {}; trust the folder first",
            mode.unwrap_or("that mode")
        ))
        .with_data(json!({"reason": "restricted.widening"}))),
    }
}

/// `request` (a `session/request_permission`) as a restricted chat offers it: without the
/// options that allow more than this one call (`allow_always`, "Allow for this session",
/// after which Claude Code keeps the rules it suggested and stops asking). An answer naming
/// one is then refused as not offered (`Hub::respond_permission`), and a chat with an ask
/// open never becomes restricted (`Hub::set_restricted`).
pub(crate) fn strip_lasting_allows(request: &mut Value) {
    if let Some(options) = request.get_mut("options").and_then(Value::as_array_mut) {
        options.retain(|o| o.get("kind").and_then(Value::as_str) != Some("allow_always"));
    }
}

/// Profile, login and daemon env that loads code into Claude Code's process or a launcher's
/// interpreter or shell: a restricted chat starts with it blank (a relative `--require` in
/// `NODE_OPTIONS` would load the folder's, as a PYTHONPATH of `.` imports its
/// `sitecustomize.py`; the loader runs a preloaded library's constructors before Claude Code
/// starts; `CLAUDE_CODE_PLUGIN_DIRS` loads plugins and their hooks, as `--plugin-dir` does).
const BLANKED_ENV: &[&str] = &[
    "NODE_OPTIONS",
    "NODE_PATH",
    "PYTHONPATH",
    "PYTHONHOME",
    "PYTHONSTARTUP",
    "PYTHONUSERBASE",
    "RUBYLIB",
    "RUBYOPT",
    "PERL5LIB",
    "PERL5OPT",
    "PERLLIB",
    "BASH_ENV",
    "ENV",
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    "LD_AUDIT",
    "CLAUDE_CODE_PLUGIN_DIRS",
];

/// The env that says where Claude Code reads its user settings, and the folder under it:
/// `$CLAUDE_CONFIG_DIR`, else `$HOME/.claude`.
const SETTINGS_ROOTS: &[(&str, &str)] = &[("CLAUDE_CONFIG_DIR", ""), ("HOME", ".claude")];

/// The person's home from the account database, canonical: not `$HOME`, which the env being
/// checked can set.
#[cfg(unix)]
fn account_home() -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let mut buf = vec![0 as libc::c_char; 4096];
    // SAFETY: zeroed passwd is a valid out-parameter for getpwuid_r.
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: getuid has no preconditions; every pointer is valid for the call and buf
    // outlives it.
    let rc = unsafe {
        libc::getpwuid_r(libc::getuid(), &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result)
    };
    if rc != 0 || result.is_null() || pwd.pw_dir.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r returned a NUL-terminated path inside buf.
    let dir = unsafe { std::ffi::CStr::from_ptr(pwd.pw_dir) };
    std::fs::canonicalize(std::ffi::OsStr::from_bytes(dir.to_bytes())).ok()
}

#[cfg(not(unix))]
fn account_home() -> Option<PathBuf> {
    None
}

/// The person's home when the canonical folder `cwd` holds it (the home itself, `/`).
fn held_home(cwd: &Path) -> Option<PathBuf> {
    account_home().filter(|home| home.starts_with(cwd))
}

/// `path` with its nearest existing folder canonical: where it is, or would be once made.
fn resolved(path: &Path) -> PathBuf {
    path.ancestors()
        .find_map(|a| Some(std::fs::canonicalize(a).ok()?.join(path.strip_prefix(a).ok()?)))
        .unwrap_or_else(|| path.to_path_buf())
}

/// `path` (a PATH) without its relative folders and the ones inside the chat's folder `cwd`,
/// unless `cwd` holds the person's home (`frozen_program`). Claude Code runs git in the folder
/// as it starts, and acpmux probes and runs `systemd-run` from it (`session_scope.rs`), both
/// before anything asks: neither may be a program the folder planted. None kept is refused: an
/// empty PATH makes a Unix exec look in the current folder.
fn restricted_path(path: &OsStr, cwd: &Path) -> Result<String, String> {
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let home = held_home(&cwd);
    let kept = std::env::split_paths(path)
        .filter(|dir| dir.is_absolute() && (home.is_some() || !resolved(dir).starts_with(&cwd)));
    let kept = std::env::join_paths(kept).map(|p| p.to_string_lossy().into_owned());
    kept.ok()
        .filter(|p| !p.is_empty())
        .ok_or_else(|| "a PATH with no folder outside the chat's folder".to_owned())
}

/// `argv` without the `--disallowedTools` acpmux appended for the tools the chat turned off
/// (`spawn.rs`), which only take tools away: the profile's own are still refused.
fn own_argv<'a>(argv: &'a [String], tools: &crate::store::ToolInventory) -> &'a [String] {
    let generated = super::tools::disallowed_args(tools);
    argv.strip_suffix(generated.as_slice()).unwrap_or(argv)
}

/// Refuses a `key` of `SETTINGS_ROOTS` (each value the spawn could inherit) that is relative or
/// whose settings folder (`under` it) is inside the chat's folder `cwd`: Claude Code reads its
/// user settings there, so `--setting-sources user` would load the folder's own. One elsewhere
/// is the person's own (another Claude account's folder). When `cwd` holds the person's home
/// (`frozen_program`), the home's own folders (`~/.claude`, `~/.claude-work`) are theirs too.
fn check_settings_root<'v>(
    (key, under): (&str, &str),
    values: impl IntoIterator<Item = &'v str>,
    cwd: &Path,
) -> Result<(), String> {
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let home = held_home(&cwd);
    for value in values.into_iter().filter(|v| !v.is_empty()) {
        let root = Path::new(value);
        if !root.is_absolute() {
            return Err(format!("{key}={value} is a relative path"));
        }
        // Claude Code makes the folder when it is missing; a symlink to it counts where it
        // points.
        let real = resolved(&root.join(under));
        let own = home.as_deref().is_some_and(|home| real.parent() == Some(home));
        if real.starts_with(&cwd) && !own {
            return Err(format!("{key}={value} puts Claude's settings inside the chat's folder"));
        }
    }
    Ok(())
}

/// A profile's `key` value with its `${env:…}` references read as the spawn reads them
/// (`agent/command.rs`); any other reference (`${cwd}`, a Keychain item) cannot be checked
/// here, so it is refused.
fn env_refs_read(key: &str, value: &str) -> Result<String, String> {
    let mut one = BTreeMap::from([(key.to_owned(), value.to_owned())]);
    crate::config::profiles::resolve_env_refs(
        &mut one,
        &|var| crate::login_env::allowed_var(var).or_else(|| std::env::var(var).ok()),
        &|_, _| Err("not read for a restricted chat".into()),
    )?;
    let read = one.remove(key).unwrap_or_default();
    if read.contains("${") {
        return Err(format!("{key}={value} holds a reference a restricted chat cannot check"));
    }
    Ok(read)
}

/// Why a request would widen what a restricted chat runs without asking, or Ok.
pub(crate) fn refuse_widening(meta: &SessionMeta, m: &str, params: &Value) -> Result<(), RpcError> {
    if !meta.restricted {
        return Ok(());
    }
    let refused = |what: &str| {
        Err(RpcError::invalid_params(format!(
            "restricted.widening: {what} in a restricted chat; trust the folder first"
        ))
        .with_data(json!({"reason": "restricted.widening"})))
    };
    let text = |key: &str| params.get(key).and_then(Value::as_str);
    match m {
        method::SESSION_SET_MODE => match text("modeId") {
            Some(mode) if !MODES.contains(&mode) => refused("only Normal and Plan run"),
            _ => Ok(()),
        },
        method::SESSION_SET_CONFIG_OPTION
            if text("configId") == Some("mode")
                && !text("value").is_some_and(|mode| MODES.contains(&mode)) =>
        {
            refused("only Normal and Plan run")
        }
        method::MUX_SET_POLICY => match text("policy").map(str::parse::<PermissionPolicy>) {
            Some(Ok(PermissionPolicy::Ask | PermissionPolicy::DenyAll)) | Some(Err(_)) | None => {
                Ok(())
            }
            Some(Ok(_)) => refused("a policy that approves by itself"),
        },
        method::MUX_SET_RULES
            if !crate::hub::person::rules_cannot_auto_approve(params.get("rules")) =>
        {
            refused("a rule that approves by itself")
        }
        method::MUX_SET_TOOLS => refused("turning tools on or off"),
        _ => Ok(()),
    }
}

impl Hub {
    /// Whether `meta`'s chat can run restricted: a local chat of Claude Code as acpmux runs it,
    /// with no preset.
    pub(crate) async fn restrictable(&self, meta: &SessionMeta) -> bool {
        !meta.remote_origin
            && meta.preset.is_none()
            && self.config.read().await.harnesses.get(&meta.harness).is_some_and(supports)
    }

    /// Whether the harness named `harness` (a profile, a family or `HEAD/MODEL`) runs restricted.
    pub(super) async fn restricted_harness(&self, harness: &str) -> bool {
        let cfg = self.config.read().await;
        let head = harness.split('/').next().unwrap_or(harness);
        cfg.resolve_harness(head)
            .ok()
            .and_then(|resolved| cfg.harnesses.get(&resolved))
            .is_some_and(supports)
    }

    /// Brings `session` to `restricted`; true when it is now. Its agent ends, so the next
    /// prompt starts one with the command line that goes with it; a chat that is busy (a turn,
    /// a queued prompt or a question) or whose agent did not end keeps what it was. Becoming
    /// restricted also sets the policy to ask.
    pub(crate) async fn set_restricted(
        self: &Arc<Self>,
        session: &Arc<Session>,
        restricted: bool,
    ) -> bool {
        if session.meta().restricted == restricted {
            return true;
        }
        if restricted && !self.restrictable(&session.meta()).await {
            return false;
        }
        // No agent starts while the flag moves: the next start reads it.
        let spawning = session.spawn_lock.lock().await;
        if session.meta().restricted == restricted {
            return true;
        }
        // Held until the agent has ended: no turn starts on the old agent meanwhile (a turn
        // takes `turn_lock` before `spawn_lock`, so this only tries).
        let Ok(turn) = session.turn_lock.try_lock() else { return false };
        let busy = session.turn().is_some()
            || session.queued() > 0
            || !session.pending_permissions().is_empty();
        if busy {
            return false;
        }
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).restricted = restricted;
        let running = session.child.lock().await.is_some();
        if running {
            let child = session.child.lock().await.clone();
            let link_lost = match &child {
                Some(c) => c.host_record().is_some() && !c.is_alive().await,
                None => false,
            };
            self.detach_child(session).await;
            if link_lost {
                self.end_unadopted_host(session).await;
            }
        }
        // A host this daemon has not reached again yet runs the old command line too.
        if Self::host_record_live(&session.id) {
            self.end_unadopted_host(session).await;
        }
        if Self::host_record_live(&session.id) {
            tracing::warn!(session = %session.id, restricted, "restriction unchanged: the chat's agent host did not end");
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).restricted = !restricted;
            return false;
        }
        tracing::info!(session = %session.id, restricted, "restricted chat changed; the next prompt starts a fresh agent");
        self.append(session, "mux", "restricted", json!({"restricted": restricted}));
        // `set_policy` moves a mode that does not ask under `spawn_lock` itself
        // (`follow_policy`); a start after this reads the flag and asks anyway.
        drop((turn, spawning));
        if restricted {
            self.set_policy(session, PermissionPolicy::Ask).await;
        } else {
            self.save_meta(session);
        }
        true
    }

    /// After a trust answer: every restricted chat whose folder is trusted now lifts (off the
    /// request: the answer replies at once).
    pub(crate) fn lift_trusted_restrictions(self: &Arc<Self>) {
        let Some(paths) = self.trust_gate() else { return };
        let restricted: Vec<_> =
            self.sessions().into_iter().filter(|s| s.meta().restricted).collect();
        if restricted.is_empty() {
            return;
        }
        let hub = self.clone();
        tokio::spawn(async move {
            for session in restricted {
                let meta = session.meta();
                let (paths, cwd) = (paths.clone(), meta.cwd.to_string_lossy().into_owned());
                let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
                let level = tokio::task::spawn_blocking(move || {
                    crate::trust::session_level(&paths, &cwd, &family)
                })
                .await;
                if matches!(level, Ok(Ok((_, crate::trust::Level::Trusted)))) {
                    hub.set_restricted(&session, false).await;
                }
            }
        });
    }

    /// A restricted chat's start refused for `why`, recorded in its log.
    fn refuse_start(&self, session: &Session, why: String) -> RpcError {
        self.append(session, "mux", "restricted_refused", json!({"error": why}));
        RpcError::new(-32000, format!("restricted chat refused: {why}"))
            .with_data(json!({"reason": "restricted.refused"}))
    }

    /// Refuses to start `profile` for a restricted chat unless it is Claude Code, whose
    /// command line `restricted_plan` builds: any other harness would start with the folder's
    /// own config, and the trust gate lets a restricted chat's prompts through.
    pub(super) fn refuse_unrestricted_start(
        &self,
        session: &Session,
        profile: &HarnessProfile,
    ) -> Result<(), RpcError> {
        if !session.meta().restricted || supports(profile) {
            return Ok(());
        }
        Err(self.refuse_start(session, "only Claude Code runs as a restricted chat".into()))
    }

    /// The turn error of a restricted chat whose fallback `to` cannot run restricted, or None
    /// when the turn may move to `to`. The limit `error` stands, with why the chat stayed; the
    /// chat's log gets a `failover_refused` record (`{from, to, reason, error, turnId}`), which
    /// the pane draws where the failover note would be.
    pub(super) async fn refuse_failover(
        &self,
        session: &Session,
        to: &str,
        error: &RpcError,
        turn_id: &str,
    ) -> Option<RpcError> {
        let meta = session.meta();
        if !meta.restricted
            || self.config.read().await.harnesses.get(to).is_some_and(starts_restricted)
        {
            return None;
        }
        tracing::info!(session = %session.id, to, "failover refused: the fallback cannot run restricted");
        self.append(
            session,
            "mux",
            "failover_refused",
            json!({"from": meta.harness, "to": to, "reason": "restricted", "error": error.message, "turnId": turn_id}),
        );
        let mut refused = error.clone();
        refused.message =
            format!("{} (can't switch to {to} in a folder you haven't trusted)", error.message);
        Some(refused)
    }

    /// `plan` and `profile` for this spawn: a restricted chat's restricted command line and
    /// env (above); any other session's are unchanged.
    pub(super) fn restricted_plan<'p>(
        &self,
        session: &Session,
        profile: Cow<'p, HarnessProfile>,
        plan: crate::claude_stdio::SpawnPlan,
    ) -> Result<(crate::claude_stdio::SpawnPlan, Cow<'p, HarnessProfile>), RpcError> {
        let meta = session.meta();
        // A remote chain (a chat moved here) runs in its own sandbox with its own inline
        // settings, which ask too (`remote_sandbox.rs`): one set of flags, never two.
        if !meta.restricted || meta.remote_origin {
            return Ok((plan, profile));
        }
        let refused = |why: String| self.refuse_start(session, why);
        self.refuse_unrestricted_start(session, &profile)?;
        let own = own_argv(&profile.argv, &meta.tools);
        launcher(own.first().map_or("", String::as_str)).map_err(refused)?;
        folder_args(own.get(1..).unwrap_or_default(), &meta.cwd).map_err(refused)?;
        folder_env(&profile.env, &meta.cwd).map_err(refused)?;
        let zdotdir = [
            crate::login_env::var("ZDOTDIR"),
            std::env::var("ZDOTDIR").ok(),
            std::env::var(crate::login_env::AGENT_USER_ZDOTDIR_ENV).ok(),
        ];
        inherited_zdotdir(zdotdir.iter().flatten().map(String::as_str), &meta.cwd)
            .map_err(refused)?;
        let mut plan = command_line(own, plan).map_err(refused)?;
        plan.program = frozen_program(&plan.program, &meta.cwd).map_err(refused)?;
        for &(key, under) in SETTINGS_ROOTS {
            let own = profile.env.get(key).map(|v| env_refs_read(key, v)).transpose();
            let (own, login, daemon) =
                (own.map_err(refused)?, crate::login_env::var(key), std::env::var(key).ok());
            let values = [own.as_ref(), login.as_ref(), daemon.as_ref()];
            let values = values.into_iter().flatten().map(String::as_str);
            check_settings_root((key, under), values, &meta.cwd).map_err(refused)?;
        }
        // The PATH the spawn would give it (`session_scope::runner`'s order).
        let path = match profile.env.get("PATH") {
            Some(own) => Some(OsString::from(env_refs_read("PATH", own).map_err(refused)?)),
            None => crate::login_env::agent_path().or_else(|| std::env::var_os("PATH")),
        };
        let mut profile = profile.into_owned();
        for key in BLANKED_ENV {
            profile.env.insert((*key).to_owned(), String::new());
        }
        if let Some(path) = path {
            let path = restricted_path(&path, &meta.cwd).map_err(refused)?;
            profile.env.insert("PATH".to_owned(), path);
        }
        let inherited = crate::login_env::var("GIT_CONFIG_COUNT")
            .or_else(|| std::env::var("GIT_CONFIG_COUNT").ok());
        add_git_config(&mut profile.env, inherited.as_deref());
        Ok((plan, Cow::Owned(profile)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claude_stdio::{SpawnPlan, spawn_plan};

    fn claude(argv: &[&str]) -> HarnessProfile {
        let mut p: HarnessProfile = serde_json::from_value(json!({"argv": argv})).expect("profile");
        p.kind = HarnessKind::ClaudeStdio;
        p
    }

    fn value_after<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
        let i = args.iter().position(|a| a == flag)?;
        args.get(i + 1).map(String::as_str)
    }

    #[test]
    fn the_setting_is_off_by_default_and_only_true_turns_it_on() {
        assert!(!catalog_default(), "the catalog default is off");
        assert!(!enabled_in(&json!({})));
        assert!(!enabled_in(&json!({"agents": {"trust": {"restrictedChats": "yes"}}})));
        assert!(!enabled_in(&json!({"agents.trust.restrictedChats": false})));
        assert!(enabled_in(&json!({"agents": {"trust": {"restrictedChats": true}}})));
        assert!(enabled_in(&json!({"agents.trust.restrictedChats": true})));
    }

    #[test]
    fn the_restricted_command_line_skips_project_config_and_asks() {
        let profile = claude(&["claude"]);
        let plan = spawn_plan(&profile, None, false, Some("id"), None, "bypassPermissions", None);
        let plan = command_line(&profile.argv, plan).expect("restricted plan");
        let args = &plan.args;
        assert!(!args.iter().any(|a| a == crate::claude_stdio::ALLOW_BYPASS_FLAG));
        assert_eq!(value_after(args, "--permission-mode"), Some("default"));
        assert_eq!(value_after(args, "--setting-sources"), Some("user"));
        assert!(args.iter().any(|a| a == "--strict-mcp-config"));
        assert_eq!(value_after(args, "--mcp-config"), Some(NO_MCP_SERVERS));
        assert!(args.iter().any(|a| a == "--disable-slash-commands"));
        let settings: Value =
            serde_json::from_str(value_after(args, "--settings").expect("settings")).unwrap();
        assert_eq!(settings["permissions"]["disableBypassPermissionsMode"], "disable");
        let ask = settings["permissions"]["ask"].as_array().expect("ask rules");
        for tool in ["Bash", "Edit", "Write", "WebFetch", "Task", "Skill"] {
            assert!(ask.iter().any(|t| t == tool), "{tool} asks");
        }
        assert_eq!(settings["sandbox"]["autoAllowBashIfSandboxed"], false);
        assert_eq!(args.iter().filter(|a| *a == "--permission-mode").count(), 1);
    }

    #[test]
    fn plan_mode_stays_and_every_other_mode_runs_as_default() {
        let profile = claude(&["claude"]);
        for (mode, runs) in [
            ("plan", "plan"),
            ("default", "default"),
            ("auto", "default"),
            ("acceptEdits", "default"),
        ] {
            let plan = spawn_plan(&profile, None, false, Some("id"), None, mode, None);
            let plan = command_line(&profile.argv, plan).expect("restricted plan");
            assert_eq!(value_after(&plan.args, "--permission-mode"), Some(runs), "{mode}");
        }
        assert_eq!(asking_mode("bypassPermissions".into()), "default");
        assert_eq!(asking_mode("plan".into()), "plan");
    }

    #[test]
    fn a_profile_argv_that_shapes_the_command_line_is_refused() {
        for flag in [
            "--settings",
            "--setting-sources=project",
            "--mcp-config",
            "--dangerously-skip-permissions",
            "--allow-dangerously-skip-permissions",
            "--permission-mode",
            "--plugin-dir",
            "--add-dir",
        ] {
            let profile = claude(&["claude", flag, "x"]);
            let plan = SpawnPlan { program: "claude".into(), args: profile.argv[1..].to_vec() };
            let refused = command_line(&profile.argv, plan).expect_err(flag);
            assert!(refused.contains("restricted chat never runs"), "{flag}: {refused}");
        }
        let sr = claude(&["sr", "claude", "proxy"]);
        let plan = SpawnPlan { program: "sr".into(), args: sr.argv[1..].to_vec() };
        assert!(command_line(&sr.argv, plan).is_ok(), "the subrouter launcher runs restricted");
        // A failover target is judged the same way: one that would be refused at spawn is
        // refused before the chat moves to it.
        assert!(starts_restricted(&sr));
        assert!(!starts_restricted(&claude(&["claude", "--add-dir", "/"])));
        assert!(!starts_restricted(&claude(&["node", "/opt/claude/cli.js"])));
    }

    #[test]
    fn git_config_is_appended_after_what_the_env_passes() {
        let mut env = BTreeMap::new();
        add_git_config(&mut env, None);
        assert_eq!(env["GIT_CONFIG_COUNT"], "2");
        assert_eq!(env["GIT_CONFIG_KEY_0"], "core.fsmonitor");
        assert_eq!(env["GIT_CONFIG_VALUE_0"], "false");
        assert_eq!(env["GIT_CONFIG_KEY_1"], "core.hooksPath");
        assert_eq!(env["GIT_CONFIG_VALUE_1"], "/dev/null");

        let mut env = BTreeMap::new();
        add_git_config(&mut env, Some("1"));
        assert_eq!(env["GIT_CONFIG_COUNT"], "3");
        assert_eq!(env["GIT_CONFIG_KEY_1"], "core.fsmonitor");
        assert!(!env.contains_key("GIT_CONFIG_KEY_0"), "the inherited entry stays the env's");
    }

    #[test]
    fn a_program_inside_the_chat_folder_is_refused() {
        let root = std::env::temp_dir().join(format!("restricted-program-{}", std::process::id()));
        let (dir, elsewhere) = (root.join("chat"), root.join("elsewhere"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        let program = dir.join("claude");
        std::fs::write(&program, "#!/bin/sh\n").unwrap();
        let refused = frozen_program(&program.to_string_lossy(), &dir).unwrap_err();
        assert!(refused.contains("inside the chat's folder"), "{refused}");
        assert!(frozen_program("./claude", &dir).is_err());
        let frozen = frozen_program(&program.to_string_lossy(), &elsewhere).unwrap();
        assert_eq!(frozen, program.to_string_lossy());
        // A folder holding the person's home (here `/`) holds their own install too.
        if account_home().is_some() {
            assert!(frozen_program(&program.to_string_lossy(), Path::new("/")).is_ok());
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_profile_argument_inside_the_chat_folder_is_refused() {
        let root = std::env::temp_dir().join(format!("restricted-args-{}", std::process::id()));
        let (chat, elsewhere) = (root.join("chat"), root.join("elsewhere"));
        std::fs::create_dir_all(&chat).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::write(chat.join("cli.js"), "").unwrap();
        let args = |a: &[&str]| a.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
        let script = chat.join("cli.js").to_string_lossy().into_owned();
        assert!(folder_args(&args(&[&script]), &chat).is_err());
        assert!(folder_args(&args(&["./cli.js"]), &chat).is_err());
        // A bare word is a value, even one the folder has a file for.
        assert!(folder_args(&args(&["--model", "cli.js"]), &chat).is_ok());
        assert!(folder_args(&args(&[&format!("--require={script}")]), &chat).is_err());
        let missing = chat.join("later.js").to_string_lossy().into_owned();
        assert!(folder_args(&args(&[&missing]), &chat).is_err());
        let ok = args(&["--model", "opus", "--verbose", &elsewhere.to_string_lossy()]);
        assert!(folder_args(&ok, &chat).is_ok());
        assert!(folder_args(&args(&[&script]), &elsewhere).is_ok());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_profile_env_value_inside_the_chat_folder_is_refused() {
        let root = std::env::temp_dir().join(format!("restricted-env-{}", std::process::id()));
        let (chat, elsewhere) = (root.join("chat"), root.join("elsewhere"));
        std::fs::create_dir_all(chat.join("dots")).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        let env = |pairs: &[(&str, &str)]| {
            pairs
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect::<BTreeMap<_, _>>()
        };
        let dots = chat.join("dots").to_string_lossy().into_owned();
        assert!(folder_env(&env(&[("ZDOTDIR", ".")]), &chat).is_err());
        assert!(folder_env(&env(&[("ZDOTDIR", &dots)]), &chat).is_err());
        assert!(folder_env(&env(&[("ZDOTDIR", "./dots")]), &chat).is_err());
        let list = format!("/usr/lib:{dots}");
        assert!(folder_env(&env(&[("GEM_PATH", &list)]), &chat).is_err());
        assert!(folder_env(&env(&[("TOOL_OPTS", "--rcfile dots/x")]), &chat).is_ok());
        assert!(folder_env(&env(&[("TOOL_OPTS", "--rcfile=dots")]), &chat).is_ok());
        assert!(folder_env(&env(&[("TOOL_OPTS", "--rc ./dots")]), &chat).is_err());
        // Values, other folders, and the keys the restricted chat sets or checks itself.
        let ok = env(&[
            ("ANTHROPIC_MODEL", "dots"),
            ("ANTHROPIC_BASE_URL", "http://localhost:8080/v1"),
            ("ZDOTDIR", &elsewhere.to_string_lossy()),
            ("PYTHONPATH", "."),
            ("PATH", "."),
        ]);
        assert!(folder_env(&ok, &chat).is_ok());
        assert!(folder_env(&env(&[("ZDOTDIR", ".")]), &elsewhere).is_err());
        assert!(folder_env(&env(&[("ZDOTDIR", &dots)]), &elsewhere).is_ok());
        // A folder whose name has a space: named whole, inside an option string, or relative.
        let spaced = root.join("my chat");
        std::fs::create_dir_all(spaced.join("my dots")).unwrap();
        let spaced_dots = spaced.join("my dots").to_string_lossy().into_owned();
        assert!(folder_env(&env(&[("ZDOTDIR", &spaced_dots)]), &spaced).is_err());
        let opts = format!("--rcfile \"{spaced_dots}/x\"");
        assert!(folder_env(&env(&[("TOOL_OPTS", &opts)]), &spaced).is_err());
        assert!(folder_env(&env(&[("ZDOTDIR", "./my dots")]), &spaced).is_err());
        let sibling = root.join("my chat2").to_string_lossy().into_owned();
        assert!(folder_env(&env(&[("ZDOTDIR", &sibling)]), &spaced).is_ok());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_inherited_zdotdir_relative_or_in_the_chat_folder_is_refused() {
        let root = std::env::temp_dir().join(format!("restricted-zdot-{}", std::process::id()));
        let (chat, elsewhere) = (root.join("chat"), root.join("elsewhere"));
        std::fs::create_dir_all(chat.join("dots")).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        let dots = chat.join("dots").to_string_lossy().into_owned();
        assert!(inherited_zdotdir(["."], &chat).is_err());
        assert!(inherited_zdotdir(["zsh"], &chat).is_err());
        assert!(inherited_zdotdir([dots.as_str()], &chat).is_err());
        let theirs = elsewhere.to_string_lossy().into_owned();
        assert!(inherited_zdotdir(["", theirs.as_str()], &chat).is_ok());
        assert!(inherited_zdotdir([dots.as_str()], &elsewhere).is_ok());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn only_claude_codes_launchers_start_restricted() {
        for program in ["claude", "/Users/me/.local/bin/claude", "/opt/bin/sr", "coderouter"] {
            assert!(launcher(program).is_ok(), "{program}");
        }
        for program in ["python3", "/usr/bin/node", "bun", "/bin/sh", "claude.py", ""] {
            assert!(launcher(program).is_err(), "{program}");
        }
        // The Claude Code profiles acpmux finds start restricted.
        let which = |bin: &str| Some(format!("/opt/bin/{bin}"));
        let mut found = crate::config::discover_harnesses_from(None, &which);
        crate::config::add_coderouter_route(&mut found, Some("work"), &which);
        let claude = found.values().filter(|p| supports(p)).collect::<Vec<_>>();
        assert!(claude.len() >= 3, "{claude:?}");
        for profile in claude {
            assert!(launcher(&profile.argv[0]).is_ok(), "{:?}", profile.argv);
        }
    }

    #[cfg(unix)]
    #[test]
    fn path_keeps_no_folder_in_the_chat_and_no_relative_one() {
        let root = std::env::temp_dir().join(format!("restricted-path-{}", std::process::id()));
        let (chat, elsewhere) = (root.join("chat"), root.join("elsewhere"));
        std::fs::create_dir_all(chat.join("bin")).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::os::unix::fs::symlink(chat.join("bin"), elsewhere.join("bin")).unwrap();
        let path = std::env::join_paths([
            chat.join("bin"),
            PathBuf::from("bin"),
            PathBuf::from("/usr/bin"),
            elsewhere.join("bin"),
            elsewhere.join("missing"),
            chat.join("missing"),
        ])
        .unwrap();
        let kept = std::env::join_paths([PathBuf::from("/usr/bin"), elsewhere.join("missing")]);
        assert_eq!(restricted_path(&path, &chat).unwrap(), kept.unwrap().to_string_lossy());
        // Nothing left: refused, since an empty PATH looks in the current folder.
        let inside = std::env::join_paths([chat.join("bin"), PathBuf::from("bin")]).unwrap();
        assert!(restricted_path(&inside, &chat).is_err());
        // A folder holding the person's home (here `/`) keeps their own folders.
        if account_home().is_some() {
            let all = std::env::join_paths([chat.join("bin"), elsewhere.join("bin")]).unwrap();
            assert_eq!(restricted_path(&all, Path::new("/")).unwrap(), all.to_string_lossy());
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_tools_a_chat_turned_off_are_not_the_profile_shaping_it() {
        let tools = crate::store::ToolInventory {
            off: vec!["tool:WebFetch".into(), "mcp:docs".into()],
            ..Default::default()
        };
        let generated = crate::hub::tools::disallowed_args(&tools);
        let with = |argv: &[&str]| {
            let mut argv: Vec<String> = argv.iter().map(|a| (*a).to_owned()).collect();
            argv.extend(generated.iter().cloned());
            argv
        };
        let argv = with(&["claude"]);
        assert_eq!(own_argv(&argv, &tools), ["claude".to_owned()]);
        let plan = SpawnPlan { program: "claude".into(), args: argv[1..].to_vec() };
        let plan = command_line(own_argv(&argv, &tools), plan).expect("restricted plan");
        assert_eq!(value_after(&plan.args, "--disallowedTools"), Some("WebFetch"));
        // The profile's own still shape it.
        let argv = with(&["claude", "--disallowedTools", "Read"]);
        let plan = SpawnPlan { program: "claude".into(), args: argv[1..].to_vec() };
        assert!(command_line(own_argv(&argv, &tools), plan).is_err());
    }

    #[test]
    fn a_restricted_ask_offers_nothing_that_allows_more_than_the_call() {
        let mut request = json!({"options": [
            {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
            {"optionId": "allow_always", "name": "Allow for this session", "kind": "allow_always"},
            {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
        ]});
        strip_lasting_allows(&mut request);
        let kinds: Vec<_> =
            request["options"].as_array().unwrap().iter().map(|o| o["kind"].clone()).collect();
        assert_eq!(kinds, [json!("allow_once"), json!("reject_once")]);
    }

    #[cfg(unix)]
    #[test]
    fn a_settings_root_in_the_chat_folder_or_relative_is_refused() {
        let root = std::env::temp_dir().join(format!("restricted-config-{}", std::process::id()));
        let (chat, elsewhere) = (root.join("chat"), root.join("elsewhere"));
        std::fs::create_dir_all(&chat).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        let text = |p: &Path| p.to_string_lossy().into_owned();
        let (config, home) = (SETTINGS_ROOTS[0], SETTINGS_ROOTS[1]);
        assert!(check_settings_root(config, [], &chat).is_ok());
        assert!(check_settings_root(config, [""], &chat).is_ok(), "set but empty is unset");
        let relative = check_settings_root(config, [".claude"], &chat).unwrap_err();
        assert!(relative.contains("relative path"), "{relative}");
        // Missing yet (Claude Code makes it), and through the temp folder's symlink on macOS.
        let inside = text(&chat.join(".claude"));
        let refused = check_settings_root(config, [inside.as_str()], &chat).unwrap_err();
        assert!(refused.contains("inside the chat's folder"), "{refused}");
        // Another account's folder elsewhere is the person's own.
        let own = text(&elsewhere.join(".claude-work"));
        assert!(check_settings_root(config, [own.as_str()], &chat).is_ok());
        // Any one value the spawn could inherit is enough to refuse.
        assert!(check_settings_root(config, [own.as_str(), inside.as_str()], &chat).is_err());
        // A profile's references: `${env:…}` is read, any other cannot be checked.
        assert_eq!(env_refs_read("CLAUDE_CONFIG_DIR", "/opt/claude").unwrap(), "/opt/claude");
        assert!(env_refs_read("CLAUDE_CONFIG_DIR", "${cwd}/.claude").is_err());
        assert!(env_refs_read("CLAUDE_CONFIG_DIR", "${keychain:claude}").is_err());
        // `HOME` counts by its `.claude`: the chat's folder itself, a HOME just above a chat
        // in `.claude`, or a HOME elsewhere whose `.claude` links to the chat.
        assert!(check_settings_root(home, [text(&chat).as_str()], &chat).is_err());
        let settings = chat.join(".claude");
        std::fs::create_dir_all(&settings).unwrap();
        assert!(check_settings_root(home, [text(&chat).as_str()], &settings).is_err());
        std::os::unix::fs::symlink(&chat, elsewhere.join(".claude")).unwrap();
        let linked = check_settings_root(home, [text(&elsewhere).as_str()], &chat).unwrap_err();
        assert!(linked.contains("inside the chat's folder"), "{linked}");
        assert!(env_refs_read("HOME", "${cwd}").is_err());
        // The person's own home, read from the account database, not from `$HOME`.
        if let Some(account) = account_home() {
            let own = text(&account);
            assert!(check_settings_root(home, [own.as_str()], Path::new("/")).is_ok());
            let deeper = text(&account.join("project"));
            assert!(check_settings_root(home, [deeper.as_str()], Path::new("/")).is_err());
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    fn meta(restricted: bool) -> SessionMeta {
        let profile = claude(&["claude"]);
        let mut m = super::super::resolve::draft_meta(super::super::resolve::Draft {
            id: "s".into(),
            agent: "claude",
            profile: &profile,
            family: "claude",
            preset: None,
            model_request: None,
            cwd: PathBuf::from("/tmp"),
            agent_session_id: None,
            policy: None,
            remote: false,
        });
        m.restricted = restricted;
        m
    }

    #[test]
    fn a_restricted_chat_refuses_what_would_widen_it() {
        let r = meta(true);
        let widen = |m: &str, p: Value| refuse_widening(&r, m, &p);
        assert!(widen(method::SESSION_SET_MODE, json!({"modeId": "bypassPermissions"})).is_err());
        assert!(widen(method::SESSION_SET_MODE, json!({"modeId": "auto"})).is_err());
        assert!(widen(method::SESSION_SET_MODE, json!({"modeId": "plan"})).is_ok());
        assert!(widen(method::SESSION_SET_MODE, json!({"modeId": "default"})).is_ok());
        let mode = |v: &str| json!({"configId": "mode", "value": v});
        assert!(widen(method::SESSION_SET_CONFIG_OPTION, mode("bypassPermissions")).is_err());
        assert!(widen(method::SESSION_SET_CONFIG_OPTION, mode("plan")).is_ok());
        assert!(
            widen(
                method::SESSION_SET_CONFIG_OPTION,
                json!({"configId": "effort", "value": "high"})
            )
            .is_ok()
        );
        for policy in ["approve-all", "approve-reads", "approve-edits"] {
            assert!(widen(method::MUX_SET_POLICY, json!({"policy": policy})).is_err(), "{policy}");
        }
        assert!(widen(method::MUX_SET_POLICY, json!({"policy": "ask"})).is_ok());
        assert!(widen(method::MUX_SET_POLICY, json!({"policy": "deny-all"})).is_ok());
        assert!(widen(method::MUX_SET_TOOLS, json!({})).is_err());
        let refused = widen(method::SESSION_SET_MODE, json!({"modeId": "auto"})).unwrap_err();
        assert_eq!(
            refused.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str),
            Some("restricted.widening")
        );
        // Hub::set_mode and the mode config option of Hub::set_config, whoever asks.
        assert!(refuse_mode(&r, Some("plan")).is_ok());
        assert!(refuse_mode(&r, Some("bypassPermissions")).is_err());
        assert!(refuse_mode(&r, None).is_err(), "a mode that is not a string");
        // A chat that is not restricted is not this check's.
        let free = meta(false);
        assert!(refuse_mode(&free, Some("bypassPermissions")).is_ok());
        assert!(
            refuse_widening(&free, method::SESSION_SET_MODE, &json!({"modeId": "auto"})).is_ok()
        );
        assert!(refuse_widening(&free, method::MUX_SET_TOOLS, &json!({})).is_ok());
    }
}

//! Relay-side execution verbs (relay wire v3, W57; v5 process credentials).
//!
//! Behavior port of `packages/relay/bin/actions.mjs` (chatmux repo); tests
//! mirror `actions.test.mjs`. The Worker sends `action_request` frames over
//! the paired socket; this module runs them with the relay user's
//! permissions and answers `action_result`.
//!
//! Discipline:
//! - trust is re-checked HERE from the machine's own reconciled config
//!   (observe = the read-only verbs only), so a compromised or buggy server
//!   still cannot run anything the owner did not allow;
//! - path scoping: when allowed roots exist (local `--allow-root` config
//!   and/or the machine row echoed by the server) every file path and exec
//!   cwd must resolve inside them — enforced against BOTH lists, first
//!   lexically and then against the canonical (realpath) host view;
//! - final read/write opens use O_NOFOLLOW where the host supports it;
//! - exec spawns with a scrubbed environment (no inherited API keys) and a
//!   hard timeout (whole process group: SIGTERM, then SIGKILL after grace);
//! - all output is truncated to bounded sizes before it goes on the wire.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use serde_json::{Map, Value, json};

pub const READ_ONLY_VERBS: [&str; 4] = ["read", "ls", "grep", "find"];
pub const ACTION_VERBS: [&str; 6] = ["exec", "read", "write", "ls", "grep", "find"];

/// Bounded sizes so one action can never flood the socket.
pub const MAX_OUTPUT_CHARS: usize = 60_000;
pub const MAX_READ_BYTES: u64 = 2_000_000;
pub const MAX_LISTING_ENTRIES: usize = 1_000;

pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;
pub const MAX_TIMEOUT_MS: u64 = 300_000;
pub const MAX_PATH_CHARS: usize = 4_096;

const MAX_RUNTIME_ENVIRONMENT_ENTRIES: usize = 64;
const MAX_RUNTIME_ENVIRONMENT_BYTES: usize = 256_000;
const MAX_RUNTIME_FILES: usize = 8;

// ---------------------------------------------------------------------------
// Path policy (pure)
// ---------------------------------------------------------------------------

/// Node `path.resolve` equivalent: absolute values normalize on their own,
/// relative values join the base first; `.` and `..` collapse lexically.
fn lexical_resolve(base: &Path, value: &str) -> PathBuf {
    let candidate = Path::new(value);
    let joined =
        if candidate.is_absolute() { candidate.to_path_buf() } else { base.join(candidate) };
    let mut out = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::Prefix(prefix) => out.push(prefix.as_os_str()),
            Component::RootDir => out.push(Component::RootDir.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    // Above the root: Node clamps at the root.
                }
            }
            Component::Normal(part) => out.push(part),
        }
    }
    if out.as_os_str().is_empty() { base.to_path_buf() } else { out }
}

/// Expand a leading `~` and resolve to an absolute path.
pub fn expand_path(raw_path: &str, home: &Path, base: &Path) -> PathBuf {
    if raw_path == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = raw_path.strip_prefix("~/").or_else(|| raw_path.strip_prefix("~\\")) {
        return lexical_resolve(home, rest);
    }
    lexical_resolve(base, raw_path)
}

fn within_root(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}

fn relative_path_escapes(raw_path: &str) -> bool {
    let mut depth: i64 = 0;
    for segment in raw_path.split(['/', '\\']) {
        match segment {
            "" | "." => {}
            ".." => {
                if depth == 0 {
                    return true;
                }
                depth -= 1;
            }
            _ => depth += 1,
        }
    }
    false
}

fn is_tilde_request(value: &str) -> bool {
    value == "~" || value.starts_with("~/") || value.starts_with("~\\")
}

fn has_encoded_path_syntax(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    ["%00", "%25", "%2e", "%2f", "%5c"].iter().any(|needle| lower.contains(needle))
}

fn validate_request_path(value: &str) -> Result<(), String> {
    if value.len() > MAX_PATH_CHARS {
        return Err(format!("path exceeds {MAX_PATH_CHARS} characters"));
    }
    if value.chars().any(|c| c <= '\u{001f}' || c == '\u{007f}') {
        return Err("path contains a control character".to_owned());
    }
    if has_encoded_path_syntax(value) {
        return Err("percent-encoded path syntax is not accepted".to_owned());
    }
    if value.starts_with("//") || value.starts_with("\\\\") {
        return Err("ambiguous leading path separators are not accepted".to_owned());
    }
    if cfg!(windows) {
        let drive_relative = value.len() >= 2
            && value.as_bytes()[1] == b':'
            && value.as_bytes()[0].is_ascii_alphabetic()
            && !Path::new(value).is_absolute();
        if drive_relative {
            return Err("drive-relative paths are not accepted".to_owned());
        }
    }
    // A backslash is a filename character on POSIX but a separator on
    // Windows. Refuse that ambiguous spelling on POSIX so one request cannot
    // acquire different authority after crossing hosts.
    if cfg!(not(windows)) && value.contains('\\') {
        return Err("use '/' as the path separator on this machine".to_owned());
    }
    Ok(())
}

pub struct ScopedPath {
    pub path: PathBuf,
    pub absolute_request: bool,
    pub workdir: PathBuf,
}

/// Root lists: local config roots and the server-echoed roots. Empty or
/// absent lists impose nothing; every NON-empty list must contain the path.
pub type RootLists<'a> = [Option<&'a [String]>; 2];

/// Resolve a request path and enforce every non-empty root list.
pub fn resolve_scoped_path(
    raw_path: &str,
    root_lists: &RootLists<'_>,
    home: &Path,
    workdir: &str,
) -> Result<ScopedPath, String> {
    validate_request_path(raw_path)?;
    let absolute_request = Path::new(raw_path).is_absolute() || is_tilde_request(raw_path);
    if !absolute_request && relative_path_escapes(raw_path) {
        return Err("a relative path cannot escape the target workdir".to_owned());
    }
    let resolved_workdir = expand_path(workdir, home, home);
    let path = expand_path(raw_path, home, &resolved_workdir);
    if !path.is_absolute() {
        return Err(format!("path did not resolve absolute: {}", path.display()));
    }
    if !absolute_request && !within_root(&path, &resolved_workdir) {
        return Err(format!(
            "relative path {} is outside the target workdir {}",
            path.display(),
            resolved_workdir.display(),
        ));
    }
    for roots in root_lists.iter().flatten() {
        if roots.is_empty() {
            continue;
        }
        let resolved: Vec<PathBuf> =
            roots.iter().map(|root| expand_path(root, home, home)).collect();
        if !resolved.iter().any(|root| within_root(&path, root)) {
            let joined =
                resolved.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ");
            return Err(format!(
                "path {} is outside this machine's allowed roots ({joined})",
                path.display(),
            ));
        }
    }
    Ok(ScopedPath { path, absolute_request, workdir: resolved_workdir })
}

// ---------------------------------------------------------------------------
// Host-aware second pass (realpath + O_NOFOLLOW)
// ---------------------------------------------------------------------------

/// A typed refusal from the canonical host pass (mapped to path_forbidden).
struct HostPathRefusal(String);

enum HostError {
    Refusal(String),
    Io(std::io::Error),
}

impl From<HostPathRefusal> for HostError {
    fn from(refusal: HostPathRefusal) -> HostError {
        HostError::Refusal(refusal.0)
    }
}

impl From<std::io::Error> for HostError {
    fn from(error: std::io::Error) -> HostError {
        HostError::Io(error)
    }
}

fn is_not_found(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::NotFound
}

fn is_eloop(error: &std::io::Error) -> bool {
    #[cfg(unix)]
    {
        error.raw_os_error() == Some(libc::ELOOP)
    }
    #[cfg(not(unix))]
    {
        error.kind() == std::io::ErrorKind::FilesystemLoop
    }
}

fn assert_not_dangling_link(path: &Path) -> Result<(), HostError> {
    match std::fs::symlink_metadata(path) {
        Ok(info) => {
            if info.file_type().is_symlink() {
                return Err(HostError::Refusal(format!(
                    "path {} is a symlink whose target cannot be resolved",
                    path.display(),
                )));
            }
            Ok(())
        }
        Err(error) if is_not_found(&error) => Ok(()),
        Err(error) => Err(HostError::Io(error)),
    }
}

/// realpath the nearest existing ancestor and re-append the missing suffix.
/// realpath reports NotFound for both a genuinely absent component and a
/// dangling symlink; never reinterpret the latter as a safe create target.
fn canonical_potential_path(path: &Path) -> Result<PathBuf, HostError> {
    let mut cursor = path.to_path_buf();
    let mut suffix: Vec<std::ffi::OsString> = Vec::new();
    loop {
        match std::fs::canonicalize(&cursor) {
            Ok(canonical) => {
                let mut out = canonical;
                for part in suffix.iter().rev() {
                    out.push(part);
                }
                return Ok(out);
            }
            Err(error) if is_not_found(&error) => {
                assert_not_dangling_link(&cursor)?;
                let Some(parent) = cursor.parent().map(Path::to_path_buf) else {
                    return Err(HostError::Io(error));
                };
                if parent == cursor {
                    return Err(HostError::Io(error));
                }
                let Some(name) = cursor.file_name().map(std::ffi::OsStr::to_os_string) else {
                    return Err(HostError::Io(error));
                };
                suffix.push(name);
                cursor = parent;
            }
            Err(error) => return Err(HostError::Io(error)),
        }
    }
}

fn canonical_root_lists(
    root_lists: &[&[String]],
    home: &Path,
) -> Result<Vec<Vec<PathBuf>>, HostError> {
    let mut canonical = Vec::new();
    for roots in root_lists {
        if roots.is_empty() {
            continue;
        }
        let mut list = Vec::new();
        for root in *roots {
            list.push(canonical_potential_path(&expand_path(root, home, home))?);
        }
        canonical.push(list);
    }
    Ok(canonical)
}

fn enforce_canonical_roots(path: &Path, root_lists: &[Vec<PathBuf>]) -> Result<(), String> {
    for roots in root_lists {
        if !roots.iter().any(|root| within_root(path, root)) {
            let joined =
                roots.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ");
            return Err(format!(
                "path {} resolves outside this machine's allowed roots ({joined})",
                path.display(),
            ));
        }
    }
    Ok(())
}

pub struct HostScopedPath {
    pub path: PathBuf,
    roots: Vec<Vec<PathBuf>>,
}

/// Host-aware second pass. Existing paths are realpathed and operations use
/// that canonical path, so a stable symlink inside a workdir/root cannot
/// redirect an operation outside it. Missing write targets canonicalize
/// from the nearest existing ancestor.
pub fn resolve_scoped_host_path(
    raw_path: &str,
    root_lists: &RootLists<'_>,
    home: &Path,
    workdir: &str,
    allow_missing: bool,
) -> Result<Result<HostScopedPath, String>, std::io::Error> {
    let run = || -> Result<HostScopedPath, HostError> {
        let lexical =
            resolve_scoped_path(raw_path, root_lists, home, workdir).map_err(HostError::Refusal)?;
        let workdir_list: Vec<String>;
        let mut effective: Vec<&[String]> = root_lists.iter().flatten().copied().collect();
        if !lexical.absolute_request {
            workdir_list = vec![lexical.workdir.display().to_string()];
            effective.push(&workdir_list);
        }
        let roots = canonical_root_lists(&effective, home)?;
        let path = if allow_missing {
            canonical_potential_path(&lexical.path)?
        } else {
            std::fs::canonicalize(&lexical.path)?
        };
        enforce_canonical_roots(&path, &roots).map_err(HostError::Refusal)?;
        Ok(HostScopedPath { path, roots })
    };
    match run() {
        Ok(scoped) => Ok(Ok(scoped)),
        Err(HostError::Refusal(message)) => Ok(Err(message)),
        Err(HostError::Io(error)) => Err(error),
    }
}

// ---------------------------------------------------------------------------
// Bounded file I/O (O_NOFOLLOW where the host supports it)
// ---------------------------------------------------------------------------

fn open_options_no_follow(read: bool) -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    if read {
        options.read(true);
    } else {
        options.write(true).create(true).truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options
}

fn read_utf8_no_follow(path: &Path) -> Result<String, HostError> {
    use std::io::Read as _;
    let mut file = open_options_no_follow(true).open(path).map_err(|error| {
        if is_eloop(&error) {
            HostError::Refusal("refusing a symlink that changed during read".to_owned())
        } else {
            HostError::Io(error)
        }
    })?;
    let info = file.metadata()?;
    if info.len() > MAX_READ_BYTES {
        return Err(HostError::Refusal(format!(
            "file is {} bytes (max {MAX_READ_BYTES}); read a smaller file or use grep",
            info.len(),
        )));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn write_utf8_no_follow(
    path: &Path,
    content: &str,
    roots: &[Vec<PathBuf>],
) -> Result<(), HostError> {
    use std::io::Write as _;
    let parent = path.parent().unwrap_or(Path::new("."));
    // Check the requested parent before creating anything. Creating an
    // untrusted directory tree first can mutate paths outside the allowed
    // roots, even when the final file check rejects the write.
    enforce_canonical_roots(parent, roots).map_err(HostError::Refusal)?;
    std::fs::create_dir_all(parent)?;
    let canonical_parent = std::fs::canonicalize(parent)?;
    let file_name = path.file_name().map(std::ffi::OsStr::to_os_string).unwrap_or_default();
    let canonical = canonical_parent.join(file_name);
    assert_not_dangling_link(&canonical)?;
    enforce_canonical_roots(&canonical, roots).map_err(HostError::Refusal)?;
    let mut file = open_options_no_follow(false).open(&canonical).map_err(|error| {
        if is_eloop(&error) {
            HostError::Refusal("refusing a symlink that changed during write".to_owned())
        } else {
            HostError::Io(error)
        }
    })?;
    file.write_all(content.as_bytes())?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Output bounds, timeouts, environment
// ---------------------------------------------------------------------------

pub struct TruncatedOutput {
    pub output: String,
    pub truncated: bool,
}

pub fn truncate_output(output: &str, cap: usize) -> TruncatedOutput {
    let total = output.chars().count();
    if total <= cap {
        return TruncatedOutput { output: output.to_owned(), truncated: false };
    }
    let head: String = output.chars().take(cap).collect();
    TruncatedOutput {
        output: format!("{head}\n…[truncated {} characters]", total - cap),
        truncated: true,
    }
}

pub fn clamp_timeout(requested: Option<&Value>) -> u64 {
    let value = requested.and_then(Value::as_f64).unwrap_or(0.0);
    if !value.is_finite() || value <= 0.0 {
        return DEFAULT_TIMEOUT_MS;
    }
    (value.trunc() as u64).clamp(1_000, MAX_TIMEOUT_MS)
}

/// Minimal, non-secret environment for spawned commands.
pub fn scrubbed_env(base: &HashMap<String, String>) -> HashMap<String, String> {
    let keep = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL"];
    let mut env = HashMap::new();
    for key in keep {
        if let Some(value) = base.get(key) {
            env.insert(key.to_owned(), value.clone());
        }
    }
    env.insert("TERM".to_owned(), "dumb".to_owned());
    env
}

pub fn process_env_snapshot() -> HashMap<String, String> {
    std::env::vars().collect()
}

fn valid_environment_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) if first.is_ascii_alphabetic() || first == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub struct ProcessRuntime {
    pub environment: HashMap<String, String>,
    pub files: Vec<RuntimeFile>,
}

pub struct RuntimeFile {
    pub content_environment_variable: String,
    pub path_environment_variable: String,
    pub path_hint: String,
}

/// Validate the secret-bearing frame field without returning secret text in
/// errors (v5 one-call process credentials).
pub fn process_runtime(frame_runtime: Option<&Value>) -> Result<ProcessRuntime, String> {
    let Some(runtime) = frame_runtime else {
        return Ok(ProcessRuntime { environment: HashMap::new(), files: Vec::new() });
    };
    let invalid = || "process runtime is invalid".to_owned();
    let object = runtime.as_object().ok_or_else(invalid)?;
    let environment_value =
        object.get("environment").and_then(Value::as_object).ok_or_else(invalid)?;
    let files_value = object.get("files").and_then(Value::as_array).ok_or_else(invalid)?;
    if environment_value.len() > MAX_RUNTIME_ENVIRONMENT_ENTRIES {
        return Err("process runtime has too many environment values".to_owned());
    }
    let mut environment = HashMap::new();
    let mut bytes = 0_usize;
    for (name, value) in environment_value {
        let Some(value) = value.as_str() else {
            return Err("process runtime environment is invalid".to_owned());
        };
        if !valid_environment_name(name) {
            return Err("process runtime environment is invalid".to_owned());
        }
        bytes += name.len() + value.len();
        if bytes > MAX_RUNTIME_ENVIRONMENT_BYTES || value.contains('\0') {
            return Err("process runtime environment is too large or invalid".to_owned());
        }
        environment.insert(name.clone(), value.to_owned());
    }
    if files_value.len() > MAX_RUNTIME_FILES {
        return Err("process runtime has too many files".to_owned());
    }
    let mut files = Vec::new();
    for file in files_value {
        let content = file
            .get("contentEnvironmentVariable")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let path_var = file
            .get("pathEnvironmentVariable")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let path_hint = file.get("pathHint").and_then(Value::as_str);
        if !valid_environment_name(&content)
            || !valid_environment_name(&path_var)
            || path_hint.is_none()
            || !environment.contains_key(&content)
        {
            return Err("process runtime file is invalid".to_owned());
        }
        files.push(RuntimeFile {
            content_environment_variable: content,
            path_environment_variable: path_var,
            path_hint: path_hint.unwrap_or_default().to_owned(),
        });
    }
    Ok(ProcessRuntime { environment, files })
}

/// Build a POSIX supervisor. No secret value enters the command string.
pub fn command_with_process_files(command: &str, files: &[RuntimeFile]) -> String {
    if files.is_empty() {
        return command.to_owned();
    }
    let mut setup: Vec<String> = vec!["set +e".to_owned(), "umask 077".to_owned()];
    let mut cleanup: Vec<String> = Vec::new();
    for (index, file) in files.iter().enumerate() {
        let sanitized: String = file
            .path_hint
            .chars()
            .map(
                |c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '-' },
            )
            .take(80)
            .collect();
        let hint = if sanitized.is_empty() { "secret".to_owned() } else { sanitized };
        let shell_path = format!("__chatmux_file_{index}");
        setup.push(format!("{shell_path}=$(mktemp \"${{TMPDIR:-/tmp}}/chatmux-{hint}.XXXXXX\")"));
        setup.push(format!("chmod 600 \"${shell_path}\""));
        setup.push(format!(
            "printf '%s' \"${}\" > \"${shell_path}\"",
            file.content_environment_variable,
        ));
        setup.push(format!("unset {}", file.content_environment_variable));
        setup.push(format!("export {}=\"${shell_path}\"", file.path_environment_variable,));
        cleanup.push(format!("rm -f -- \"${shell_path}\""));
    }
    let cleanup_body = cleanup.join("; ");
    setup.push(format!("__chatmux_cleanup() {{ {cleanup_body}; }}"));
    setup.push("trap __chatmux_cleanup EXIT".to_owned());
    setup.push("trap 'exit 143' HUP INT TERM".to_owned());
    setup.push(format!("( /bin/sh -c {} )", shell_quote(command)));
    setup.push("__chatmux_status=$?".to_owned());
    setup.push("__chatmux_cleanup".to_owned());
    setup.push("trap - EXIT HUP INT TERM".to_owned());
    setup.push("exit $__chatmux_status".to_owned());
    setup.join("\n")
}

// ---------------------------------------------------------------------------
// Bounded spawn with a hard process-group timeout
// ---------------------------------------------------------------------------

enum RunSpec<'a> {
    Shell { command: &'a str },
    Argv { file: &'a str, args: Vec<String> },
}

enum RunOutcome {
    Done { exit_code: i64, output: String },
    TimedOut { tail: String },
    Failed { message: String },
}

async fn run_spec(
    spec: RunSpec<'_>,
    cwd: &Path,
    timeout_ms: u64,
    env: &HashMap<String, String>,
) -> RunOutcome {
    use tokio::io::AsyncReadExt as _;
    let mut command = match &spec {
        RunSpec::Shell { command } => {
            let mut shell = tokio::process::Command::new("/bin/sh");
            shell.arg("-c").arg(command);
            shell
        }
        RunSpec::Argv { file, args } => {
            let mut argv = tokio::process::Command::new(file);
            argv.args(args);
            argv
        }
    };
    command.current_dir(cwd).env_clear().envs(env);
    command.stdin(std::process::Stdio::null());
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => return RunOutcome::Failed { message: "process failed to start".to_owned() },
    };
    let pid = child.id();
    // Collect a little past the char cap (bytes over-approximate chars).
    let byte_cap = (MAX_OUTPUT_CHARS + 10_000) * 4;
    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let mut output: Vec<u8> = Vec::new();
    let mut timed_out = false;
    let deadline = tokio::time::sleep(std::time::Duration::from_millis(timeout_ms));
    tokio::pin!(deadline);
    let mut stdout_buf = [0_u8; 8_192];
    let mut stderr_buf = [0_u8; 8_192];
    let mut stdout_open = stdout.is_some();
    let mut stderr_open = stderr.is_some();
    let mut exited: Option<i64> = None;
    let mut kill_deadline: Option<std::pin::Pin<Box<tokio::time::Sleep>>> = None;
    let mut drain_deadline: Option<std::pin::Pin<Box<tokio::time::Sleep>>> = None;
    loop {
        if exited.is_some() && !stdout_open && !stderr_open {
            break;
        }
        tokio::select! {
            read = async {
                match stdout.as_mut() {
                    Some(stream) => stream.read(&mut stdout_buf).await,
                    None => std::future::pending().await,
                }
            }, if stdout_open => {
                match read {
                    Ok(0) | Err(_) => stdout_open = false,
                    Ok(count) => {
                        if output.len() < byte_cap {
                            output.extend_from_slice(&stdout_buf[..count]);
                        }
                    }
                }
            }
            read = async {
                match stderr.as_mut() {
                    Some(stream) => stream.read(&mut stderr_buf).await,
                    None => std::future::pending().await,
                }
            }, if stderr_open => {
                match read {
                    Ok(0) | Err(_) => stderr_open = false,
                    Ok(count) => {
                        if output.len() < byte_cap {
                            output.extend_from_slice(&stderr_buf[..count]);
                        }
                    }
                }
            }
            status = child.wait(), if exited.is_none() => {
                // The child is gone. Do not let a pending escalation signal
                // fire against a PID that the OS may reuse while descendants
                // keep the output pipes open.
                kill_deadline = None;
                if timed_out {
                    drain_deadline = Some(Box::pin(tokio::time::sleep(
                        std::time::Duration::from_millis(250),
                    )));
                }
                exited = Some(match status {
                    Ok(status) => status.code().map(i64::from).unwrap_or(1),
                    Err(_) => 1,
                });
            }
            () = &mut deadline, if !timed_out => {
                timed_out = true;
                // Commands run below a shell and may have descendants that
                // inherited stdout/stderr. Kill the whole POSIX process group
                // so the supervisor gets its EXIT cleanup, then enforce a
                // hard bound for processes that ignore TERM.
                signal_process_tree(pid, false);
                // Keep the escalation timer owned by this invocation. A
                // detached task could fire after the process exits and its
                // PID is reused by an unrelated process.
                kill_deadline = Some(Box::pin(tokio::time::sleep(
                    std::time::Duration::from_millis(250),
                )));
            }
            () = async {
                match kill_deadline.as_mut() {
                    Some(timer) => timer.as_mut().await,
                    None => std::future::pending().await,
                }
            }, if kill_deadline.is_some() => {
                signal_process_tree(pid, true);
                kill_deadline = None;
            }
            () = async {
                match drain_deadline.as_mut() {
                    Some(timer) => timer.as_mut().await,
                    None => std::future::pending().await,
                }
            }, if drain_deadline.is_some() => {
                stdout_open = false;
                stderr_open = false;
                drain_deadline = None;
            }
        }
    }
    let text = String::from_utf8_lossy(&output);
    if timed_out {
        let tail: String = {
            let chars: Vec<char> = text.chars().collect();
            let start = chars.len().saturating_sub(2_000);
            chars[start..].iter().collect()
        };
        return RunOutcome::TimedOut { tail };
    }
    RunOutcome::Done { exit_code: exited.unwrap_or(0), output: text.into_owned() }
}

#[cfg(unix)]
fn signal_process_tree(pid: Option<u32>, kill: bool) {
    let Some(pid) = pid else { return };
    let signal = if kill { libc::SIGKILL } else { libc::SIGTERM };
    // SAFETY: sending a signal to a process group id we spawned; failure is
    // harmless (the group may have exited already).
    let group = -(pid as i32);
    unsafe {
        if libc::kill(group, signal) != 0 {
            libc::kill(pid as i32, signal);
        }
    }
}

#[cfg(not(unix))]
fn signal_process_tree(_pid: Option<u32>, _kill: bool) {}

fn cap_lines(output: &str, truncated: bool, limit: Option<&Value>) -> (String, bool) {
    let Some(limit) = limit.and_then(Value::as_f64).filter(|v| v.is_finite()) else {
        return (output.to_owned(), truncated);
    };
    let cap = (limit.trunc() as i64).clamp(1, 5_000) as usize;
    let lines: Vec<&str> = output.split('\n').collect();
    if lines.len() <= cap {
        return (output.to_owned(), truncated);
    }
    (format!("{}\n…[{} more lines]", lines[..cap].join("\n"), lines.len() - cap), true)
}

// ---------------------------------------------------------------------------
// The verb dispatcher
// ---------------------------------------------------------------------------

pub struct ActionContext {
    /// The machine's reconciled trust (config after the trust_ack handshake),
    /// never the frame's echo alone.
    pub trust: String,
    pub local_roots: Option<Vec<String>>,
    pub home: PathBuf,
    /// Scrubbed base environment for spawns.
    pub env: HashMap<String, String>,
}

fn frame_roots(frame: &Value) -> Option<Vec<String>> {
    frame
        .get("allowedRoots")
        .and_then(Value::as_array)
        .map(|roots| roots.iter().filter_map(Value::as_str).map(str::to_owned).collect())
}

fn ok_result(version: i64, action_id: &str, result: Value) -> Value {
    json!({
        "version": version,
        "type": "action_result",
        "actionId": action_id,
        "ok": true,
        "result": result,
    })
}

fn run_reply(
    version: i64,
    action_id: &str,
    outcome: RunOutcome,
    limit: Option<&Value>,
    default_limit: Option<i64>,
    timeout_ms: u64,
) -> Value {
    let default_value = default_limit.map(Value::from);
    let limit = limit.or(default_value.as_ref());
    match outcome {
        RunOutcome::Failed { message } => fail_result(version, action_id, "failed", &message),
        RunOutcome::TimedOut { .. } => {
            let seconds = (timeout_ms as f64 / 1000.0).round() as u64;
            fail_result(
                version,
                action_id,
                "timeout",
                &format!("command timed out after {seconds}s"),
            )
        }
        RunOutcome::Done { exit_code, output } => {
            let bounded = truncate_output(&output, MAX_OUTPUT_CHARS);
            let (capped, truncated) = cap_lines(&bounded.output, bounded.truncated, limit);
            let mut result = Map::new();
            result.insert("exitCode".to_owned(), Value::from(exit_code));
            result.insert("output".to_owned(), Value::from(capped));
            if truncated {
                result.insert("truncated".to_owned(), Value::from(true));
            }
            ok_result(version, action_id, Value::Object(result))
        }
    }
}

fn fail_result(version: i64, action_id: &str, code: &str, message: &str) -> Value {
    json!({
        "version": version,
        "type": "action_result",
        "actionId": action_id,
        "ok": false,
        "code": code,
        "message": message,
    })
}

/// Execute one action_request frame. Returns the `action_result` frame to
/// send back (never fails).
pub async fn perform_action(frame: &Value, context: &ActionContext) -> Value {
    let version = frame.get("version").and_then(Value::as_i64).unwrap_or(3);
    let action_id = frame.get("actionId").and_then(Value::as_str).unwrap_or_default().to_owned();
    let fail = |code: &str, message: &str| fail_result(version, &action_id, code, message);

    let verb = frame.get("verb").and_then(Value::as_str).unwrap_or_default().to_owned();
    if !ACTION_VERBS.contains(&verb.as_str()) {
        return fail("unsupported_verb", &format!("this relay does not support verb \"{verb}\""));
    }

    // Owner-side trust floor: the server gates too, but the machine's own
    // config is authoritative here.
    if context.trust == "observe" && !READ_ONLY_VERBS.contains(&verb.as_str()) {
        return fail(
            "trust_refused",
            &format!("this machine is paired at observe trust; \"{verb}\" is not a read-only verb"),
        );
    }

    let home = context.home.clone();
    let server_roots = frame_roots(frame);
    let root_lists: RootLists<'_> = [context.local_roots.as_deref(), server_roots.as_deref()];
    let empty_args = Map::new();
    let args = frame.get("args").and_then(Value::as_object).unwrap_or(&empty_args);
    let timeout_ms = clamp_timeout(frame.get("timeoutMs"));
    let runtime = match process_runtime(frame.get("runtime")) {
        Ok(runtime) => runtime,
        Err(message) => return fail("failed", &message),
    };
    if verb != "exec" && (!runtime.environment.is_empty() || !runtime.files.is_empty()) {
        return fail("failed", "process runtime is valid only for exec");
    }
    if cfg!(windows) && !runtime.files.is_empty() {
        return fail("failed", "process file bindings are not available on Windows relays");
    }
    let mut env = context.env.clone();
    env.extend(runtime.environment.clone());
    let first_roots = root_lists.iter().flatten().find(|roots| !roots.is_empty());
    let workdir = match first_roots {
        Some(roots) => expand_path(&roots[0], &home, &home).display().to_string(),
        None => home.display().to_string(),
    };
    let scoped = |raw: &str, allow_missing: bool| {
        resolve_scoped_host_path(raw, &root_lists, &home, &workdir, allow_missing)
    };
    // Host paths and OS errors can contain private filesystem details. Keep
    // those details in local diagnostics, never in the remote action result.
    let io_fail =
        |_error: std::io::Error| fail_result(version, &action_id, "failed", "operation failed");

    match verb.as_str() {
        "read" => {
            let Some(raw) = args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty())
            else {
                return fail("failed", "read: path is required");
            };
            let path = match scoped(raw, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            match read_utf8_no_follow(&path.path) {
                Ok(content) => ok_result(version, &action_id, json!({ "content": content })),
                Err(HostError::Refusal(message)) => fail("path_forbidden", &message),
                Err(HostError::Io(error)) if is_eloop(&error) => {
                    fail("path_forbidden", "path contains a symlink loop")
                }
                Err(HostError::Io(error)) => io_fail(error),
            }
        }
        "write" => {
            let Some(raw) = args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty())
            else {
                return fail("failed", "write: path is required");
            };
            let path = match scoped(raw, true) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            let content = args.get("content").and_then(Value::as_str).unwrap_or_default();
            match write_utf8_no_follow(&path.path, content, &path.roots) {
                Ok(()) => ok_result(version, &action_id, json!({})),
                Err(HostError::Refusal(message)) => fail("path_forbidden", &message),
                Err(HostError::Io(error)) if is_eloop(&error) => {
                    fail("path_forbidden", "path contains a symlink loop")
                }
                Err(HostError::Io(error)) => io_fail(error),
            }
        }
        "ls" => {
            let raw =
                args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let path = match scoped(raw, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            let entries = match std::fs::read_dir(&path.path) {
                Ok(entries) => entries,
                Err(error) => return io_fail(error),
            };
            let mut names: Vec<String> = Vec::new();
            let mut total = 0_usize;
            for entry in entries.flatten() {
                total += 1;
                if names.len() >= MAX_LISTING_ENTRIES {
                    continue;
                }
                let name = entry.file_name().to_string_lossy().into_owned();
                let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
                names.push(if is_dir { format!("{name}/") } else { name });
            }
            names.sort();
            let more = if total > MAX_LISTING_ENTRIES {
                format!("\n…[{} more entries]", total - MAX_LISTING_ENTRIES)
            } else {
                String::new()
            };
            ok_result(
                version,
                &action_id,
                json!({ "listing": format!("{}{more}", names.join("\n")) }),
            )
        }
        "grep" => {
            let raw =
                args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let path = match scoped(raw, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            let pattern = args.get("pattern").and_then(Value::as_str).unwrap_or_default();
            if pattern.is_empty() {
                return fail("failed", "grep: pattern is required");
            }
            if cfg!(windows) {
                return fail("unsupported_verb", "grep is not available on Windows relays yet");
            }
            let command_cwd = match scoped(".", false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            let outcome = run_spec(
                RunSpec::Argv {
                    file: "grep",
                    args: vec![
                        "-rIn".to_owned(),
                        "--exclude-dir=.git".to_owned(),
                        "--exclude-dir=node_modules".to_owned(),
                        "-e".to_owned(),
                        pattern.to_owned(),
                        "--".to_owned(),
                        path.path.display().to_string(),
                    ],
                },
                &command_cwd.path,
                timeout_ms,
                &env,
            )
            .await;
            run_reply(version, &action_id, outcome, args.get("limit"), Some(200), timeout_ms)
        }
        "find" => {
            let raw =
                args.get("path").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let path = match scoped(raw, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            if cfg!(windows) {
                return fail("unsupported_verb", "find is not available on Windows relays yet");
            }
            let command_cwd = match scoped(".", false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            let mut find_args = vec![path.path.display().to_string()];
            if let Some(pattern) =
                args.get("pattern").and_then(Value::as_str).filter(|p| !p.is_empty())
            {
                find_args.push("-name".to_owned());
                find_args.push(pattern.to_owned());
            }
            let outcome = run_spec(
                RunSpec::Argv { file: "find", args: find_args },
                &command_cwd.path,
                timeout_ms,
                &env,
            )
            .await;
            run_reply(version, &action_id, outcome, args.get("limit"), Some(500), timeout_ms)
        }
        "exec" => {
            let command = args.get("command").and_then(Value::as_str).unwrap_or_default();
            if command.is_empty() {
                return fail("failed", "exec: command is required");
            }
            // Default and explicit relative cwds use the same canonical
            // workdir policy as every file verb. This also enforces the
            // intersection when the root lists do not overlap.
            let raw_cwd =
                args.get("cwd").and_then(Value::as_str).filter(|p| !p.is_empty()).unwrap_or(".");
            let scoped_cwd = match scoped(raw_cwd, false) {
                Ok(Ok(path)) => path,
                Ok(Err(message)) => return fail("path_forbidden", &message),
                Err(error) => return io_fail(error),
            };
            let prepared = command_with_process_files(command, &runtime.files);
            let outcome =
                run_spec(RunSpec::Shell { command: &prepared }, &scoped_cwd.path, timeout_ms, &env)
                    .await;
            run_reply(version, &action_id, outcome, None, None, timeout_ms)
        }
        _ => fail("unsupported_verb", &format!("verb \"{verb}\" fell through")),
    }
}

// ---------------------------------------------------------------------------
// Tests — mirror packages/relay/test/actions.test.mjs.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn home() -> PathBuf {
        PathBuf::from("/home/u")
    }

    fn ctx(trust: &str, roots: Option<Vec<String>>, home: PathBuf) -> ActionContext {
        ActionContext { trust: trust.to_owned(), local_roots: roots, home, env: HashMap::new() }
    }

    fn scratch(name: &str) -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("chatmux-actions-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // realpath so canonical checks match (macOS /tmp -> /private/tmp).
        std::fs::canonicalize(&dir).unwrap()
    }

    #[test]
    fn expand_path_handles_tilde_relative_and_absolute() {
        assert_eq!(expand_path("~", &home(), &home()), home());
        assert_eq!(expand_path("~/x", &home(), &home()), PathBuf::from("/home/u/x"));
        assert_eq!(expand_path("/abs", &home(), Path::new("/base")), PathBuf::from("/abs"));
        assert_eq!(expand_path("rel", &home(), Path::new("/base")), PathBuf::from("/base/rel"));
        assert_eq!(expand_path("a/../b", &home(), Path::new("/base")), PathBuf::from("/base/b"));
    }

    #[test]
    fn resolve_scoped_path_enforces_every_nonempty_root_list() {
        let roots_a = vec!["/home/u/work".to_owned()];
        let roots_b = vec!["/home/u/work/sub".to_owned()];
        let lists: RootLists = [Some(roots_a.as_slice()), Some(roots_b.as_slice())];
        // Inside both: ok.
        let ok = resolve_scoped_path("/home/u/work/sub/file", &lists, &home(), "/home/u/work/sub");
        assert!(ok.is_ok());
        // Inside A but outside B: refused.
        let refused = resolve_scoped_path("/home/u/work/other", &lists, &home(), "/home/u/work");
        assert!(refused.is_err());
    }

    #[test]
    fn relative_paths_stay_in_the_workdir() {
        let roots = vec!["/home/u/work".to_owned()];
        let lists: RootLists = [Some(roots.as_slice()), None];
        assert!(resolve_scoped_path("../escape", &lists, &home(), "/home/u/work").is_err());
        assert!(resolve_scoped_path("./nested/../ok", &lists, &home(), "/home/u/work").is_ok());
        // Encoded and control-character variants are refused.
        assert!(resolve_scoped_path("a%2e%2e/b", &lists, &home(), "/home/u/work").is_err());
        assert!(resolve_scoped_path("a\u{0000}b", &lists, &home(), "/home/u/work").is_err());
    }

    #[test]
    fn truncate_output_caps_and_marks() {
        let short = truncate_output("hi", MAX_OUTPUT_CHARS);
        assert!(!short.truncated);
        let long = "x".repeat(MAX_OUTPUT_CHARS + 5);
        let capped = truncate_output(&long, MAX_OUTPUT_CHARS);
        assert!(capped.truncated);
        assert!(capped.output.contains("truncated 5 characters"));
    }

    #[test]
    fn clamp_timeout_bounds() {
        assert_eq!(clamp_timeout(None), DEFAULT_TIMEOUT_MS);
        assert_eq!(clamp_timeout(Some(&json!(50))), 1_000);
        assert_eq!(clamp_timeout(Some(&json!(9_999_999))), MAX_TIMEOUT_MS);
        assert_eq!(clamp_timeout(Some(&json!(-5))), DEFAULT_TIMEOUT_MS);
    }

    #[test]
    fn scrubbed_env_drops_secrets_keeps_path_home() {
        let base = HashMap::from([
            ("PATH".to_owned(), "/usr/bin".to_owned()),
            ("HOME".to_owned(), "/home/u".to_owned()),
            ("OPENAI_API_KEY".to_owned(), "sekret".to_owned()),
        ]);
        let env = scrubbed_env(&base);
        assert_eq!(env.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(env.get("HOME").map(String::as_str), Some("/home/u"));
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert_eq!(env.get("TERM").map(String::as_str), Some("dumb"));
    }

    #[tokio::test]
    async fn read_write_ls_round_trip_inside_allowed_roots() {
        let root = scratch("rw");
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        // write
        let write = perform_action(
            &json!({ "verb": "write", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "note.txt", "content": "hello" } }),
            &context,
        )
        .await;
        assert_eq!(write["ok"], true, "{write}");
        // read
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a2", "allowedRoots": roots,
                     "args": { "path": "note.txt" } }),
            &context,
        )
        .await;
        assert_eq!(read["result"]["content"], "hello");
        // ls
        let ls = perform_action(
            &json!({ "verb": "ls", "actionId": "a3", "allowedRoots": roots, "args": {} }),
            &context,
        )
        .await;
        assert!(ls["result"]["listing"].as_str().unwrap().contains("note.txt"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn file_verbs_outside_roots_are_path_forbidden() {
        let root = scratch("scoped");
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "/etc/hosts" } }),
            &context,
        )
        .await;
        assert_eq!(read["ok"], false);
        assert_eq!(read["code"], "path_forbidden");
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn symlinks_cannot_escape_allowed_roots() {
        let root = scratch("symlink");
        let outside = scratch("outside");
        std::fs::write(outside.join("secret.txt"), "top secret").unwrap();
        // A symlink inside the root pointing outside it.
        std::os::unix::fs::symlink(&outside, root.join("escape")).unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("supervised", Some(roots.clone()), root.clone());
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "escape/secret.txt" } }),
            &context,
        )
        .await;
        assert_eq!(read["ok"], false);
        assert_eq!(read["code"], "path_forbidden");
        std::fs::remove_dir_all(&root).ok();
        std::fs::remove_dir_all(&outside).ok();
    }

    #[tokio::test]
    async fn exec_runs_with_cwd_discipline_and_returns_exit_code_and_output() {
        let root = scratch("exec");
        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        context.env =
            scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let exec = perform_action(
            &json!({ "verb": "exec", "actionId": "a1", "allowedRoots": roots,
                     "args": { "command": "echo hi && pwd" }, "timeoutMs": 10000 }),
            &context,
        )
        .await;
        assert_eq!(exec["ok"], true, "{exec}");
        assert_eq!(exec["result"]["exitCode"], 0);
        let output = exec["result"]["output"].as_str().unwrap();
        assert!(output.contains("hi"));
        assert!(output.contains(&root.display().to_string()));
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn exec_receives_scoped_process_environment_values() {
        let root = scratch("procenv");
        let roots = vec![root.display().to_string()];
        let mut context = ctx("supervised", Some(roots.clone()), root.clone());
        context.env =
            scrubbed_env(&HashMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]));
        let exec = perform_action(
            &json!({ "verb": "exec", "actionId": "a1", "allowedRoots": roots,
                     "args": { "command": "printf '%s' \"$MY_TOKEN\"" }, "timeoutMs": 10000,
                     "runtime": { "environment": { "MY_TOKEN": "abc123" }, "files": [] } }),
            &context,
        )
        .await;
        assert_eq!(exec["result"]["output"], "abc123");
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn observe_trust_refuses_mutating_verbs_allows_reads() {
        let root = scratch("observe");
        std::fs::write(root.join("f.txt"), "data").unwrap();
        let roots = vec![root.display().to_string()];
        let context = ctx("observe", Some(roots.clone()), root.clone());
        let write = perform_action(
            &json!({ "verb": "write", "actionId": "a1", "allowedRoots": roots,
                     "args": { "path": "x.txt", "content": "no" } }),
            &context,
        )
        .await;
        assert_eq!(write["code"], "trust_refused");
        let read = perform_action(
            &json!({ "verb": "read", "actionId": "a2", "allowedRoots": roots,
                     "args": { "path": "f.txt" } }),
            &context,
        )
        .await;
        assert_eq!(read["ok"], true);
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn unknown_verbs_answer_unsupported_verb() {
        let context = ctx("supervised", None, home());
        let result =
            perform_action(&json!({ "verb": "nope", "actionId": "a1", "args": {} }), &context)
                .await;
        assert_eq!(result["ok"], false);
        assert_eq!(result["code"], "unsupported_verb");
    }

    #[tokio::test]
    async fn invalid_process_runtime_does_not_reflect_credential_bytes() {
        let context = ctx("supervised", None, home());
        let result = perform_action(
            &json!({ "verb": "exec", "actionId": "a1", "args": { "command": "true" },
                     "runtime": { "environment": { "BAD NAME": "sekret-value" }, "files": [] } }),
            &context,
        )
        .await;
        assert_eq!(result["ok"], false);
        assert!(!result["message"].as_str().unwrap().contains("sekret-value"));
    }
}

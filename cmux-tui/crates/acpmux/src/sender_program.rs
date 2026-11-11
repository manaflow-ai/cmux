//! Which program ran an `acpmux send`, as the daemon finds it from the unix socket's peer pid
//! (never as the sender says), and the host's registry of first-party senders that makes a named
//! sender's prompt `verified` by its program.
//!
//! Leo, 2026-11-11, on our own outbox relay's notice drawn as "Unverified sender" with an "Xcode"
//! chip (Xcode's bundled Python ran the relay script): "surely this could be more... idk.
//! generally the "unverified sender" things should be more verified". So the daemon names the
//! program itself: the nearest process above the acpmux CLI that is not acpmux (a shell that
//! only passes a command on, `sh -c`, is walked past), by its executable, and for an interpreter
//! (python, node, bun, deno, ruby, perl, or a shell running a script file) by the script it runs,
//! read from the process's own argv (`/proc/<pid>/cmdline` on Linux, `KERN_PROCARGS2` on macOS).
//!
//! The registry is `senders.json` in the daemon's home (`~/.acpmux/senders.json`), a file only
//! its owner may write (mode 0600, owned by the daemon's uid; any other is ignored):
//!
//! ```json
//! {"senders": {"outbox-relay": {"programs": ["/Users/me/tools/outbox_relay.py"]},
//!              "glaeda-gh": {"programs": ["/Users/me/.local/bin/glaeda-gh"]}}}
//! ```
//!
//! A send whose process chain runs one of a name's programs (the nearest program, or any process
//! above it, so a tool run under a wrapper still matches) is that name's: a prompt naming it
//! (`--from`, `ACPMUX_FROM`, a notice's sender) is `verified: true, verifiedBy: "program"`, and
//! one naming no sender takes the registry's name. Anything else stays unverified and carries
//! what the daemon `identified` instead of what it claimed. Verified only changes how a prompt is
//! labelled: it never makes a prompt the person's or the owner's (`server/requests.rs`
//! `owner_terminal`, `person_admitted` read none of this), never binds a session (`fromSessionId`),
//! and decides nothing a prompt may do. The trust is the machine's user, as the unix socket's is.

use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::path::Path;

/// The registry's file name, in the daemon's home (`config::home`).
pub const REGISTRY_FILE: &str = "senders.json";
/// `verifiedBy` of a prompt the registry verified.
pub const VERIFIED_BY_PROGRAM: &str = "program";
/// Where a provenance carries what the daemon identified of an unverified sender.
pub const IDENTIFIED: &str = "identified";
/// Most parents walked from a pid.
const MAX_HOPS: usize = 32;
/// Most arguments read of one process.
const MAX_ARGS: usize = 64;
/// Most registry names one send records.
const MAX_REGISTERED: usize = 8;
/// Longest sender name, in characters (`hub::MAX_FROM_AGENT_CHARS`).
const MAX_NAME_CHARS: usize = 64;
/// Longest recorded path, in bytes.
const MAX_PATH_BYTES: usize = 1024;

/// One process as program identification reads it: its executable (a full path where the kernel
/// gives one), its arguments and its working directory.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProcInfo {
    pub pid: u32,
    pub ppid: u32,
    pub exe: String,
    pub argv: Vec<String>,
    pub cwd: Option<String>,
}

/// The program found: a script's or an executable's base name, its absolute path when known,
/// and the interpreter that runs it when it is a script.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Program {
    pub name: String,
    pub path: Option<String>,
    pub interpreter: Option<String>,
}

/// What a walk from a send's peer pid found: the nearest program, and every path in the chain
/// above the acpmux CLI (each process's executable and script), nearest first, for the registry.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Programs {
    pub nearest: Option<Program>,
    pub paths: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Interpreter {
    Python,
    Node,
    Bun,
    Deno,
    Ruby,
    Perl,
    Shell,
}

fn interpreter(name: &str) -> Option<Interpreter> {
    let lower = name.to_ascii_lowercase();
    let python = lower
        .strip_prefix("python")
        .is_some_and(|v| v.chars().all(|c| c.is_ascii_digit() || c == '.'));
    Some(match lower.as_str() {
        _ if python => Interpreter::Python,
        "node" | "nodejs" => Interpreter::Node,
        "bun" => Interpreter::Bun,
        "deno" => Interpreter::Deno,
        "ruby" => Interpreter::Ruby,
        "perl" => Interpreter::Perl,
        "sh" | "bash" | "zsh" | "dash" => Interpreter::Shell,
        _ => return None,
    })
}

fn basename(path: &str) -> &str {
    let name = path.trim_start_matches('-');
    name.rsplit('/').next().unwrap_or(name)
}

/// A short option cluster (`-lc`, `-e`): its letters.
fn short_flags(arg: &str) -> Option<&str> {
    arg.strip_prefix('-').filter(|rest| !rest.is_empty() && !rest.starts_with('-'))
}

/// Whether `arg` ends the options with code given inline, so no script file follows.
fn inline_code(kind: Interpreter, arg: &str) -> bool {
    let short = short_flags(arg).unwrap_or_default();
    match kind {
        Interpreter::Python => short.contains(['c', 'm']),
        Interpreter::Shell => short.contains('c'),
        Interpreter::Node | Interpreter::Bun => {
            matches!(arg, "-e" | "--eval" | "-p" | "--print")
        }
        Interpreter::Ruby | Interpreter::Perl => short.starts_with(['e', 'E']),
        Interpreter::Deno => false,
    }
}

/// Whether option `arg` takes the next argument as its value.
fn takes_value(kind: Interpreter, arg: &str) -> bool {
    match kind {
        Interpreter::Python => matches!(arg, "-W" | "-X" | "-Q"),
        Interpreter::Node => {
            matches!(arg, "-r" | "--require" | "--import" | "--loader" | "-C" | "--conditions")
        }
        Interpreter::Shell => matches!(arg, "-o" | "+o" | "-O" | "+O"),
        _ => false,
    }
}

/// The script argument an interpreter's argv names: its first argument that is no option, past
/// bun's and deno's `run`. `None` with inline code (`-c`, `-m`, `-e`) or none at all.
fn script_arg(kind: Interpreter, argv: &[String]) -> Option<&str> {
    let mut args = argv.iter().skip(1).map(String::as_str);
    let mut first = true;
    while let Some(arg) = args.next() {
        if arg == "--" {
            return args.next();
        }
        let option = arg.starts_with('-') || (kind == Interpreter::Shell && arg.starts_with('+'));
        if arg.len() > 1 && option {
            if inline_code(kind, arg) {
                return None;
            }
            if takes_value(kind, arg) {
                args.next();
            }
            continue;
        }
        if first && matches!(kind, Interpreter::Bun | Interpreter::Deno) && arg == "run" {
            first = false;
            continue;
        }
        return Some(arg);
    }
    None
}

/// Whether a shell only runs a command string (`sh -c CMD`): it passes the command on, so the
/// program is the one above it.
fn passes_command_on(argv: &[String]) -> bool {
    argv.iter()
        .skip(1)
        .take_while(|a| a.starts_with('-') || a.starts_with('+'))
        .any(|a| inline_code(Interpreter::Shell, a))
}

fn fits_path(path: &str) -> bool {
    path.starts_with('/') && path.len() <= MAX_PATH_BYTES && !path.chars().any(char::is_control)
}

/// Walk up from `pid` (the socket's peer: the acpmux CLI, or a script speaking to the socket
/// itself), one parent at a time:
/// the nearest program above it, and every path the chain runs. `resolve(arg, cwd)` gives a script
/// argument's absolute canonical path when it names a regular file.
pub fn programs(
    read: impl Fn(u32) -> Option<ProcInfo>,
    resolve: impl Fn(&str, Option<&str>) -> Option<String>,
    pid: u32,
) -> Programs {
    let mut found = Programs::default();
    let mut passed_shell = None;
    let mut at = pid;
    for hop in 0..MAX_HOPS {
        let Some(p) = read(at) else { break };
        let name = basename(&p.exe);
        let kind = interpreter(name);
        // The socket's peer is the acpmux CLI, whatever its file is called (cmux.app's resolves
        // to `cmux`), unless it is an interpreter: a script speaking to the socket itself.
        let peer_cli = hop == 0 && kind.is_none();
        if !peer_cli && name != "acpmux" && !name.is_empty() {
            // A script named but not found (a relative path where the working directory is not
            // read, macOS) is still named, with no path: it matches no registry entry.
            let named = kind.and_then(|k| script_arg(k, &p.argv));
            let script = named.and_then(|s| resolve(s, p.cwd.as_deref()));
            let exe_path = fits_path(&p.exe).then(|| p.exe.clone());
            for path in [&exe_path, &script].into_iter().flatten() {
                if !found.paths.contains(path) {
                    found.paths.push(path.clone());
                }
            }
            let program = match (&script, named) {
                (Some(script), _) => Program {
                    name: basename(script).to_owned(),
                    path: Some(script.clone()),
                    interpreter: Some(name.to_owned()),
                },
                (None, Some(named)) if !basename(named).is_empty() => Program {
                    name: basename(named).to_owned(),
                    path: None,
                    interpreter: Some(name.to_owned()),
                },
                _ => Program { name: name.to_owned(), path: exe_path, interpreter: None },
            };
            let passes =
                named.is_none() && kind == Some(Interpreter::Shell) && passes_command_on(&p.argv);
            // The wrapper script that runs the CLI (`cli_caller::wrapper_path`, `<home>/bin/acpmux`)
            // is acpmux itself, not the sender.
            let wrapper = named.is_some_and(|n| basename(n) == "acpmux");
            if found.nearest.is_none() && !wrapper {
                if !passes {
                    found.nearest = Some(program);
                } else if passed_shell.is_none() {
                    passed_shell = Some(program);
                }
            }
        }
        if p.ppid <= 1 || p.ppid == p.pid {
            break;
        }
        at = p.ppid;
    }
    if found.nearest.is_none() {
        found.nearest = passed_shell;
    }
    found
}

/// [`programs`] for a real pid.
pub fn programs_of(pid: u32) -> Programs {
    programs(read, resolve, pid)
}

/// A script argument as an absolute, canonical path of a regular file: relative to the process's
/// working directory when it is known, else only when absolute.
fn resolve(arg: &str, cwd: Option<&str>) -> Option<String> {
    let path = Path::new(arg);
    let path = if path.is_absolute() { path.to_path_buf() } else { Path::new(cwd?).join(path) };
    let canonical = std::fs::canonicalize(path).ok()?;
    let canonical = canonical.to_string_lossy().into_owned();
    (fits_path(&canonical) && std::fs::metadata(&canonical).ok()?.is_file()).then_some(canonical)
}

#[cfg(target_os = "linux")]
fn read(pid: u32) -> Option<ProcInfo> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let base = crate::sender_harness::stat_proc(pid, &stat)?;
    let exe = std::fs::read_link(format!("/proc/{pid}/exe"))
        .ok()
        .map(|p| p.to_string_lossy().trim_end_matches(" (deleted)").to_owned())
        .unwrap_or(base.exe);
    let argv = std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|raw| split_args(&raw, MAX_ARGS))
        .unwrap_or_default();
    let cwd = std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()
        .map(|p| p.to_string_lossy().into_owned());
    Some(ProcInfo { pid, ppid: base.ppid, exe, argv, cwd })
}

#[cfg(target_os = "macos")]
fn read(pid: u32) -> Option<ProcInfo> {
    let base = crate::sender_harness::lookup(pid)?;
    let argv = procargs(pid).unwrap_or_default();
    Some(ProcInfo { pid, ppid: base.ppid, exe: base.exe, argv, cwd: None })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn read(_pid: u32) -> Option<ProcInfo> {
    None
}

/// NUL-separated arguments, at most `max`, empty ones dropped.
#[cfg_attr(not(any(target_os = "linux", target_os = "macos")), allow(dead_code))]
fn split_args(raw: &[u8], max: usize) -> Vec<String> {
    raw.split(|b| *b == 0)
        .filter(|a| !a.is_empty())
        .take(max)
        .map(|a| String::from_utf8_lossy(a).into_owned())
        .collect()
}

/// A process's arguments from `KERN_PROCARGS2`: `argc`, the exec path, NUL padding, then argv.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn parse_procargs(buf: &[u8]) -> Option<Vec<String>> {
    let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?);
    let argc = usize::try_from(argc).ok()?.min(MAX_ARGS);
    let rest = buf.get(4..)?;
    let exec_end = rest.iter().position(|b| *b == 0)?;
    Some(split_args(rest.get(exec_end..)?, argc))
}

#[cfg(target_os = "macos")]
fn procargs(pid: u32) -> Option<Vec<String>> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut argmax: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    // SAFETY: `argmax` is one writable `c_int` and `size` says so.
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            std::ptr::addr_of_mut!(argmax).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    let argmax = usize::try_from(argmax).ok().filter(|n| rc == 0 && *n > 0)?;
    let mut buf = vec![0u8; argmax];
    let mut size = buf.len();
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    // SAFETY: `buf` is `size` writable bytes; the kernel writes at most that and sets `size`.
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return None;
    }
    parse_procargs(buf.get(..size)?)
}

/// The host's first-party senders: each name and the program paths that are it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Registry {
    senders: BTreeMap<String, Vec<String>>,
}

fn name_fits(name: &str) -> bool {
    let trimmed = name.trim();
    !trimmed.is_empty()
        && trimmed == name
        && name.chars().count() <= MAX_NAME_CHARS
        && !name.chars().any(char::is_control)
}

impl Registry {
    /// `{"senders": {NAME: {"programs": [ABSOLUTE_PATH, ...]}}}`; a name or path that does not
    /// fit is skipped, and each path is kept as written and canonical. `None` for no object.
    pub fn parse(text: &str, canonical: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let value: Value = serde_json::from_str(text).ok()?;
        let senders = value.get("senders")?.as_object()?;
        let mut out = BTreeMap::new();
        for (name, entry) in senders {
            if !name_fits(name) {
                continue;
            }
            let mut programs = Vec::new();
            for path in entry.get("programs").and_then(Value::as_array).into_iter().flatten() {
                let Some(path) = path.as_str().filter(|p| fits_path(p)) else { continue };
                for path in [Some(path.to_owned()), canonical(path)].into_iter().flatten() {
                    if !programs.contains(&path) {
                        programs.push(path);
                    }
                }
            }
            if !programs.is_empty() {
                out.insert(name.clone(), programs);
            }
        }
        Some(Self { senders: out })
    }

    /// The names one of whose programs is among `paths`, in name order, at most a few.
    pub fn names_for(&self, paths: &[String]) -> Vec<String> {
        self.senders
            .iter()
            .filter(|(_, programs)| programs.iter().any(|p| paths.contains(p)))
            .map(|(name, _)| name.clone())
            .take(MAX_REGISTERED)
            .collect()
    }
}

/// The registry at `path`, when its owner alone may write it: a regular file (no link) owned by
/// this process's user with no group or other permission bits. Anything else, or no file, is an
/// empty registry. Read again only when the file changes (its inode, size or time).
pub fn load(path: &Path) -> Registry {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        type Key = (std::path::PathBuf, u64, u64, i64, i64, u32, u32);
        static CACHE: std::sync::Mutex<Option<(Key, Registry)>> = std::sync::Mutex::new(None);
        let Ok(meta) = std::fs::symlink_metadata(path) else { return Registry::default() };
        let key = (
            path.to_path_buf(),
            meta.ino(),
            meta.len(),
            meta.mtime(),
            meta.mtime_nsec(),
            meta.mode(),
            meta.uid(),
        );
        let mut cache = CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((cached, registry)) = cache.as_ref()
            && *cached == key
        {
            return registry.clone();
        }
        // SAFETY: `geteuid` reads this process's effective uid and cannot fail.
        let uid = unsafe { libc::geteuid() };
        if !meta.file_type().is_file() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
            tracing::warn!(path = %path.display(), "senders registry ignored: not an owner-only file");
            *cache = Some((key, Registry::default()));
            return Registry::default();
        }
        let canonical =
            |p: &str| std::fs::canonicalize(p).ok().map(|c| c.to_string_lossy().into_owned());
        let registry = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| Registry::parse(&text, canonical))
            .unwrap_or_default();
        *cache = Some((key, registry.clone()));
        registry
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Registry::default()
    }
}

/// The checked fields a walk adds (`sender_harness::checked`): `program`, `programPath`,
/// `interpreter`, and `registered`, the registry names its chain runs.
pub fn checked_fields(found: &Programs, registered: &[String]) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(program) = &found.nearest {
        out.insert("program".into(), json!(program.name));
        if let Some(path) = &program.path {
            out.insert("programPath".into(), json!(path));
        }
        if let Some(interpreter) = &program.interpreter {
            out.insert("interpreter".into(), json!(interpreter));
        }
    }
    if !registered.is_empty() {
        out.insert("registered".into(), json!(registered));
    }
    out
}

/// A carried `checked`'s program fields, as [`checked_fields`] writes them, each bounded.
pub fn kept_fields(found: &Value, kept: &mut Map<String, Value>) {
    for (field, max) in
        [("program", MAX_NAME_CHARS * 4), ("programPath", MAX_PATH_BYTES), ("interpreter", 64)]
    {
        if let Some(value) = found.get(field).and_then(Value::as_str) {
            let value: String = value.chars().filter(|c| !c.is_control()).collect();
            if !value.is_empty() && value.len() <= max {
                kept.insert(field.into(), json!(value));
            }
        }
    }
    let names: Vec<&str> = found
        .get("registered")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|n| name_fits(n))
        .take(MAX_REGISTERED)
        .collect();
    if !names.is_empty() {
        kept.insert("registered".into(), json!(names));
    }
}

/// The registry names a prompt's checked chain runs (`_meta.acpmux.senderHarnessChecked`, the
/// daemon's own or a proven peer daemon's word: `sender_harness::stamp_checked` drops any other).
fn registered(checked: &Value) -> Vec<&str> {
    checked
        .get("registered")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|n| name_fits(n))
        .collect()
}

/// The checked chain a prompt carries, if any (see [`registered`]).
pub fn checked_of(params: &Value) -> Option<&Value> {
    params
        .pointer("/_meta/acpmux")?
        .get(crate::sender_harness::CHECKED_KEY)
        .filter(|c| c.is_object())
}

/// The registry's name for a send that names no sender, when its chain runs exactly one
/// registered sender's program: the relay that runs `acpmux send` with no `--from`.
pub fn registered_name(params: &Value) -> Option<String> {
    match registered(checked_of(params)?).as_slice() {
        [one] => Some((*one).to_owned()),
        _ => None,
    }
}

/// Whether the daemon found a script (an interpreter running a script file) behind the send: a
/// program, never the person typing at a terminal (`server/requests.rs` `owner_terminal`).
pub fn scripted(params: &Value) -> bool {
    checked_of(params).is_some_and(|c| c.get("interpreter").and_then(Value::as_str).is_some())
}

/// `provenance` labelled by what the daemon checked of its sender: a named sender (a notice's,
/// `--from`'s) whose chain runs one of that name's registered programs is `verified` by its
/// program; any other unverified one carries what was `identified` (`{program, app?}`). A
/// provenance the daemon verified otherwise (a caller-proven session) is left as it is. Only
/// labels: who may do what never reads them.
pub fn label(mut provenance: Value, checked: Option<&Value>) -> Value {
    let Some(checked) = checked else { return provenance };
    let field = |k: &str| provenance.get(k).and_then(Value::as_str);
    if provenance.get(crate::prompt_provenance::VERIFIED).and_then(Value::as_bool) == Some(true) {
        return provenance;
    }
    let named = field("from") == Some(crate::prompt_provenance::NAMED_SENDER);
    let name = match field("kind") {
        Some(crate::prompt_provenance::NOTICE_KIND) => field("fromName"),
        Some("agent_message") if named => field("fromName"),
        Some(crate::prompt_provenance::UNVERIFIED_KIND) => None,
        _ => return provenance,
    }
    .map(str::to_owned);
    let program = checked.get("program").and_then(Value::as_str).map(str::to_owned);
    let Some(fields) = provenance.as_object_mut() else { return provenance };
    if let (Some(name), Some(program)) = (&name, &program)
        && registered(checked).contains(&name.as_str())
    {
        fields.insert(crate::prompt_provenance::VERIFIED.into(), json!(true));
        fields.insert("verifiedBy".into(), json!(VERIFIED_BY_PROGRAM));
        fields.insert("program".into(), json!(program));
        fields.remove(IDENTIFIED);
        return provenance;
    }
    let mut identified = Map::new();
    if let Some(program) = program {
        identified.insert("program".into(), json!(program));
    }
    if let Some(app) = checked.get("app").and_then(Value::as_str) {
        identified.insert("app".into(), json!(app));
    }
    if !identified.is_empty() {
        fields.insert(IDENTIFIED.into(), Value::Object(identified));
    }
    provenance
}

#[cfg(test)]
#[path = "sender_program_tests.rs"]
mod tests;

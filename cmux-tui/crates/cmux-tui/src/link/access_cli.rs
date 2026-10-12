//! `cmux link access`: folders of this Mac shared with a chat on a Cloud
//! machine (Move to Cloud, cmuxterm-hq#1874 slice 6). The app runs it; the
//! machine never does. Nothing on the machine can read this Mac: every byte
//! goes from here, pushed through the machine daemon's `fs-v1` ops (the same
//! push as `cmux link sync push`), after the person shared the folder.
//!
//! - `grant --socket PATH --machine ID --session ID --remote-root DIR
//!   [--mode read|write] FOLDER`: shares FOLDER with chat `session` on the
//!   machine, copying it to `DIR/local/<name>-<hash>` there. The grant is
//!   kept only after that first copy succeeded. A folder another chat of the
//!   machine shares with the other mode is refused (`grant_mode_conflict`).
//! - `sync --socket PATH --machine ID [--session ID]`: each shared folder of
//!   the machine (of that chat) again. `read`: this Mac's changes go and the
//!   copy is made this Mac's again; nothing comes back. `write`: the
//!   machine's changes come back first (`cmux link sync pull`'s three-way
//!   merge against the last push; a conflict changes nothing on either side
//!   and is reported), then this Mac's go.
//! - `revoke --machine ID --session ID [--socket PATH] (--all | FOLDER)`:
//!   ends the chat's grants (all, or of FOLDER). A read-only copy no other
//!   chat shares is deleted from the machine when `--socket` is given; a
//!   read-write copy stays (it may hold work not brought back yet). What
//!   the machine already read stays read: a revoke stops what comes next.
//! - `grants [--machine ID] [--session ID]`: the grants kept here.
//!
//! What may be shared and the record: [`grants`]. Secret files never go from
//! a shared folder, at any depth ([`is_secret`]); a read-only grant never
//! writes on this Mac.
//!
//! Output: one JSON line on stdout; `{"ok":true,...}` and exit 0, or
//! `{"ok":false,"error":...,"error_code":...}` and exit 1 (a folder that
//! may not be shared is `grant_refused`); bad usage exits 64. `sync`
//! answers `{"ok":true,"synced":[{"folder","remote","mode","ok",...}]}`,
//! one entry per copy, each with its own `ok` and, when false, its
//! `error_code` (`sync_conflict` with `conflicts`). Unix only, like the link.

mod grants;
mod requests;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use self::grants::{Grant, Mode, Store};
use super::sync_cli::{self, Back};

const USAGE: &str = "usage: cmux link access grant --socket PATH --machine ID --session ID --remote-root DIR [--mode read|write] FOLDER
       cmux link access sync --socket PATH --machine ID [--session ID]
       cmux link access revoke --machine ID --session ID [--socket PATH] (--all | FOLDER)
       cmux link access grants [--machine ID] [--session ID]
       cmux link access request [--socket PATH] [--session ID] [--reason TEXT] [--timeout SECONDS] PATH
       cmux link access triage --socket PATH --machine ID --session ID [--session ID]...
       cmux link access answer --socket PATH --machine ID --session ID --request ID [--remote-root DIR] (--allow PATH | --always PATH | --deny [--reason TEXT])";

/// File names that never go from a shared folder: env files, credential
/// files, private keys and keychains.
const SECRET_NAMES: &[&str] = &[
    ".netrc",
    ".git-credentials",
    ".npmrc",
    ".pypirc",
    ".pgpass",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
];
/// Folders whose files never go from a shared folder.
const SECRET_FOLDERS: &[&str] = &[".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure"];

/// Whether the file at `relative` (in a shared folder) is a secret file. A
/// repository's own files (`.git/...`) are judged by the sync's own rules.
fn is_secret(relative: &str) -> bool {
    if relative.starts_with(".git/") {
        return false;
    }
    let mut names = relative.split('/').peekable();
    while let Some(name) = names.next() {
        let lower = name.to_ascii_lowercase();
        if names.peek().is_some() {
            if SECRET_FOLDERS.contains(&lower.as_str()) {
                return true;
            }
            continue;
        }
        return lower.starts_with(".env")
            || SECRET_NAMES.contains(&lower.as_str())
            || lower.ends_with(".keychain")
            || lower.ends_with(".keychain-db");
    }
    false
}

/// Parsed flags and positional arguments.
#[derive(Default)]
struct Args {
    socket: Option<PathBuf>,
    machine: Option<String>,
    session: Option<String>,
    remote_root: Option<String>,
    mode: Option<String>,
    all: bool,
    positional: Vec<String>,
    /// Every `--session`, in order (`triage` takes several).
    sessions: Vec<String>,
    reason: Option<String>,
    timeout: Option<u64>,
    request: Option<String>,
    allow: bool,
    always: bool,
    deny: bool,
}

fn parse(args: &[String]) -> Option<Args> {
    let mut parsed = Args::default();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => parsed.socket = Some(PathBuf::from(rest.next()?)),
            "--machine" => parsed.machine = Some(rest.next()?.clone()),
            "--session" => {
                let session = rest.next()?.clone();
                parsed.sessions.push(session.clone());
                parsed.session = Some(session);
            }
            "--reason" => parsed.reason = Some(rest.next()?.clone()),
            "--timeout" => parsed.timeout = Some(rest.next()?.parse().ok()?),
            "--request" => parsed.request = Some(rest.next()?.clone()),
            "--allow" => parsed.allow = true,
            "--always" => parsed.always = true,
            "--deny" => parsed.deny = true,
            "--remote-root" => parsed.remote_root = Some(rest.next()?.clone()),
            "--mode" => parsed.mode = Some(rest.next()?.clone()),
            "--all" => parsed.all = true,
            flag if flag.starts_with('-') => return None,
            value => parsed.positional.push(value.to_string()),
        }
    }
    let ids = [&parsed.machine, &parsed.session];
    if ids.iter().any(|id| id.as_deref().is_some_and(|id| !grants::plain_id(id)))
        || parsed.sessions.iter().any(|session| !grants::plain_id(session))
    {
        return None;
    }
    Some(parsed)
}

/// A failure's answer: its code and its words.
struct Failure {
    code: String,
    error: String,
}

impl Failure {
    fn new(code: &str, error: impl std::fmt::Display) -> Self {
        Self { code: code.to_string(), error: error.to_string() }
    }
}

impl From<anyhow::Error> for Failure {
    fn from(error: anyhow::Error) -> Self {
        Self::new("access_failed", format!("{error:#}"))
    }
}

pub(super) fn run(args: &[String]) -> i32 {
    let Some((action, rest)) = args.split_first() else {
        eprintln!("{USAGE}");
        return 64;
    };
    if matches!(action.as_str(), "-h" | "--help" | "help") {
        println!("{USAGE}");
        return 0;
    }
    let Some(args) = parse(rest) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let answer = match (action.as_str(), &args) {
        (
            "grant",
            Args {
                socket: Some(socket),
                machine: Some(machine),
                session: Some(session),
                remote_root: Some(root),
                positional,
                all: false,
                ..
            },
        ) if positional.len() == 1 => {
            let Some(mode) = Mode::parse(args.mode.as_deref().unwrap_or("read")) else {
                eprintln!("{USAGE}");
                return 64;
            };
            let Some(root) = grants::remote_root(root) else {
                eprintln!("{USAGE}");
                return 64;
            };
            grant(socket, machine, session, &root, mode, Path::new(&positional[0]))
        }
        ("sync", Args { socket: Some(socket), machine: Some(machine), positional, .. })
            if positional.is_empty() =>
        {
            sync(socket, machine, args.session.as_deref())
        }
        (
            "revoke",
            Args { machine: Some(machine), session: Some(session), positional, all, .. },
        ) if *all != (positional.len() == 1) && positional.len() <= 1 => {
            revoke(args.socket.as_deref(), machine, session, positional.first().map(Path::new))
        }
        ("grants", Args { positional, .. }) if positional.is_empty() => {
            list(args.machine.as_deref(), args.session.as_deref())
        }
        ("request", Args { positional, .. }) if positional.len() == 1 => requests::request(
            args.socket.as_deref(),
            args.session.as_deref(),
            args.reason.as_deref(),
            std::time::Duration::from_secs(args.timeout.unwrap_or(300)),
            &positional[0],
        ),
        (
            "triage",
            Args { socket: Some(socket), machine: Some(machine), positional, sessions, .. },
        ) if positional.is_empty() && !sessions.is_empty() => {
            requests::triage(socket, machine, sessions)
        }
        (
            "answer",
            Args {
                socket: Some(socket),
                machine: Some(machine),
                session: Some(session),
                request: Some(request),
                positional,
                allow,
                always,
                deny,
                ..
            },
        ) if [*allow, *always, *deny].iter().filter(|set| **set).count() == 1
            && positional.len() == usize::from(!*deny) =>
        {
            let how = if *allow {
                requests::How::Allow
            } else if *always {
                requests::How::Always
            } else {
                requests::How::Deny
            };
            let root = match args.remote_root.as_deref().map(grants::remote_root) {
                Some(None) => {
                    eprintln!("{USAGE}");
                    return 64;
                }
                root => root.flatten(),
            };
            requests::answer(
                socket,
                machine,
                session,
                request,
                root.as_deref(),
                how,
                positional.first().map(String::as_str),
                args.reason.as_deref(),
            )
        }
        _ => {
            eprintln!("{USAGE}");
            return 64;
        }
    };
    match answer {
        Ok(mut line) => {
            line["ok"] = json!(true);
            println!("{line}");
            0
        }
        Err(failure) => {
            println!(
                "{}",
                json!({"ok": false, "error": failure.error, "error_code": failure.code})
            );
            1
        }
    }
}

fn grant(
    socket: &Path,
    machine: &str,
    session: &str,
    root: &str,
    mode: Mode,
    folder: &Path,
) -> Result<Value, Failure> {
    let folder = grants::shareable(folder).map_err(|why| Failure::new("grant_refused", why))?;
    let folder_text = folder.to_str().ok_or_else(|| {
        Failure::new("grant_refused", format!("{} is not a UTF-8 path", folder.display()))
    })?;
    let mut store = Store::open()?;
    if store.grants.iter().any(|other| {
        other.machine == machine
            && other.folder == folder_text
            && other.session != session
            && other.mode != mode
    }) {
        return Err(Failure::new(
            "grant_mode_conflict",
            format!("another chat on this machine shares {folder_text} with the other mode"),
        ));
    }
    let remote = grants::remote_of(root, &folder);
    let mut synced = sync_copy(socket, &folder, &remote, mode);
    if synced["ok"] != json!(true) {
        let code = synced["error_code"].as_str().unwrap_or("sync_failed").to_string();
        let error = synced["error"].as_str().unwrap_or_default().to_string();
        return Err(Failure { code, error });
    }
    let grant = Grant {
        machine: machine.to_string(),
        session: session.to_string(),
        folder: folder_text.to_string(),
        remote,
        mode,
    };
    // One grant per chat and folder: a second one replaces the first.
    store.grants.retain(|kept| {
        !(kept.machine == grant.machine
            && kept.session == grant.session
            && kept.folder == grant.folder)
    });
    // A mode change of the folder's only chat applies to its copy.
    store.grants.push(grant.clone());
    store.save()?;
    synced["grant"] = grant_json(&grant);
    Ok(synced)
}

fn sync(socket: &Path, machine: &str, session: Option<&str>) -> Result<Value, Failure> {
    let store = Store::open()?;
    let mut synced = Vec::new();
    for ((folder, remote), mode) in store.copies(machine, session) {
        let mut entry = match grants::shareable(Path::new(&folder)) {
            Ok(canonical) if canonical.as_os_str() == folder.as_str() => {
                sync_copy(socket, &canonical, &remote, mode)
            }
            // Moved, replaced by a symlink, or no longer shareable: it stays
            // here and nothing goes until the person shares it again.
            _ => json!({"ok": false, "error_code": "grant_folder_changed",
                                     "error": format!("{folder} is no longer the shared folder")}),
        };
        entry["folder"] = json!(folder);
        entry["remote"] = json!(remote);
        entry["mode"] = json!(mode);
        synced.push(entry);
    }
    Ok(json!({ "synced": synced }))
}

/// One copy, synced: for `write` the machine's changes come back first, then
/// this Mac's go. Its answer has `ok` and the counts, or the failure.
fn sync_copy(socket: &Path, folder: &Path, remote: &str, mode: Mode) -> Value {
    let mut pulled = Value::Null;
    if mode == Mode::Write {
        match sync_cli::pull_back(socket, folder, remote) {
            Back::Done(summary) => pulled = summary,
            Back::Conflict(conflicts, reasons) => {
                let mut error = format!(
                    "{} changed both here and on the machine; nothing was synced",
                    conflicts.join(", ")
                );
                if !reasons.is_empty() {
                    error = format!("{error} ({})", reasons.join("; "));
                }
                return json!({"ok": false, "error_code": "sync_conflict", "error": error,
                              "conflicts": conflicts});
            }
            // Never pushed from here, or the machine's copy is not the one
            // this Mac left (deleted, or changed by hand): there is nothing
            // to bring back, and the push below starts the copy over.
            Back::Failed { code, .. } if code == "sync_no_base" || code == "sync_base_mismatch" => {
            }
            Back::Failed { code, error } => {
                return json!({"ok": false, "error_code": code, "error": error});
            }
        }
    }
    match sync_cli::push_kept(socket, folder, remote, &|relative| !is_secret(relative)) {
        Ok(summary) => {
            let mut answer = summary.json();
            answer["ok"] = json!(true);
            if !pulled.is_null() {
                answer["pulled"] = pulled;
            }
            answer
        }
        Err(error) => json!({"ok": false, "error_code": sync_cli::push_failure_code(&error),
                             "error": format!("{error:#}")}),
    }
}

fn revoke(
    socket: Option<&Path>,
    machine: &str,
    session: &str,
    folder: Option<&Path>,
) -> Result<Value, Failure> {
    // A folder that is gone is named as it was shared.
    let folder = folder.map(|folder| {
        std::fs::canonicalize(folder)
            .unwrap_or_else(|_| folder.to_path_buf())
            .to_string_lossy()
            .into_owned()
    });
    let mut store = Store::open()?;
    let (revoked, kept): (Vec<Grant>, Vec<Grant>) = store.grants.drain(..).partition(|grant| {
        grant.machine == machine
            && grant.session == session
            && folder.as_ref().is_none_or(|folder| &grant.folder == folder)
    });
    store.grants = kept;
    store.save()?;
    let mut removed = Vec::new();
    let mut left = Vec::new();
    for grant in &revoked {
        let shared = store
            .grants
            .iter()
            .any(|other| other.machine == machine && other.remote == grant.remote);
        let deleted = match socket {
            Some(socket) if grant.mode == Mode::Read && !shared => {
                sync_cli::delete_remote(socket, &grant.remote).is_ok()
            }
            _ => false,
        };
        if deleted {
            removed.push(grant.remote.clone());
        } else {
            left.push(grant.remote.clone());
        }
    }
    Ok(json!({"revoked": revoked.len(), "removed": removed, "left_on_machine": left}))
}

fn list(machine: Option<&str>, session: Option<&str>) -> Result<Value, Failure> {
    let store = Store::open()?;
    let grants: Vec<Value> = store
        .grants
        .iter()
        .filter(|grant| machine.is_none_or(|machine| grant.machine == machine))
        .filter(|grant| session.is_none_or(|session| grant.session == session))
        .map(grant_json)
        .collect();
    Ok(json!({ "grants": grants }))
}

fn grant_json(grant: &Grant) -> Value {
    json!({"machine": grant.machine, "session": grant.session, "folder": grant.folder,
           "remote": grant.remote, "mode": grant.mode})
}

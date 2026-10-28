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
//! - `upload --socket PATH --remote-root DIR FILE...`: files the person
//!   dropped or pasted into the chat, copied once each ([`uploads`]).
//!
//! What may be shared and the record: [`grants`]. What goes of a shared
//! folder: its files (a git working copy's tracked and untracked files that
//! are not ignored), never a repository (`.git` of the copy or of a nested
//! one) and never a secret file at any depth ([`shared_file`]). A
//! read-write grant is refused for a git working copy. A read-only grant
//! never writes on this Mac.
//!
//! Output: one JSON line on stdout; `{"ok":true,...}` and exit 0, or
//! `{"ok":false,"error":...,"error_code":...}` and exit 1 (a folder that
//! may not be shared is `grant_refused`); bad usage exits 64. `sync`
//! answers `{"ok":true,"synced":[{"folder","remote","mode","ok",...}]}`,
//! one entry per copy, each with its own `ok` and, when false, its
//! `error_code` (`sync_conflict` with `conflicts`). Unix only, like the link.

mod grants;
mod requests;
mod uploads;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use self::grants::{Grant, Mode, Store};
use super::sync_cli::{self, Back};

const USAGE: &str = "usage: cmux link access grant --socket PATH --machine ID --session ID --remote-root DIR [--mode read|write] FOLDER
       cmux link access sync --socket PATH --machine ID [--session ID]
       cmux link access revoke --machine ID --session ID [--socket PATH] (--all | FOLDER)
       cmux link access grants [--machine ID] [--session ID]
       cmux link access request [--socket PATH] [--session ID] [--reason TEXT] [--timeout SECONDS] (PATH | --secret NAME)
       cmux link access upload --socket PATH --remote-root DIR FILE...
       cmux link access triage --socket PATH --machine ID --session ID [--session ID]...
       cmux link access answer --socket PATH --machine ID --session ID --request ID [--remote-root DIR] (--allow PATH --target PATH | --always PATH --target PATH --folder DIR | --share-secret NAME | --deny [--reason TEXT])
         (--share-secret reads the value from stdin, byte for byte: no newline is removed)";

/// File names that never go from a shared folder (ASCII case folded):
/// env, credential and key files. Best effort: a secret under any other
/// name goes with the folder the person shared.
const SECRET_NAMES: &[&str] = &[
    ".netrc",
    ".git-credentials",
    ".npmrc",
    ".pypirc",
    ".pgpass",
    ".htpasswd",
    ".vault-token",
    ".boto",
    ".s3cfg",
    ".terraformrc",
    ".dockercfg",
    ".yarnrc.yml",
    "credentials",
    "credentials.json",
    "credentials.toml",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ecdsa_sk",
    "id_ed25519",
    "id_ed25519_sk",
];
/// File name endings that never go from a shared folder.
const SECRET_SUFFIXES: &[&str] = &[
    ".keychain",
    ".keychain-db",
    ".pem",
    ".key",
    ".p12",
    ".pfx",
    ".ppk",
    ".jks",
    ".keystore",
    ".tfstate",
    ".tfvars",
];
/// Folders whose files never go from a shared folder.
const SECRET_FOLDERS: &[&str] =
    &[".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure", "gcloud", ".gem", ".cargo"];

/// Whether the file at `relative` (in a shared folder) is a secret file.
fn is_secret(relative: &str) -> bool {
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
            || SECRET_SUFFIXES.iter().any(|suffix| lower.ends_with(suffix));
    }
    false
}

/// Whether the file at `relative` of the shared `folder` goes (`git`: the
/// folder is a git working copy). Never: a secret file, anything of a
/// repository (no `.git` part under any spelling, so neither a working
/// copy's own repository nor a nested one goes: its config, hooks and
/// history stay here), a sync's own leftovers, and in git a path git lists
/// below a folder that is now a symlink (it would read outside the folder).
fn shared_file(folder: &Path, relative: &str, git: bool) -> bool {
    let names: Vec<&str> = relative.split('/').collect();
    if is_secret(relative)
        || names.iter().any(|name| sync_cli::is_dotgit(name) || name.starts_with(".cmux-sync"))
        || names.last().is_some_and(|name| name.ends_with(".cmux-sync-part"))
    {
        return false;
    }
    if !git {
        // The walk enters no symlink, so every path is below real folders.
        return true;
    }
    let mut at = folder.to_path_buf();
    names[..names.len().saturating_sub(1)].iter().all(|name| {
        at.push(name);
        cmux_blocking::fs::symlink_metadata(&at).is_ok_and(|meta| meta.file_type().is_dir())
    })
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
    /// `answer --target PATH`: where the card said the path leads.
    target: Option<String>,
    /// `answer --always --folder DIR`: the folder the card said Always shares.
    folder: Option<String>,
    allow: bool,
    always: bool,
    deny: bool,
    /// `request --secret NAME`: the secret asked for.
    secret: Option<String>,
    /// `answer --share-secret NAME`: the value comes on stdin.
    share_secret: bool,
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
            "--target" => parsed.target = Some(rest.next()?.clone()),
            "--folder" => parsed.folder = Some(rest.next()?.clone()),
            "--allow" => parsed.allow = true,
            "--always" => parsed.always = true,
            "--deny" => parsed.deny = true,
            "--secret" => parsed.secret = Some(rest.next()?.clone()),
            "--share-secret" => parsed.share_secret = true,
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
    // A secret flag means nothing to any other action: refuse it.
    if (args.secret.is_some() && action != "request") || (args.share_secret && action != "answer") {
        eprintln!("{USAGE}");
        return 64;
    }
    // A machine too old for this action says so before anything changes.
    if let Some(line) = outdated_line(action, args.socket.as_deref()) {
        println!("{line}");
        return 1;
    }
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
        ("request", Args { positional, secret, .. })
            if positional.len() + usize::from(secret.is_some()) == 1 =>
        {
            let what = match secret {
                Some(name) => requests::Asked::Secret(name),
                None => requests::Asked::File(&positional[0]),
            };
            requests::request(
                args.socket.as_deref(),
                args.session.as_deref(),
                args.reason.as_deref(),
                std::time::Duration::from_secs(args.timeout.unwrap_or(300)),
                what,
            )
        }
        ("upload", Args { socket: Some(socket), remote_root: Some(root), positional, .. })
            if !positional.is_empty() =>
        {
            let Some(root) = grants::remote_root(root) else {
                eprintln!("{USAGE}");
                return 64;
            };
            uploads::upload(socket, &root, positional)
        }
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
                share_secret,
                ..
            },
        ) if [*allow, *always, *deny, *share_secret].iter().filter(|set| **set).count() == 1
            && positional.len() == usize::from(!*deny) =>
        {
            let how = if *allow {
                requests::How::Allow
            } else if *always {
                requests::How::Always
            } else if *share_secret {
                requests::How::ShareSecret
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
                requests::Shown {
                    path: positional.first().map(String::as_str),
                    target: args.target.as_deref(),
                    folder: args.folder.as_deref(),
                },
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

/// The `machine_outdated` line when the machine's cmux-tui is too old for
/// what `action` needs there ([`super::machine_gate`]). `request` runs on the
/// machine itself and is never gated, and neither is `revoke`: a revoke
/// always ends the grants on this Mac, whatever the machine runs.
fn outdated_line(action: &str, socket: Option<&Path>) -> Option<Value> {
    let needed = match action {
        "triage" | "answer" => {
            cmux_tui_core::server::agent_transfer::access_requests::ACCESS_REQUEST_CAPABILITY
        }
        "grant" | "sync" | "upload" => cmux_tui_core::fs_ops::FS_CAPABILITY,
        _ => return None,
    };
    super::machine_gate::outdated(socket?, &[needed]).map(|outdated| outdated.line())
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
    // A read-write copy of a git working copy would let the machine's
    // staged paths choose which files here the next push reads.
    if mode == Mode::Write && sync_cli::in_git(&folder) {
        return Err(Failure::new(
            "grant_refused",
            format!(
                "{folder_text} is in a git working copy: share it read-only, or move the chat with it"
            ),
        ));
    }
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
    let same = |kept: &Grant| {
        kept.machine == machine && kept.session == session && kept.folder == folder_text
    };
    let before = store.grants.iter().find(|kept| same(kept)).cloned();
    // A read-write copy turning read-only brings the machine's work back
    // first, so the read-only push does not overwrite it.
    if let Some(before) = &before
        && before.mode == Mode::Write
        && before.remote == remote
        && mode == Mode::Read
    {
        let back = sync_copy(socket, &folder, &remote, Mode::Write, false);
        if back["ok"] != json!(true) {
            return Err(failure_of(&back));
        }
    }
    // Only a copy no grant of this machine holds yet is started over; one a
    // grant holds may have machine work that has not come back.
    let first = !store.grants.iter().any(|kept| kept.machine == machine && kept.remote == remote);
    let mut synced = sync_copy(socket, &folder, &remote, mode, first);
    if synced["ok"] != json!(true) {
        return Err(failure_of(&synced));
    }
    let grant = Grant {
        machine: machine.to_string(),
        session: session.to_string(),
        folder: folder_text.to_string(),
        remote,
        mode,
    };
    // One grant per chat and folder: a second one replaces the first.
    store.grants.retain(|kept| !same(kept));
    store.grants.push(grant.clone());
    store.save()?;
    // A copy the replaced grant left under another root goes like a revoked one.
    if let Some(before) = before
        && before.remote != grant.remote
    {
        let (removed, _) = forget_copies(&store, Some(socket), &[before]);
        synced["removed"] = json!(removed);
    }
    synced["grant"] = grant_json(&grant);
    Ok(synced)
}

fn failure_of(answer: &Value) -> Failure {
    Failure::new(
        answer["error_code"].as_str().unwrap_or("sync_failed"),
        answer["error"].as_str().unwrap_or_default(),
    )
}

/// `sync`: each copy under the grants lock, checked against the record
/// again, so a revoke waits for one copy at most and nothing it revoked goes
/// after it returned.
fn sync(socket: &Path, machine: &str, session: Option<&str>) -> Result<Value, Failure> {
    let copies = Store::open()?.copies(machine, session);
    let mut synced = Vec::new();
    for ((folder, remote), mode) in copies {
        let store = Store::open()?;
        if store.copies(machine, session).get(&(folder.clone(), remote.clone())) != Some(&mode) {
            continue;
        }
        let mut entry = match grants::shareable(Path::new(&folder)) {
            // A read-write folder that became a git working copy stops (its
            // pull would take the machine's staged paths into the index).
            Ok(canonical)
                if canonical.as_os_str() == folder.as_str()
                    && !(mode == Mode::Write && sync_cli::in_git(&canonical)) =>
            {
                sync_copy(socket, &canonical, &remote, mode, false)
            }
            // Moved, replaced by a symlink, or no longer shareable: it stays
            // here and nothing goes until the person shares it again.
            _ => json!({"ok": false, "error_code": "grant_folder_changed",
                        "error": format!("{folder} is no longer the shared folder")}),
        };
        drop(store);
        entry["folder"] = json!(folder);
        entry["remote"] = json!(remote);
        entry["mode"] = json!(mode);
        synced.push(entry);
    }
    Ok(json!({ "synced": synced }))
}

/// One copy, synced: for `write` the machine's changes come back first, then
/// this Mac's go. `first`: the person is sharing it now, so a copy this Mac
/// has no record of (never pushed, or not as this Mac left it) is started
/// over; on a later sync that stops it instead, since the machine's work
/// may not have come back. Its answer has `ok` and the counts, or the
/// failure.
fn sync_copy(socket: &Path, folder: &Path, remote: &str, mode: Mode, first: bool) -> Value {
    let mut pulled = Value::Null;
    if mode == Mode::Write {
        let keep_new = |relative: &str| shared_file(folder, relative, false);
        match sync_cli::pull_back(socket, folder, remote, &keep_new) {
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
            Back::Failed { code, .. }
                if first && (code == "sync_no_base" || code == "sync_base_mismatch") => {}
            Back::Failed { code, error } => {
                return json!({"ok": false, "error_code": code, "error": error});
            }
        }
    }
    let keep = |relative: &str, git: bool| shared_file(folder, relative, git);
    match sync_cli::push_kept(socket, folder, remote, &keep) {
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
        cmux_blocking::fs::canonicalize(folder)
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
    if let Some(folder) = &folder
        && revoked.is_empty()
    {
        return Err(Failure::new(
            "grant_not_found",
            format!("{folder} is not shared with this chat"),
        ));
    }
    store.save()?;
    let (removed, left) = forget_copies(&store, socket, &revoked);
    Ok(json!({"revoked": revoked.len(), "removed": removed, "left_on_machine": left}))
}

/// Deletes from the machine the read-only copies of `ended` grants that no
/// grant left in `store` shares (with `socket`); answers the copies deleted
/// and the ones left there.
fn forget_copies(
    store: &Store,
    socket: Option<&Path>,
    ended: &[Grant],
) -> (Vec<String>, Vec<String>) {
    let mut removed = Vec::new();
    let mut left = Vec::new();
    for grant in ended {
        let shared = store
            .grants
            .iter()
            .any(|other| other.machine == grant.machine && other.remote == grant.remote);
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
    (removed, left)
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

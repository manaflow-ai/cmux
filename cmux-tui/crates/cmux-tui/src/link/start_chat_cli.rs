//! `cmux link start-chat plan|pin|copy`: the bookkeeping of a new chat's
//! first send that runs in Cloud (`cloud.startChat`, the App's
//! `CloudStartChat`), moved out of Swift so it builds and tests on Linux
//! (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE INSTEAD OF SWIFT"). The App
//! lists its Cloud machines, makes the one a plan asks for, opens the chat
//! and closes its own tab; what decides is here:
//!
//! - `plan --request JSON`: the machine the send takes ([`pick::destination`]):
//!   the one its first try took while that machine exists; for a send from a
//!   Mac workspace, the machine that workspace already has; else a new one
//!   named for chats; and the send's keys ([`Keys`]). For now each workspace
//!   gets a small machine of its own and no machine serves two workspaces
//!   (leo-workspace `design/cloud.md`, "One workspace per small machine,
//!   snapshots, and a Cloud button"). A machine that exists is pinned to the
//!   send before anything runs there, so a retry of the send names it.
//! - `pin --key K --account A --machine ID [--workspace W]`: pins the send
//!   to the machine the App just made for it, and makes it the workspace's
//!   when the workspace has none yet and no other workspace has it.
//! - `copy --key K --account A --machine ID --socket PATH --local ROOT
//!   [--subpath SUB] --work-root R...`: copies ROOT to a folder of the send's
//!   own on the machine (`cmux link sync push`), trying each work root in
//!   turn, unless this send's copy already finished there: a second push
//!   would overwrite what the chat changed since. Answers the chat's folder
//!   there.
//! - `ensure --workspace W --key K --repo OWNER/NAME [--ref REF] [--environment env_...]
//!   [--platform URL]`, the cmux credential on stdin: the workspace's own
//!   machine from the cmux platform (`POST /v1/workspaces/{W}/machine`), made
//!   under the plan's `create_key` so a retry gets the same one. With the
//!   folder's repository (the plan's `repo`) it boots from the repository's
//!   set-up snapshot once that is ready (zero-setup hot start), keyed by the
//!   chosen cloud environment (`cloud.startChat`'s `environment`; absent: the
//!   personal Default).
//! - `import --entries JSON`: takes in the sends the App kept in its user
//!   defaults before this did ([`Ledger::import`]), once, on upgrade.
//!
//! Every send is kept under the account it began in (`account`: the user and
//! the team, as the App spells them): a team switch keeps the person signed
//! in, and a send of the previous team must never take, or copy to, this
//! team's machine. The pins live in this Mac's state folder ([`ledger`]). Output: one JSON
//! line on stdout, `{"ok":true,...}` with exit 0, or
//! `{"ok":false,"error":...,"error_code":...}` with exit 1; bad usage exits 64.

mod ledger;
mod pick;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use ledger::{Ledger, Send};
use pick::{Candidate, Destination};

const USAGE: &str = "usage: cmux link start-chat plan --request JSON\n       \
cmux link start-chat pin --key KEY --account ACCOUNT --machine ID [--workspace ID]\n       \
cmux link start-chat ensure --workspace ID --key KEY --repo OWNER/NAME [--ref REF] [--environment env_ID] [--platform URL] (the cmux credential on stdin)\n       \
cmux link start-chat import --entries JSON\n       \
cmux link start-chat copy --key KEY --account ACCOUNT --machine ID --socket PATH --local FOLDER [--subpath PATH] --work-root PATH...";

/// The error code a work root the machine's user cannot write answers with:
/// the next root is tried.
const PERMISSION_DENIED: &str = "fs.permission_denied";

pub(super) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let Some((action, flags)) = args.split_first() else {
        eprintln!("{USAGE}");
        return 64;
    };
    let Some(flags) = Flags::parse(flags) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let Some(ledger) = ledger::path() else {
        println!(
            "{}",
            refused("ledger_failed", "this Mac has no state folder to keep the send's machine in")
        );
        return 1;
    };
    let answer = match action.as_str() {
        "plan" => flags.one("--request").map(|request| plan(&ledger, request)),
        "pin" => match (flags.key(), flags.account(), flags.one("--machine"), flags.workspace()) {
            (Some(key), Some(account), Some(machine), Some(workspace)) => {
                Some(pin(&ledger, &key, account, machine, workspace))
            }
            _ => None,
        },
        "copy" => StartCopy::of(&flags).map(|copy| copy.run(&ledger, &push)),
        "import" => flags.one("--entries").map(|entries| import(&ledger, entries)),
        "ensure" => Ensure::of(&flags).map(|ensure| ensure.run(&mut std::io::stdin().lock())),
        _ => None,
    };
    let Some(answer) = answer else {
        eprintln!("{USAGE}");
        return 64;
    };
    println!("{answer}");
    if answer["ok"] == json!(true) { 0 } else { 1 }
}

/// The keys of the send `key` (lowercased: a retry may spell it in another case).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Keys {
    /// The idempotency key of the Cloud machine the send creates: a retry
    /// whose create reached the server but lost its answer gets that machine
    /// back, never a second paid VM.
    pub(super) create: String,
    /// The creation key of the machine's chat tab: a retry gets the tab its
    /// first try made, never a second chat with the prompt again.
    pub(super) tab: String,
    /// The folder under the machine's work root the send's copies go in: its
    /// own, so a second chat from the same folder never writes over the first
    /// one's changes on a reused machine. Each copy goes to a new folder in it
    /// ([`StartCopy::run`]).
    pub(super) place: String,
}

impl Keys {
    pub(super) fn of(key: &str) -> Self {
        let key = key.to_lowercase();
        Self {
            create: format!("cloud-start-chat-{key}"),
            tab: format!("cloud-start-chat-{key}"),
            place: format!("chats/{key}"),
        }
    }

    fn json(&self) -> Value {
        json!({"create_key": self.create, "tab_key": self.tab, "remote_place": self.place})
    }
}

/// A send's key: the page's UUID, as `AgentPaneCloudStart` checked it.
pub(super) fn valid_key(key: &str) -> bool {
    key.len() == 36
        && key.char_indices().all(|(index, char)| match index {
            8 | 13 | 18 | 23 => char == '-',
            _ => char.is_ascii_hexdigit(),
        })
}

fn refused(code: &str, error: impl std::fmt::Display) -> Value {
    json!({"ok": false, "error": error.to_string(), "error_code": code})
}

/// The account a send began in, as the App spells it: printable, at most 512 bytes.
pub(super) fn valid_account(account: &str) -> bool {
    account.len() <= 512 && !account.chars().any(char::is_control)
}

/// A Mac workspace's id, as the App spells it: 1 to 128 printable characters.
pub(super) fn valid_workspace(workspace: &str) -> bool {
    (1..=128).contains(&workspace.chars().count()) && !workspace.chars().any(char::is_control)
}

/// What `plan` reads: the send, the account it began in, the Mac workspace it
/// came from, who is signed in, and the Cloud machines the App's list for
/// that account named.
#[derive(serde::Deserialize)]
struct PlanRequest {
    key: String,
    account: String,
    /// The Mac workspace of the tab that sent; None for a send from no workspace.
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default)]
    user: Option<String>,
    /// Whether the App has loaded its machine list: before it has, a machine
    /// a pin names is kept (it may be one made for this send, not listed yet).
    #[serde(default)]
    loaded: bool,
    /// The machines the account's list named: the only ones a send may take.
    #[serde(default)]
    machines: Vec<Candidate>,
    /// Machines in the App's store that its list did not name yet (made
    /// since): a send pinned to one keeps it, but none is picked.
    #[serde(default)]
    stored: Vec<String>,
    /// The chat's folder on this Mac: its GitHub `origin` is the plan's `repo`.
    #[serde(default)]
    local: Option<String>,
    /// The cloud environment the send chose (`cloud.startChat`'s `environment`), echoed for `ensure`.
    #[serde(default)]
    environment: Option<String>,
}

/// `plan`: where the send goes, pinned when it is a machine that exists.
pub(super) fn plan(ledger: &Path, request: &str) -> Value {
    let request: PlanRequest = match serde_json::from_str(request) {
        Ok(request) => request,
        Err(error) => return refused("bad_request", error),
    };
    if !valid_key(&request.key) {
        return refused("bad_request", "the send's key is not a UUID");
    }
    if !valid_account(&request.account) {
        return refused("bad_request", "the account is too long or has control characters");
    }
    let workspace = request.workspace.as_deref();
    if workspace.is_some_and(|workspace| !valid_workspace(workspace)) {
        return refused(
            "bad_request",
            "the workspace id is empty, too long or has control characters",
        );
    }
    if request.environment.as_deref().is_some_and(|id| !valid_environment(id)) {
        return refused("bad_request", "the environment is not a cloud environment id (env_...)");
    }
    let keys = Keys::of(&request.key);
    let send = Send::new(&request.key, &request.account);
    let planned = Ledger::update(ledger, |pins| {
        let destination = pick::destination(
            &send,
            &request.account,
            workspace,
            pins,
            &request.machines,
            &request.stored,
            request.user.as_deref(),
            request.loaded,
        );
        if let Destination::Machine(id) = &destination {
            pins.record(id, &send);
            // A retry of an older send keeps its machine, never the workspace's newer one,
            // and a machine another workspace has never becomes this one's too.
            if let Some(workspace) = workspace {
                pick::claim(pins, workspace, &request.account, id);
            }
        }
        destination
    });
    let mut line = keys.json();
    let fields = match planned {
        Ok(Destination::Machine(id)) => json!({"ok": true, "machine": id}),
        Ok(Destination::New) => json!({
            "ok": true,
            "machine": null,
            "new_name": pick::new_machine_name(request.machines.iter().map(|machine| machine.title.as_str())),
        }),
        Err(error) => return refused("ledger_failed", format!("{error:#}")),
    };
    if let (Value::Object(line), Value::Object(fields)) = (&mut line, fields) {
        line.extend(fields);
        line.insert("repo".into(), json!(request.local.as_deref().and_then(folder_repo)));
        line.insert("environment".into(), json!(request.environment));
    }
    line
}

/// A cloud environment's id, as the cmux platform makes them: `env_` and 24 hex digits.
pub(super) fn valid_environment(id: &str) -> bool {
    id.len() == 28
        && id.starts_with("env_")
        && id[4..].bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// A repository as the cmux platform names one: `owner/name`, GitHub's characters, at most 140 bytes.
pub(super) fn valid_repo(repo: &str) -> bool {
    let part = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    };
    repo.len() <= 140
        && matches!(repo.split_once('/'), Some((owner, name)) if part(owner) && part(name))
}

/// The GitHub repository of the folder `local`: its `origin` remote, when that is GitHub's.
fn folder_repo(local: &str) -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["-C", local, "remote", "get-url", "origin"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    github_repo(String::from_utf8_lossy(&output.stdout).trim())
}

/// `owner/name` of a GitHub remote URL (https, ssh or scp-like), None for any other host.
pub(super) fn github_repo(url: &str) -> Option<String> {
    let path =
        ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"]
            .iter()
            .find_map(|prefix| url.strip_prefix(prefix))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    valid_repo(path).then(|| path.to_string())
}

/// `ensure`: the Mac workspace's own machine from the cmux platform.
pub(super) struct Ensure {
    workspace: String,
    create_key: String,
    repo: String,
    git_ref: Option<String>,
    environment: Option<String>,
    platform: Option<String>,
}

impl Ensure {
    fn of(flags: &Flags) -> Option<Self> {
        let optional = |name: &str| match flags.all(name).as_slice() {
            [] => Some(None),
            [value] => Some(Some(value.to_string())),
            _ => None,
        };
        let environment = optional("--environment")?;
        let git_ref = optional("--ref")?;
        if environment.as_deref().is_some_and(|id| !valid_environment(id))
            || git_ref
                .as_deref()
                .is_some_and(|r| r.is_empty() || r.len() > 200 || r.chars().any(char::is_control))
        {
            return None;
        }
        Some(Self {
            workspace: flags.workspace()??.to_string(),
            create_key: Keys::of(&flags.key()?).create,
            repo: flags.one("--repo").filter(|repo| valid_repo(repo))?.to_string(),
            git_ref,
            environment,
            platform: optional("--platform")?,
        })
    }

    /// The request body: the plan's `create_key` as the client key, so a retry gets the same machine.
    pub(super) fn body(&self) -> Value {
        let mut body = json!({"clientKey": self.create_key, "repo": self.repo});
        if let Some(git_ref) = &self.git_ref {
            body["ref"] = json!(git_ref);
        }
        if let Some(environment) = &self.environment {
            body["environment"] = json!(environment);
        }
        body
    }

    fn run(&self, stdin: &mut dyn std::io::BufRead) -> Value {
        let mut credential = String::new();
        if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
            return refused("unauthorized", "no cmux credential on stdin");
        }
        let env = |name: &str| std::env::var(name).ok();
        let origin = match crate::cli::platform_origin(self.platform.as_deref(), &env) {
            Ok(origin) => origin,
            Err(error) => return refused("bad_request", error),
        };
        // A new machine's placement may take a while; the platform answers once it is admitted.
        let platform = match crate::cli::Platform::new(
            origin,
            credential.trim().to_string(),
            std::time::Duration::from_secs(120),
        ) {
            Ok(platform) => platform,
            Err(failure) => return refused(failure.code, failure.message),
        };
        let path = format!("/v1/workspaces/{}/machine", percent_segment(&self.workspace));
        ensure_answer(platform.post(&path, self.body()))
    }
}

/// One URL path segment: unreserved bytes kept, every other byte percent-encoded.
pub(super) fn percent_segment(segment: &str) -> String {
    segment
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// `ensure`'s line from the platform's answer: the machine's id and what it booted from.
pub(super) fn ensure_answer(answer: Result<Value, crate::cli::PlatformCallError>) -> Value {
    use crate::cli::PlatformCallError as E;
    match answer {
        Ok(body) => match body.pointer("/machine/id").and_then(Value::as_str) {
            Some(id) => json!({
                "ok": true,
                "machine": id,
                "team": body.get("team"),
                "created": body.get("created").and_then(Value::as_bool).unwrap_or(false),
                "snapshot": body.get("snapshot"),
                "environment": body.get("environment"),
            }),
            None => refused("bad_answer", "the cmux platform answered without the machine"),
        },
        Err(E::Status { status: 404, code: "" }) => {
            refused("unavailable", "this cmux platform has no workspace machines (it answered 404)")
        }
        Err(E::Status { status, code }) => refused(
            if code.is_empty() { "refused" } else { code },
            format!(
                "the cmux platform refused the workspace's machine: {}",
                format!("{status} {code}").trim_end()
            ),
        ),
        Err(E::Unreachable(reason)) => {
            refused("unreachable", format!("the cmux platform did not answer: {reason}"))
        }
        Err(E::Unreadable(status)) => refused(
            "bad_answer",
            format!("the cmux platform answered {status} with no readable body"),
        ),
    }
}

/// `pin`: the send `key` of `account` runs on `machine` (one the App just made
/// for it), which is the Mac workspace `workspace`'s own from now on when the
/// workspace has none yet and no other workspace has it ([`pick::claim`]).
pub(super) fn pin(
    ledger: &Path,
    key: &str,
    account: &str,
    machine: &str,
    workspace: Option<&str>,
) -> Value {
    match Ledger::update(ledger, |pins| {
        pins.record(machine, &Send::new(key, account));
        if let Some(workspace) = workspace {
            pick::claim(pins, workspace, account, machine);
        }
    }) {
        Ok(()) => json!({"ok": true}),
        Err(error) => refused("ledger_failed", format!("{error:#}")),
    }
}

/// `import`: the sends the App kept before cmux-tui did, a JSON list of its
/// entries ([`ledger::AppEntry`]).
pub(super) fn import(ledger: &Path, entries: &str) -> Value {
    let entries: Vec<ledger::AppEntry> = match serde_json::from_str(entries) {
        Ok(entries) => entries,
        Err(error) => return refused("bad_request", error),
    };
    match Ledger::update(ledger, |pins| pins.import(&entries)) {
        Ok(count) => json!({"ok": true, "imported": count}),
        Err(error) => refused("ledger_failed", format!("{error:#}")),
    }
}

/// One push of a folder to a machine: `(socket, local, remote)` to the push's
/// error code and message.
pub(super) type Push<'a> = dyn Fn(&Path, &Path, &str) -> Result<(), (String, String)> + 'a;

/// `cmux link sync push`, after the machine says it serves `fs-v1`.
fn push(socket: &Path, local: &Path, remote: &str) -> Result<(), (String, String)> {
    if let Some(outdated) =
        super::machine_gate::outdated(socket, &[cmux_tui_core::fs_ops::FS_CAPABILITY])
    {
        return Err((super::machine_gate::OUTDATED.to_string(), outdated.message()));
    }
    super::sync_cli::push(socket, local, remote)
        .map(|_| ())
        .map_err(|error| (super::sync_cli::push_failure_code(&error), format!("{error:#}")))
}

/// `copy`'s arguments.
#[derive(Clone, Debug)]
pub(super) struct StartCopy {
    pub(super) key: String,
    pub(super) account: String,
    pub(super) machine: String,
    pub(super) socket: PathBuf,
    /// The folder that is copied (a Git working copy's top, else the chat's
    /// folder), absolute, as the App spells it (its name on the machine is
    /// hashed from this spelling, as Move to Cloud's is).
    pub(super) local: String,
    /// The chat's folder inside `local`; empty for `local` itself.
    pub(super) subpath: String,
    /// The machine's folders for copies, in the order they are tried.
    pub(super) work_roots: Vec<String>,
}

impl StartCopy {
    fn of(flags: &Flags) -> Option<Self> {
        let local = flags.one("--local")?;
        let subpath = flags.one("--subpath").unwrap_or("").trim_matches('/').to_string();
        let work_roots: Vec<String> =
            flags.all("--work-root").into_iter().map(str::to_string).collect();
        if !local.starts_with('/')
            || local == "/"
            || subpath.split('/').any(|part| part == "..")
            || work_roots.is_empty()
            || work_roots.iter().any(|root| !root.starts_with('/'))
        {
            return None;
        }
        Some(Self {
            key: flags.key()?,
            account: flags.account()?.to_string(),
            machine: flags.one("--machine")?.to_string(),
            socket: PathBuf::from(flags.one("--socket")?),
            local: local.to_string(),
            subpath,
            work_roots,
        })
    }

    /// A new folder for one copy of the send, under its [`Keys::place`].
    pub(super) fn fresh_place(&self) -> String {
        // The first 8 hex digits of a random id (all ASCII, so 8 chars are 8 bytes).
        let id: String = uuid::Uuid::new_v4().simple().to_string().chars().take(8).collect();
        format!("{}/{}", Keys::of(&self.key).place, id)
    }

    /// The copied folder and the chat's folder in it, in `place` under `work_root`.
    pub(super) fn remote(&self, work_root: &str, place: &str) -> (String, String) {
        let folder = join(&join(work_root, place), &remote_name(&self.local));
        let chat =
            if self.subpath.is_empty() { folder.clone() } else { join(&folder, &self.subpath) };
        (folder, chat)
    }

    /// The copy, or the chat's folder of the one that already finished.
    /// Each copy goes to a new folder, kept before the push starts: the
    /// ledger is not locked during the push, which can take minutes, so a
    /// copy whose answer was lost (it may have finished on the machine) or
    /// a second copy of the same send at once never writes over another.
    pub(super) fn run(&self, ledger: &Path, push: &Push<'_>) -> Value {
        let send = Send::new(&self.key, &self.account);
        let place = self.fresh_place();
        match Ledger::update(ledger, |pins| {
            let finished = pins.copied_chat(&send, &self.machine);
            if finished.is_none() {
                pins.start_copy(&send, &self.machine, &place);
            }
            finished
        }) {
            Ok(Some(chat)) => return json!({"ok": true, "chat": chat, "copied": false}),
            Ok(None) => {}
            Err(error) => return refused("ledger_failed", format!("{error:#}")),
        }
        let mut last = ("sync_failed".to_string(), "no work root to copy to".to_string());
        for root in &self.work_roots {
            let (folder, chat) = self.remote(root, &place);
            match push(&self.socket, Path::new(&self.local), &folder) {
                Ok(()) => {
                    return match Ledger::update(ledger, |pins| {
                        pins.record_copy(&chat, &send, &self.machine, &place);
                    }) {
                        Ok(()) => {
                            json!({"ok": true, "chat": chat, "folder": folder, "copied": true})
                        }
                        Err(error) => refused("ledger_failed", format!("{error:#}")),
                    };
                }
                Err(failure) => {
                    let next = failure.0 == PERMISSION_DENIED;
                    last = failure;
                    // Not this machine's home (an image without the work user): the next root.
                    if !next {
                        break;
                    }
                }
            }
        }
        refused(&last.0, last.1)
    }
}

/// `base` and `name` joined by one slash.
fn join(base: &str, name: &str) -> String {
    if base.ends_with('/') { format!("{base}{name}") } else { format!("{base}/{name}") }
}

/// A copied folder's name on a machine: its own name and a short hash
/// (32-bit FNV-1a, low 24 bits) of where it is on this Mac, so two folders
/// with one name never share a copy. The same name Move to Cloud gives
/// (`CloudMoveFolder.remoteName`).
pub(super) fn remote_name(root: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    let name = root.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let name = if name.is_empty() { "folder" } else { name };
    format!("{name}-{:06x}", hash & 0x00ff_ffff)
}

/// `--flag value` pairs; a flag may repeat (`--work-root`).
struct Flags(Vec<(String, String)>);

impl Flags {
    fn parse(args: &[String]) -> Option<Self> {
        let mut pairs = Vec::new();
        let mut args = args.iter();
        while let Some(flag) = args.next() {
            if !flag.starts_with("--") {
                return None;
            }
            pairs.push((flag.clone(), args.next()?.clone()));
        }
        Some(Self(pairs))
    }

    fn all(&self, name: &str) -> Vec<&str> {
        self.0.iter().filter(|(flag, _)| flag == name).map(|(_, value)| value.as_str()).collect()
    }

    fn one(&self, name: &str) -> Option<&str> {
        match self.all(name).as_slice() {
            [value] => Some(*value),
            _ => None,
        }
    }

    fn key(&self) -> Option<String> {
        self.one("--key").filter(|key| valid_key(key)).map(str::to_string)
    }

    fn account(&self) -> Option<&str> {
        self.one("--account").filter(|account| valid_account(account))
    }

    /// `--workspace`: Some(None) when it is not given, None when it is not a valid id.
    fn workspace(&self) -> Option<Option<&str>> {
        match self.all("--workspace").as_slice() {
            [] => Some(None),
            [workspace] if valid_workspace(workspace) => Some(Some(*workspace)),
            _ => None,
        }
    }
}

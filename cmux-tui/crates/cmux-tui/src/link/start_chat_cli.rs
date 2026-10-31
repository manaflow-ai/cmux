//! `cmux link start-chat plan|pin|copy`: the bookkeeping of a new chat's
//! first send that runs in Cloud (`cloud.startChat`, the App's
//! `CloudStartChat`), moved out of Swift so it builds and tests on Linux
//! (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE INSTEAD OF SWIFT"). The App
//! lists its Cloud machines, makes the one a plan asks for, opens the chat
//! and closes its own tab; what decides is here:
//!
//! - `plan --request JSON`: the machine the send takes ([`pick::destination`]):
//!   the one its first try took while that machine exists, else this
//!   person's free one, else a new one named for chats; and the send's keys
//!   ([`Keys`]). A machine that exists is pinned to the send before anything
//!   runs there, so a retry of the send names it.
//! - `pin --key K --machine ID`: pins the send to the machine the App just
//!   made for it.
//! - `copy --key K --machine ID --socket PATH --local ROOT [--subpath SUB]
//!   --work-root R...`: copies ROOT to the send's own place on the machine
//!   (`cmux link sync push`), trying each work root in turn, unless this
//!   send's copy already finished there: a second push would overwrite what
//!   the chat changed since. Answers the chat's folder there.
//!
//! The pins live in this Mac's state folder ([`ledger`]). Output: one JSON
//! line on stdout, `{"ok":true,...}` with exit 0, or
//! `{"ok":false,"error":...,"error_code":...}` with exit 1; bad usage exits 64.

mod ledger;
mod pick;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use ledger::Ledger;
use pick::{Candidate, Destination};

const USAGE: &str = "usage: cmux link start-chat plan --request JSON\n       \
cmux link start-chat pin --key KEY --machine ID\n       \
cmux link start-chat copy --key KEY --machine ID --socket PATH --local FOLDER [--subpath PATH] --work-root PATH...";

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
        "pin" => match (flags.key(), flags.one("--machine")) {
            (Some(key), Some(machine)) => Some(pin(&ledger, &key, machine)),
            _ => None,
        },
        "copy" => StartCopy::of(&flags).map(|copy| copy.run(&ledger, &push)),
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
    /// The folder under the machine's work root the send's copy goes to: its
    /// own, so a second chat from the same folder never writes over the first
    /// one's changes on a reused machine.
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

/// What `plan` reads: the send, who is signed in, and this app's Cloud machines.
#[derive(serde::Deserialize)]
struct PlanRequest {
    key: String,
    #[serde(default)]
    user: Option<String>,
    /// Whether the App has loaded its machine list: before it has, a machine
    /// a pin names is kept (it may be one made for this send, not listed yet).
    #[serde(default)]
    loaded: bool,
    #[serde(default)]
    machines: Vec<Candidate>,
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
    let keys = Keys::of(&request.key);
    let planned = Ledger::update(ledger, |pins| {
        let destination = pick::destination(
            &request.key,
            pins,
            &request.machines,
            request.user.as_deref(),
            request.loaded,
        );
        if let Destination::Machine(id) = &destination {
            pins.record(id, &request.key);
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
    }
    line
}

/// `pin`: the send `key` runs on `machine` (one the App just made for it).
pub(super) fn pin(ledger: &Path, key: &str, machine: &str) -> Value {
    match Ledger::update(ledger, |pins| pins.record(machine, key)) {
        Ok(()) => json!({"ok": true}),
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
            machine: flags.one("--machine")?.to_string(),
            socket: PathBuf::from(flags.one("--socket")?),
            local: local.to_string(),
            subpath,
            work_roots,
        })
    }

    /// The copied folder and the chat's folder in it, under `work_root`.
    pub(super) fn remote(&self, work_root: &str) -> (String, String) {
        let place = join(work_root, &Keys::of(&self.key).place);
        let folder = join(&place, &remote_name(&self.local));
        let chat =
            if self.subpath.is_empty() { folder.clone() } else { join(&folder, &self.subpath) };
        (folder, chat)
    }

    /// The copy, or the chat's folder of the one that already finished.
    pub(super) fn run(&self, ledger: &Path, push: &Push<'_>) -> Value {
        // The ledger is not locked during the push, which can take minutes: a
        // second copy of the same send at once is held off by the App's
        // one-start-per-page hold, and would record the same folder.
        match Ledger::update(ledger, |pins| pins.copied_chat(&self.key, &self.machine)) {
            Ok(Some(chat)) => return json!({"ok": true, "chat": chat, "copied": false}),
            Ok(None) => {}
            Err(error) => return refused("ledger_failed", format!("{error:#}")),
        }
        let mut last = ("sync_failed".to_string(), "no work root to copy to".to_string());
        for root in &self.work_roots {
            let (folder, chat) = self.remote(root);
            match push(&self.socket, Path::new(&self.local), &folder) {
                Ok(()) => {
                    return match Ledger::update(ledger, |pins| {
                        pins.record_copy(&chat, &self.key, &self.machine);
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
}

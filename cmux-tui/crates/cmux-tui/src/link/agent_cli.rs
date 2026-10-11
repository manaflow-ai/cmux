//! `cmux link agent move --from-socket LOCAL --surface ID --to-socket MACHINE
//! --cwd FOLDER [--interrupt]`: moves the agent chat of tab `ID` of the
//! daemon at `LOCAL` to the machine daemon at `MACHINE` (Move to Cloud,
//! cmuxterm-hq#1874 slice 1c), over `agent-transfer-v1` (spec/commands.md,
//! "Agent chat transfer"). `FOLDER` is where the chat runs there. Neither
//! daemon reaches the other: this pump copies the bundle between them.
//!
//! `MACHINE` is the `local_socket` that `cmux-tui remote connect --headless
//! --json` names in its first `connection-snapshot` event (the app's Cloud
//! link runs it). cmux-remote's mux-control service carries that socket to
//! the VM daemon's own Unix socket, where the pump is a trusted local client
//! (`agent-transfer-*` ride its bulk lane). It is NOT the machine link's
//! socket that `cmux link sync push` uses: the link's remote entry admits
//! only the `fs-v1` ops.
//!
//! 1. begin on the source (the chat freezes there);
//! 2. receive on the target with the begin manifest;
//! 3. every bundle file, page by page, read from the source and written to
//!    the target;
//! 4. finish on the target (the chat runs there);
//! 5. commit on the source (the chat closes here).
//!
//! The source gives the chat back (abort) only when the target provably
//! lacks it. Before the finish is sent it cannot have it: the receive is
//! dropped there and the source aborts. Once the finish is sent, a failed
//! or lost finish is settled by asking the target (`agent-transfer-
//! receive-abort` of the receive, which also forgets the move there so a
//! late finish can never land it): landed commits, not landed aborts, no
//! answer leaves the chat frozen and reports `move_unresolved`.
//!
//! A Mac source names no target acpmux could ask on its own, so the move is
//! recorded under the state folder until it ends ([`record`]); running the
//! same command again resolves a recorded move first (asks the target, then
//! commits or aborts), and after an abort moves the chat anew.
//!
//! The record is written before the begin too. When a begin's answer was
//! lost, the rerun's begin is refused as `transfer.moving` with that move's
//! id (`error_details.transfer_id`): the pump aborts it and moves again. No
//! target can have that chat: the begin answer is the only place its id and
//! manifest are served, and nobody read it. A chat frozen in a move this
//! command has no record of is left alone (`move_unresolved`).
//!
//! Output: one JSON line on stdout, `{"ok":true,"session_id":...,
//! "transfer_id":...,"bytes":N,"resolved":bool}` (exit 0), or
//! `{"ok":false,"error":...,"error_code":...,"transfer_id"?:...}` (exit 1);
//! bad usage exits 64.

mod daemon;
mod record;

use std::path::PathBuf;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

use daemon::{BEGIN_TIMEOUT, CALL_TIMEOUT, CallError, Daemon, FINISH_TIMEOUT, call_once};
use record::{Record, Records};

const USAGE: &str = "usage: cmux link agent move --from-socket LOCAL_DAEMON_SOCKET \
--surface SURFACE_ID --to-socket REMOTE_CONNECT_SOCKET --cwd REMOTE_FOLDER [--interrupt] \
[--state-dir DIR]
  --to-socket: the local_socket of `cmux-tui remote connect --headless --json` for the \
machine (its connection-snapshot event), not the machine link socket of `cmux link sync`";
/// Bytes asked for per page (the daemon serves at most 4 MiB).
const PAGE_BYTES: u64 = 1 << 20;

struct Args {
    from: PathBuf,
    surface: u64,
    to: PathBuf,
    cwd: String,
    interrupt: bool,
    state_dir: Option<PathBuf>,
}

/// A move that failed, as its JSON line reports it.
struct Failed {
    code: String,
    error: String,
    transfer_id: Option<String>,
}

impl Failed {
    fn new(code: impl Into<String>, error: impl Into<String>) -> Self {
        Self { code: code.into(), error: error.into(), transfer_id: None }
    }

    /// A call to the `side` daemon that failed: its refusal code, or
    /// `<side>_unreachable` when no answer came.
    fn call(side: &str, error: &CallError) -> Self {
        match error {
            CallError::Refused { code, message, .. } => Self::new(code.clone(), message.clone()),
            CallError::Lost(message) => Self::new(format!("{side}_unreachable"), message.clone()),
        }
    }

    fn bad_answer(error: impl Into<String>) -> Self {
        Self::new("bad_answer", error)
    }

    fn state(error: &anyhow::Error) -> Self {
        Self::new("state_unavailable", format!("{error:#}"))
    }

    fn with_transfer(mut self, transfer_id: &str) -> Self {
        self.transfer_id = Some(transfer_id.to_owned());
        self
    }
}

/// A chat that now lives on the machine.
struct Moved {
    session_id: String,
    transfer_id: String,
    bytes: u64,
    /// An earlier run's move was resolved, not a new one made.
    resolved: bool,
}

pub(super) fn run(args: &[String]) -> i32 {
    let help = args.first().map(String::as_str) == Some("help")
        || args.iter().any(|arg| matches!(arg.as_str(), "-h" | "--help"));
    if help {
        println!("{USAGE}");
        return 0;
    }
    let Some(args) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    match move_chat(&args) {
        Ok(moved) => {
            let line = json!({"ok": true, "session_id": moved.session_id,
                              "transfer_id": moved.transfer_id, "bytes": moved.bytes,
                              "resolved": moved.resolved});
            println!("{line}");
            0
        }
        Err(failed) => {
            let mut line = json!({"ok": false, "error": failed.error, "error_code": failed.code});
            if let Some(transfer_id) = failed.transfer_id {
                line["transfer_id"] = json!(transfer_id);
            }
            println!("{line}");
            1
        }
    }
}

fn parse(args: &[String]) -> Option<Args> {
    let [action, rest @ ..] = args else { return None };
    if action != "move" {
        return None;
    }
    let (mut from, mut surface, mut to, mut cwd, mut state_dir) = (None, None, None, None, None);
    let mut interrupt = false;
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--from-socket" => from = Some(PathBuf::from(rest.next()?)),
            "--surface" => surface = Some(rest.next()?.parse::<u64>().ok()?),
            "--to-socket" => to = Some(PathBuf::from(rest.next()?)),
            "--cwd" => cwd = Some(rest.next()?.clone()),
            "--state-dir" => state_dir = Some(PathBuf::from(rest.next()?)),
            "--interrupt" => interrupt = true,
            _ => return None,
        }
    }
    let cwd = cwd.filter(|cwd| cwd.starts_with('/'))?;
    Some(Args { from: from?, surface: surface?, to: to?, cwd, interrupt, state_dir })
}

fn move_chat(args: &Args) -> Result<Moved, Failed> {
    let records = Records::open(args.state_dir.clone(), &args.from, args.surface).map_err(|e| {
        match e.downcast_ref::<record::Busy>() {
            Some(busy) => Failed::new("move_in_progress", busy.to_string()),
            None => Failed::state(&e),
        }
    })?;
    let begin_unanswered = match records.load().map_err(|e| Failed::state(&e))? {
        Some(record) if record.transfer_id.is_empty() => true,
        Some(record) => {
            if let Some(moved) = resolve(args, &records, record)? {
                return Ok(moved);
            }
            false
        }
        None => false,
    };
    fresh(args, &records, begin_unanswered)
}

/// Ends the move an earlier run left: the chat landed there (the source
/// commits), or it was given back here (`None`: a new move may start).
fn resolve(args: &Args, records: &Records, mut record: Record) -> Result<Option<Moved>, Failed> {
    if record.to_socket != args.to {
        let error = format!(
            "an earlier move of this chat to {} is unresolved; run it again with that --to-socket",
            record.to_socket.display()
        );
        return Err(unresolved(&record, error));
    }
    let landed = if record.finish_sent {
        record.landed.or_else(|| ask_landed(&record))
    } else {
        drop_receive(&record);
        Some(false)
    };
    match landed {
        Some(true) => commit(args, records, &mut record, 0, true).map(Some),
        Some(false) => give_back(args, records, &mut record).map(|()| None),
        None => {
            Err(unresolved(&record, "the machine cannot say yet whether the chat landed there"))
        }
    }
}

/// A new move: begin, receive, copy, finish, then commit or abort.
/// `begin_unanswered`: an earlier run's begin got no answer.
fn fresh(args: &Args, records: &Records, begin_unanswered: bool) -> Result<Moved, Failed> {
    let mut source = Daemon::connect(&args.from).map_err(|e| Failed::call("source", &e))?;
    let mut record =
        Record { to_socket: args.to.clone(), cwd: args.cwd.clone(), ..Record::default() };
    records.save(&record).map_err(|e| Failed::state(&e))?;
    let params = json!({"surface": args.surface, "interrupt": args.interrupt});
    let begun = match source.call("agent-transfer-begin", params, BEGIN_TIMEOUT) {
        Ok(begun) => begun,
        Err(CallError::Refused { code, message, details }) => {
            let moving = details["transfer_id"].as_str().filter(|id| !id.is_empty());
            let Some(moving) = moving else {
                records.clear();
                return Err(Failed::new(code, message));
            };
            if !begin_unanswered {
                records.clear();
                let error = "the chat is frozen in a move this command has no record of";
                return Err(Failed::new("move_unresolved", error).with_transfer(moving));
            }
            // The move an earlier begin froze. Its answer, the only place
            // its id and manifest are served, reached nobody: no target can
            // have the chat.
            record.transfer_id = moving.to_owned();
            give_back(args, records, &mut record)?;
            return fresh(args, records, false);
        }
        Err(lost) => {
            // The record stays: the chat may be frozen in that move.
            let error = format!("the begin was not answered ({}); run this again", lost.message());
            return Err(Failed::new("move_unresolved", error));
        }
    };
    let transfer_id = begun["transfer_id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| Failed::bad_answer("the source's begin named no move"))?;
    record.transfer_id = transfer_id.to_owned();
    let (mut target, bytes) =
        match up_to_finish(args, &mut source, records, &mut record, &begun["manifest"]) {
            Ok(copied) => copied,
            Err(failed) => {
                // No finish was sent: the target cannot have the chat.
                drop_receive(&record);
                return Err(match give_back(args, records, &mut record) {
                    Ok(()) => failed.with_transfer(&record.transfer_id),
                    Err(stuck) => {
                        Failed { error: format!("{}; {}", failed.error, stuck.error), ..stuck }
                    }
                });
            }
        };
    let receive_id = record.receive_id.clone().unwrap_or_default();
    let finished =
        target.call("agent-transfer-finish", json!({"receive_id": receive_id}), FINISH_TIMEOUT);
    let (landed, finish_error) = match finished {
        Ok(answer) => {
            if let Some(id) = answer["session"]["sessionId"].as_str() {
                record.session_id = Some(id.to_owned());
            }
            (Some(true), None)
        }
        Err(error) => (ask_landed(&record), Some(error)),
    };
    let finish_error = finish_error.as_ref();
    let why = finish_error.map_or("", CallError::message);
    match landed {
        Some(true) => commit(args, records, &mut record, bytes, false),
        Some(false) => {
            give_back(args, records, &mut record)?;
            let code = finish_error.and_then(CallError::code).unwrap_or("move_failed");
            let error = format!("the machine did not take the chat: {why}");
            Err(Failed::new(code, error).with_transfer(&record.transfer_id))
        }
        None => {
            let error = format!(
                "the finish was not answered ({why}) and the machine cannot say whether the chat \
                 landed; the chat stays frozen here until this command runs again"
            );
            Err(unresolved(&record, error))
        }
    }
}

/// Steps 2 and 3, each step recorded first: the receive on the target, then
/// every page, then the record that the finish is about to be sent.
/// Returns the target connection and the bytes copied.
fn up_to_finish(
    args: &Args,
    source: &mut Daemon,
    records: &Records,
    record: &mut Record,
    manifest: &Value,
) -> Result<(Daemon, u64), Failed> {
    records.save(record).map_err(|e| Failed::state(&e))?;
    let target_failed = |e: CallError| Failed::call("target", &e);
    let mut target = Daemon::connect(&args.to).map_err(target_failed)?;
    let params = json!({"manifest": manifest, "cwd": args.cwd});
    let received =
        target.call("agent-transfer-receive", params, CALL_TIMEOUT).map_err(target_failed)?;
    let receive_id = received["receive_id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| Failed::bad_answer("the machine's receive named no receive"))?;
    record.receive_id = Some(receive_id.to_owned());
    record.session_id = received["session_id"].as_str().map(str::to_owned);
    records.save(record).map_err(|e| Failed::state(&e))?;
    let files = manifest["files"]
        .as_array()
        .ok_or_else(|| Failed::bad_answer("the begin manifest lists no files"))?;
    let mut bytes = 0;
    for file in files {
        let (Some(path), Some(size)) = (file["path"].as_str(), file["size"].as_u64()) else {
            return Err(Failed::bad_answer("the begin manifest lists a file without path or size"));
        };
        bytes += copy_file(source, &mut target, record, path, size)?;
    }
    record.finish_sent = true;
    records.save(record).map_err(|e| Failed::state(&e))?;
    Ok((target, bytes))
}

/// Copies one bundle file page by page; an empty file needs no page.
fn copy_file(
    source: &mut Daemon,
    target: &mut Daemon,
    record: &Record,
    path: &str,
    size: u64,
) -> Result<u64, Failed> {
    let receive_id = record.receive_id.as_deref().unwrap_or_default();
    let mut offset = 0u64;
    while offset < size {
        let params = json!({"transfer_id": record.transfer_id, "path": path, "offset": offset,
                            "limit": PAGE_BYTES});
        let page = source
            .call("agent-transfer-read", params, CALL_TIMEOUT)
            .map_err(|e| Failed::call("source", &e))?;
        let data = page["data"].as_str().unwrap_or_default();
        let len = BASE64.decode(data).map_or(0, |bytes| bytes.len() as u64);
        if len == 0 || offset + len > size {
            return Err(Failed::bad_answer(format!("the source served a bad page of {path}")));
        }
        let params = json!({"receive_id": receive_id, "path": path, "offset": offset,
                            "data": data});
        let written = target
            .call("agent-transfer-write", params, CALL_TIMEOUT)
            .map_err(|e| Failed::call("target", &e))?;
        if written["next"].as_u64() != Some(offset + len) {
            return Err(Failed::bad_answer(format!("the machine took a page of {path} short")));
        }
        offset += len;
    }
    Ok(size)
}

/// Asks the target whether the chat landed, forgetting the move there so a
/// late finish can never land it: `None` when it cannot say.
fn ask_landed(record: &Record) -> Option<bool> {
    let receive_id = record.receive_id.as_deref()?;
    let params = json!({"receive_id": receive_id});
    let answer =
        call_once(&record.to_socket, "agent-transfer-receive-abort", params, CALL_TIMEOUT).ok()?;
    match (answer["landed"].as_bool(), answer["forgotten"].as_bool()) {
        (Some(true), _) => Some(true),
        // Only a forgotten move stays not landed.
        (Some(false), Some(true)) => Some(false),
        _ => None,
    }
}

/// Drops the receive on the target, if there is one (a best effort: an
/// unfinished receive is swept there after 24 h).
fn drop_receive(record: &Record) {
    if let Some(receive_id) = &record.receive_id {
        let params = json!({"receive_id": receive_id});
        let _ = call_once(&record.to_socket, "agent-transfer-receive-abort", params, CALL_TIMEOUT);
    }
}

/// The source gives the chat back (the target provably lacks it).
fn give_back(args: &Args, records: &Records, record: &mut Record) -> Result<(), Failed> {
    // Kept for a rerun if the source cannot be told now.
    record.landed = Some(false);
    let _ = records.save(record);
    let params = json!({"surface": args.surface, "transfer_id": record.transfer_id});
    match call_once(&args.from, "agent-transfer-abort", params, CALL_TIMEOUT) {
        Ok(_) => {}
        // Ended already (the source's own lease aborts an unread move).
        Err(CallError::Refused { code, message, .. })
            if code == "agent_transfer.refused" && message.contains("transfer.unknown") => {}
        Err(error) => {
            let error = format!("the chat could not be given back here: {}", error.message());
            return Err(unresolved(record, error));
        }
    }
    records.clear();
    Ok(())
}

/// The source closes the chat (it landed on the target).
fn commit(
    args: &Args,
    records: &Records,
    record: &mut Record,
    bytes: u64,
    resolved: bool,
) -> Result<Moved, Failed> {
    record.landed = Some(true);
    let _ = records.save(record);
    let params = json!({"surface": args.surface, "transfer_id": record.transfer_id,
                        "to": {"cwd": record.cwd}});
    if let Err(error) = call_once(&args.from, "agent-transfer-commit", params, CALL_TIMEOUT) {
        let error = format!("the chat landed there but did not close here: {}", error.message());
        return Err(unresolved(record, error));
    }
    records.clear();
    Ok(Moved {
        session_id: record.session_id.clone().unwrap_or_default(),
        transfer_id: record.transfer_id.clone(),
        bytes,
        resolved,
    })
}

fn unresolved(record: &Record, error: impl Into<String>) -> Failed {
    Failed::new("move_unresolved", error).with_transfer(&record.transfer_id)
}

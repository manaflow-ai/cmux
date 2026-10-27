//! `cmux setup machine SSH_TARGET [--name NAME] [--dry-run]`: makes a
//! machine reached over ssh an acpmux peer of this one, so agents here can
//! start sessions there (`cmux acp new --host NAME`).
//!
//! It checks first, from the running acpmux daemon (or, without one, from
//! acpmux's config): a peer of that name (or, without `--name`, at that ssh
//! host) that is connected and runs this build is `ok`, and nothing runs.
//! Before it changes anything it tries key-only ssh to the machine; a host
//! that refuses or does not answer comes back as `needs_user` with the ssh
//! command to try, because only the person can add a key or fix their ssh
//! config. It never asks for a password and never writes a key or
//! `~/.ssh/config`. A connected peer on an older build gets
//! `acp host update`; anything else gets `acp host setup`, which keeps the
//! remote config and token and re-registers the peer by name, so running it
//! again is safe.
//!
//! The work runs as `cmux acp host setup|update --json`, this executable as
//! a child, rather than through acpmux's library: those functions are
//! private to acpmux, print their result to stdout themselves (setup's
//! stdout must stay one JSON object) and end the process when a row fails
//! (`update`). The child keeps acpmux the one implementation of the remote
//! install, and its daemon start (`cmux acp` starts acpmux with this
//! binary's prefix). Only the read-only check talks to the daemon in
//! process, and it never starts one.
//!
//! The machine is registered here only: this build's `acp host setup` has
//! no way back. PR #22823 adds `acp host enroll`, which installs, registers
//! the peer both ways (`--reverse`) and runs a doctor, as JSON-lines steps;
//! once it lands this task moves to `enroll` and `reverse` reports it.

use cmux_process::{Command, Stdio};

use acpmux::peer::{SSH_PEER_PORT, ssh_target};
use serde_json::{Value, json};

use super::{Outcome, Refusal};

const TASK: &str = "machine";

/// Why `reverse` is not done yet (see the module docs).
const REVERSE_UNSUPPORTED: &str = "this build's `acp host setup` registers the machine here only; \
`acp host enroll --reverse` (PR #22823) adds the way back";

/// Why an update has no undo.
const UPDATE_NO_UNDO: &str = "host update replaced acpmux on the machine with this build and \
restarted its daemon; the old binary is not kept, so there is nothing to put back";

/// Why re-running setup for a peer that was already registered at that
/// host has no undo.
const RESETUP_NO_UNDO: &str = "the peer was registered before at this host, and host setup kept \
its name, url and token; it replaced acpmux on the machine with this build, which is not kept";

/// What `undo` leaves in place after a first setup.
const SETUP_UNDO_NOTE: &str = "the undo removes the peer here; acpmux stays installed on the \
machine with its daemon running";

struct Request {
    target: String,
    /// The peer name: `--name`, else the host's first label (as acpmux names it).
    name: String,
    /// `--name` was given, so only a peer of that name matches.
    named: bool,
    dry_run: bool,
}

/// What a change would do.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Plan {
    Update,
    Setup,
}

/// The peers acpmux knows, and whether a daemon answered for them.
struct Peers {
    daemon: bool,
    list: Vec<Value>,
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    crate::acp::configure_home();
    let peers = peers()?;
    let found = find(&peers.list, &request);
    if !request.named
        && found.is_none()
        && let Some(peer) = named(&peers.list, &request.name)
    {
        return Ok(taken(&request, peer, peers.daemon));
    }
    // A peer found at this host under another name keeps that name.
    let name = found
        .and_then(|peer| peer.get("name").and_then(Value::as_str))
        .unwrap_or(&request.name)
        .to_owned();
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "dry_run": request.dry_run,
        "target": request.target,
        "name": name,
        "daemon": if peers.daemon { "running" } else { "not_running" },
        "before": found.map(summary),
        "ssh": Value::Null,
        "plan": [],
        "after": Value::Null,
        "remote_version": Value::Null,
        "reverse": {"supported": false, "why": REVERSE_UNSUPPORTED},
        "error": Value::Null,
        "undo": Value::Null,
        "undo_note": Value::Null,
        "user_action": Value::Null,
    });
    let same_host =
        found.is_some_and(|peer| destination(peer).as_deref() == Some(request.target.as_str()));
    let connected = found.is_some_and(|peer| flag(peer, "connected"));
    let outdated = found.is_some_and(|peer| flag(peer, "outdated"));
    if same_host && connected && !outdated {
        report["state"] = json!("ok");
        report["after"] = report["before"].clone();
        return Ok(Outcome { report, failed: false });
    }
    let plan = if same_host && connected { Plan::Update } else { Plan::Setup };
    let port = found
        .filter(|_| same_host)
        .and_then(|peer| peer.get("url").and_then(Value::as_str))
        .and_then(|url| ssh_target(url).ok())
        .map_or(SSH_PEER_PORT, |target| target.port);
    let argv = acp_argv(plan, &request.target, &name, port);
    report["plan"] = json!([display(&argv)]);
    let (undo, undo_note) = undo(plan, found, same_host, &name);

    let probe = probe(&request.target)?;
    report["ssh"] = json!({
        "command": test_command(&request.target),
        "reachable": probe.is_ok(),
        "error": probe.as_ref().err(),
    });
    if let Err(error) = probe {
        report["state"] = json!("needs_user");
        report["user_action"] = json!({
            "kind": "ssh",
            "text": format!(
                "cmux reaches {target} over ssh with keys only and could not ({error}). Run the \
                 command in a terminal: when it asks for a password or is refused, add your key \
                 to the machine (ssh-copy-id {target}) or fix your ssh config, then run `cmux \
                 setup machine {target}` again.",
                target = request.target,
            ),
            "command": test_command(&request.target),
            "url": Value::Null,
        });
        return Ok(Outcome { report, failed: false });
    }
    report["undo"] = json!(undo);
    report["undo_note"] = json!(undo_note);
    if request.dry_run {
        report["state"] = json!("planned");
        return Ok(Outcome { report, failed: false });
    }

    match run_acp(&argv) {
        Ok(result) => {
            let peer = after(&result, &name);
            report["state"] = json!("changed");
            report["after"] = peer.as_ref().map_or(Value::Null, summary);
            report["remote_version"] = remote_version(&result, &name);
            Ok(Outcome { report, failed: false })
        }
        Err(error) => {
            // Nothing is registered when setup fails (the peer is its last step).
            report["state"] = json!("failed");
            report["error"] = json!(error);
            report["undo"] = Value::Null;
            report["undo_note"] = Value::Null;
            Ok(Outcome { report, failed: true })
        }
    }
}

/// Without `--name`, the default name already names a peer at another
/// place. Moving it would drop that peer (and a `ws://` peer's token, which
/// no undo can put back), so nothing runs and the person picks a name.
fn taken(request: &Request, peer: &Value, daemon: bool) -> Outcome {
    let (target, name) = (&request.target, &request.name);
    let text = format!(
        "The peer name {name} already names {url}. Run `cmux setup machine \
         {target} --name NAME` with a new name to add {target} beside it, or with --name {name} \
         to point {name} at {target} instead.",
        url = peer.get("url").and_then(Value::as_str).unwrap_or("another peer"),
    );
    let report = json!({
        "schema_version": 1,
        "task": TASK,
        "state": "needs_user",
        "dry_run": request.dry_run,
        "target": target,
        "name": name,
        "daemon": if daemon { "running" } else { "not_running" },
        "before": summary(peer),
        "ssh": Value::Null,
        "plan": [],
        "after": summary(peer),
        "remote_version": Value::Null,
        "reverse": {"supported": false, "why": REVERSE_UNSUPPORTED},
        "error": Value::Null,
        "undo": Value::Null,
        "undo_note": Value::Null,
        "user_action": {
            "kind": "name",
            "text": text,
            "command": format!("cmux setup machine {} --name NAME", quote(target)),
            "url": Value::Null,
        },
    });
    Outcome { report, failed: false }
}

/// The machine check `cmux setup status` reports: every peer, read-only.
/// A peer that is not connected or runs another build names the
/// `cmux setup machine` command that fixes it (ssh peers only).
pub(super) fn status() -> Result<Value, Refusal> {
    crate::acp::configure_home();
    let peers = peers()?;
    let rows = peers
        .list
        .iter()
        .map(|peer| {
            let mut row = summary(peer);
            let healthy = flag(peer, "connected") && !flag(peer, "outdated");
            row["fix"] =
                match (healthy, destination(peer), peer.get("name").and_then(Value::as_str)) {
                    (false, Some(target), Some(name)) => json!(setup_command(&target, name)),
                    _ => Value::Null,
                };
            row
        })
        .collect::<Vec<_>>();
    let needs_setup = rows.iter().any(|row| !row["fix"].is_null());
    Ok(json!({
        "task": TASK,
        "state": if needs_setup { "needs_setup" } else { "ok" },
        "daemon": if peers.daemon { "running" } else { "not_running" },
        "peers": rows,
    }))
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut target = None;
    let mut name = None;
    let mut dry_run = false;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--name" => {
                let value =
                    args.next().filter(|value| !value.starts_with('-')).ok_or_else(|| {
                        Refusal::Usage("cmux: setup machine: --name needs a peer name".into())
                    })?;
                name = Some(value.to_owned());
            }
            flag if flag.starts_with('-') => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup machine: unknown option {flag:?}"
                )));
            }
            host if target.is_none() => target = Some(host.to_owned()),
            extra => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup machine: unexpected argument {extra:?}; give one ssh target"
                )));
            }
        }
    }
    let target = target.ok_or_else(|| {
        Refusal::Usage("cmux: setup machine: give the ssh target (host or user@host)".into())
    })?;
    // Checked like a peer url, so the target is never an ssh option.
    match ssh_target(&format!("ssh://{target}")) {
        Ok(parsed) if parsed.destination == target => {}
        Ok(_) => {
            return Err(Refusal::Usage(
                "cmux: setup machine: give the ssh target without a port".into(),
            ));
        }
        Err(why) => {
            return Err(Refusal::Usage(format!(
                "cmux: setup machine: refusing that target: {why}"
            )));
        }
    }
    let named = name.is_some();
    let name = name.unwrap_or_else(|| default_name(&target));
    if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) {
        return Err(Refusal::Usage(format!(
            "cmux: setup machine: the peer name {name:?} must be letters, digits, '.', '_' or '-'"
        )));
    }
    Ok(Request { target, name, named, dry_run })
}

/// The name `acp host setup` gives a peer without `--name`.
fn default_name(target: &str) -> String {
    let host = target.rsplit('@').next().unwrap_or(target);
    host.split('.').next().unwrap_or(host).to_owned()
}

/// The peers from the running daemon, which knows which are connected;
/// without one, the peers in acpmux's config, none connected. Never starts
/// a daemon: this is the read-only check.
fn peers() -> Result<Peers, Refusal> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| Refusal::Failed(format!("cmux: setup machine: {error}")))?;
    let live = runtime.block_on(async {
        let client = acpmux::deliver::connect().await.ok()?;
        Some(client.request("_acpmux/peers", json!({})).await)
    });
    match live {
        Some(Ok(reply)) => Ok(Peers {
            daemon: true,
            list: reply.get("peers").and_then(Value::as_array).cloned().unwrap_or_default(),
        }),
        Some(Err(error)) => {
            Err(Refusal::Failed(format!("cmux: setup machine: acpmux refused: {error:#}")))
        }
        None => configured_peers().map(|list| Peers { daemon: false, list }),
    }
}

/// The `peers` of acpmux's config.json, as unconnected peers. Read as plain
/// JSON: loading the whole config would also discover every harness.
fn configured_peers() -> Result<Vec<Value>, Refusal> {
    let path = acpmux::config::Config::path();
    let text = match cmux_blocking::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(Refusal::Failed(format!(
                "cmux: setup machine: {}: {error}",
                path.display()
            )));
        }
    };
    let config: Value = serde_json::from_str(&text).map_err(|error| {
        Refusal::Failed(format!("cmux: setup machine: {} is not JSON: {error}", path.display()))
    })?;
    let Some(peers) = config.get("peers").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    Ok(peers
        .iter()
        .map(|(name, peer)| {
            json!({
                "name": name,
                "url": peer.get("url"),
                "connected": false,
                "outdated": false,
                "remoteBuild": Value::Null,
                "error": Value::Null,
            })
        })
        .collect())
}

/// The peer `request` names: with `--name`, the peer of that name; without
/// it, the one whose ssh host is the target. A default name never picks a
/// peer at another host (`taken` reports that one).
fn find<'a>(peers: &'a [Value], request: &Request) -> Option<&'a Value> {
    if request.named {
        return named(peers, &request.name);
    }
    peers.iter().find(|peer| destination(peer).as_deref() == Some(request.target.as_str()))
}

fn named<'a>(peers: &'a [Value], name: &str) -> Option<&'a Value> {
    peers.iter().find(|peer| peer.get("name").and_then(Value::as_str) == Some(name))
}

/// The ssh destination of an `ssh://` peer; None for any other peer.
fn destination(peer: &Value) -> Option<String> {
    let url = peer.get("url").and_then(Value::as_str)?;
    ssh_target(url).ok().map(|target| target.destination)
}

fn flag(peer: &Value, key: &str) -> bool {
    peer.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// The part of a peer summary (`_acpmux/peers`) a person needs to see.
fn summary(peer: &Value) -> Value {
    json!({
        "name": peer.get("name"),
        "url": peer.get("url"),
        "connected": flag(peer, "connected"),
        "outdated": flag(peer, "outdated"),
        "remote_build": peer.get("remoteBuild"),
        "error": peer.get("error"),
    })
}

/// The undo of `plan`, or None with the reason, and what an undo leaves.
fn undo(
    plan: Plan,
    found: Option<&Value>,
    same_host: bool,
    name: &str,
) -> (Option<String>, &'static str) {
    let quoted = quote(name);
    match (plan, found) {
        (Plan::Update, _) => (None, UPDATE_NO_UNDO),
        (Plan::Setup, None) => (Some(format!("cmux acp host rm {quoted}")), SETUP_UNDO_NOTE),
        (Plan::Setup, Some(_)) if same_host => (None, RESETUP_NO_UNDO),
        (Plan::Setup, Some(peer)) => {
            // The name pointed at another machine: setup moves it here, and
            // the undo points it back (an ssh peer reads its token over ssh).
            match peer.get("url").and_then(Value::as_str).filter(|url| ssh_target(url).is_ok()) {
                Some(url) => (
                    Some(format!("cmux acp host add {quoted} {}", quote(url))),
                    "the undo points the peer name back at the machine it named before; acpmux \
                     stays installed on the new machine",
                ),
                None => (
                    None,
                    "the name named a peer that is not reached over ssh; its token is not in a \
                     command, so re-add it with `cmux acp host add NAME URL --token TOKEN`",
                ),
            }
        }
    }
}

/// `acp host setup|update ... --json`, the arguments after this executable.
fn acp_argv(plan: Plan, target: &str, name: &str, port: u16) -> Vec<String> {
    let mut argv = vec!["acp".to_owned(), "host".to_owned()];
    match plan {
        Plan::Update => argv.extend(["update".to_owned(), name.to_owned()]),
        Plan::Setup => {
            argv.extend([
                "setup".to_owned(),
                target.to_owned(),
                "--name".to_owned(),
                name.to_owned(),
            ]);
            if port != SSH_PEER_PORT {
                argv.extend(["--port".to_owned(), port.to_string()]);
            }
        }
    }
    argv.push("--json".to_owned());
    argv
}

/// `argv` as the `cmux ...` command a person or agent would type.
fn display(argv: &[String]) -> String {
    let words = argv.iter().map(|arg| quote(arg)).collect::<Vec<_>>();
    format!("cmux {}", words.join(" "))
}

fn quote(arg: &str) -> String {
    super::super::fix_command::quote_arg(arg)
}

/// The command `status` names for a peer that needs setup.
fn setup_command(target: &str, name: &str) -> String {
    format!("cmux setup machine {} --name {}", quote(target), quote(name))
}

/// The ssh options of the probe: keys only, and a bounded wait, as acpmux's
/// own ssh calls use.
const SSH_OPTIONS: [&str; 4] = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"];

/// The ssh command the person runs to see what the probe saw.
fn test_command(target: &str) -> String {
    format!("ssh {} {} true", SSH_OPTIONS.join(" "), quote(target))
}

/// Runs `true` on the machine with key-only ssh: Err with ssh's own words
/// when it does not answer or refuses the key. Writes nothing: with
/// BatchMode, ssh refuses an unknown host key instead of recording it.
fn probe(target: &str) -> Result<Result<(), String>, Refusal> {
    let output = Command::new("ssh")
        .args(SSH_OPTIONS)
        .args(["--", target, "true"])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| {
            Refusal::Failed(format!("cmux: setup machine: cannot run ssh: {error}"))
        })?;
    if output.status.success() {
        return Ok(Ok(()));
    }
    let said = String::from_utf8_lossy(&output.stderr);
    let said = said.lines().map(str::trim).rfind(|line| !line.is_empty());
    Ok(Err(said.map_or_else(|| format!("ssh exited with {}", output.status), str::to_owned)))
}

/// Runs `cmux <argv>` (this executable) and answers its JSON result, or why
/// it failed in acpmux's words.
fn run_acp(argv: &[String]) -> Result<Value, String> {
    let exe = std::env::current_exe().map_err(|error| format!("no cmux executable: {error}"))?;
    let output = Command::new(exe)
        .args(argv)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("{}: {error}", display(argv)))?;
    let result = serde_json::from_slice::<Value>(&output.stdout).ok();
    if output.status.success() {
        return result.ok_or_else(|| format!("{} printed no JSON result", display(argv)));
    }
    // A failed update row says why; otherwise acpmux's error envelope does.
    let row = result.as_ref().and_then(|result| {
        result.get("updated")?.as_array()?.iter().find_map(|row| row.get("error")?.as_str())
    });
    let stderr = String::from_utf8_lossy(&output.stderr);
    let envelope = serde_json::from_str::<Value>(stderr.trim()).ok();
    let message = row
        .map(str::to_owned)
        .or_else(|| {
            envelope.and_then(|e| {
                e.pointer("/error/message").and_then(Value::as_str).map(str::to_owned)
            })
        })
        .unwrap_or_else(|| stderr.trim().to_owned());
    Err(format!("{} failed: {message}", display(argv)))
}

/// The peer named `name` in a setup or update result.
fn after(result: &Value, name: &str) -> Option<Value> {
    result
        .get("peers")?
        .as_array()?
        .iter()
        .find(|peer| peer.get("name").and_then(Value::as_str) == Some(name))
        .cloned()
}

/// The acpmux version the machine reported: setup's `remoteVersion`, or the
/// version of update's row for the peer.
fn remote_version(result: &Value, name: &str) -> Value {
    if let Some(version) = result.get("remoteVersion").filter(|v| v.is_string()) {
        return version.clone();
    }
    result
        .get("updated")
        .and_then(Value::as_array)
        .and_then(|rows| {
            rows.iter().find(|row| row.get("peer").and_then(Value::as_str) == Some(name))
        })
        .and_then(|row| row.get("version"))
        .cloned()
        .unwrap_or(Value::Null)
}

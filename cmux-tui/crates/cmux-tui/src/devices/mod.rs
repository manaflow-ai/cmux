//! `cmux device …` (plans/cmux-next/add-device-DESIGN.md): one list, one
//! remove and one audit over every store that lets another device in
//! (acpmux peers and pairings, remote hosting), with the overlay network
//! behind one seam (`network.rs`). `cmux device add` with no `--yes` is the
//! app's Add Device card (the app action `device.add`); with `--yes` it is
//! the headless enroll on a machine with no app.

use cmux_json::JsonSet as _;

mod model;
mod network;
mod removal;
#[cfg(test)]
mod tests;

use std::io::{BufRead as _, IsTerminal as _, Write as _};
use std::path::PathBuf;
use std::process::{Command, Stdio};

use anyhow::{Context as _, anyhow, bail};
use serde_json::{Value, json};

use crate::remote_host::{audit, config as host_config, self_exe};
use model::{Device, Listing, Role, Sources, State};
use network::{Choice, TailscaleNetwork, WeftNetwork};

const USAGE: &str = "usage: (every verb takes --json, --jsonl or --quiet)
       cmux device list [--json] [--network auto|tailscale|weft] [--platform URL] [--cloud-token-file PATH | --cloud-token-stdin]
       cmux device add HOST --yes [--name NAME] [--json]
       cmux device invite [--role client|read-only] [--ttl 15m] [--label TEXT] [--json]
       cmux device remove ID|NAME|ADDRESS [--yes] [--json]
       cmux device audit [--limit N] [--json]
       cmux device network [--json]

  cmux device add HOST (no --yes) opens Add Device in the cmux app.";

/// The verbs this module runs; `add` only with `--yes`.
const VERBS: &[&str] = &["list", "ls", "remove", "rm", "audit", "network", "invite", "help"];

/// The output flags a device verb takes anywhere: before `device`, before the verb or after.
fn output_flag(word: &str) -> bool {
    matches!(word, "--json" | "--jsonl" | "--quiet" | "-q")
}

/// The words after `device` for [`run`], with output flags written before `device`
/// (`cmux --json device list`) kept; `None` when `cmux <raw_args>` is not a device verb run
/// here.
pub(crate) fn device_args(raw_args: &[String]) -> Option<Vec<String>> {
    let lead = raw_args.iter().take_while(|w| output_flag(w)).count();
    if raw_args.get(lead).map(String::as_str) != Some("device") {
        return None;
    }
    let (leading, after_lead) = raw_args.split_at_checked(lead)?;
    let rest = after_lead.get(1..).unwrap_or_default();
    let verb = rest.iter().position(|w| !output_flag(w));
    let handled = match verb.and_then(|i| rest.get(i..)) {
        Some([verb, ..]) if VERBS.contains(&verb.as_str()) => true,
        Some([verb, after @ ..]) if verb == "add" => {
            after.iter().any(|a| a == "--yes" || a == "-y")
        }
        None => true,
        _ => false,
    };
    handled.then(|| leading.iter().chain(rest).cloned().collect())
}

/// Runs `cmux device <rest>`; returns the exit code (0 ok, 1 failed, 2 usage).
pub(crate) fn run(rest: &[String]) -> i32 {
    // Output flags may come before the verb too (`cmux device --quiet list`).
    let (rest, quiet) = output_flags(rest);
    let (verb, args) = verb_and_args(&rest);
    let verb = verb.as_str();
    if quiet && matches!(verb, "remove" | "rm") && !args.iter().any(|a| a == "--yes" || a == "-y") {
        eprintln!("cmux device {verb}: --quiet cannot ask; pass --yes\n{USAGE}");
        return 2;
    }
    // Quiet prints nothing on success: stdout goes nowhere for the verb; stderr (errors,
    // the reason for a failure) stays.
    let _silenced = if quiet { Silenced::stdout() } else { None };
    let args = args.as_slice();
    let result = match verb {
        "list" | "ls" => list(args),
        "add" => add(args),
        "invite" => invite(args),
        "remove" | "rm" => remove(args),
        "audit" => show_audit(args),
        "network" => show_network(args),
        _ => {
            println!("{USAGE}");
            return if verb == "help" { 0 } else { 2 };
        }
    };
    match result {
        Ok(()) => 0,
        Err(e) if e.downcast_ref::<Usage>().is_some() => {
            eprintln!("cmux device {verb}: {e}\n{USAGE}");
            2
        }
        Err(e) => {
            eprintln!("cmux device {verb}: {e:#}");
            1
        }
    }
}

/// `args` with `--jsonl` read as `--json` (each verb prints one JSON line) and `--quiet`
/// (`-q`) taken out; whether it was there. Words after `--` stay as they are.
fn output_flags(args: &[String]) -> (Vec<String>, bool) {
    let mut quiet = false;
    let mut kept = Vec::with_capacity(args.len());
    let mut words = args.iter();
    for word in words.by_ref() {
        match word.as_str() {
            "--" => {
                kept.push(word.clone());
                break;
            }
            "--quiet" | "-q" => quiet = true,
            "--jsonl" => kept.push("--json".into()),
            _ => kept.push(word.clone()),
        }
    }
    kept.extend(words.cloned());
    (kept, quiet)
}

/// The verb (`help` when none) and its arguments, with a `--json` written before the verb
/// handed to it like one written after.
fn verb_and_args(words: &[String]) -> (String, Vec<String>) {
    let lead = words.iter().take_while(|w| *w == "--json").count();
    let Some(verb) = words.get(lead) else {
        return ("help".to_owned(), words.to_vec());
    };
    let before = words.get(..lead).unwrap_or_default();
    let after = words.get(lead + 1..).unwrap_or_default();
    (verb.clone(), before.iter().chain(after).cloned().collect())
}

/// Stdout pointed at the null device until this is dropped.
struct Silenced {
    #[cfg(unix)]
    saved: libc::c_int,
}

impl Silenced {
    #[cfg(unix)]
    fn stdout() -> Option<Self> {
        use std::os::fd::AsRawFd as _;
        let null = std::fs::OpenOptions::new().write(true).open("/dev/null").ok()?;
        let _ = std::io::stdout().flush();
        // SAFETY: dup and dup2 on this process's own descriptors; `saved` is restored on drop.
        let saved = unsafe { libc::dup(1) };
        if saved < 0 || unsafe { libc::dup2(null.as_raw_fd(), 1) } < 0 {
            return None;
        }
        Some(Self { saved })
    }

    #[cfg(not(unix))]
    fn stdout() -> Option<Self> {
        None
    }
}

impl Drop for Silenced {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            let _ = std::io::stdout().flush();
            // SAFETY: puts back the descriptor `stdout()` saved, then closes the copy.
            unsafe {
                libc::dup2(self.saved, 1);
                libc::close(self.saved);
            }
        }
    }
}

#[derive(Debug)]
struct Usage(String);

impl std::fmt::Display for Usage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Usage {}

fn usage(text: impl Into<String>) -> anyhow::Error {
    anyhow!(Usage(text.into()))
}

/// The flags of one verb: booleans and `--name value` pairs, then positionals.
struct Flags {
    values: Vec<(String, Option<String>)>,
    positional: Vec<String>,
}

impl Flags {
    fn parse(args: &[String], with_value: &[&str], booleans: &[&str]) -> anyhow::Result<Self> {
        let mut values = Vec::new();
        let mut positional = Vec::new();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let name = match arg.as_str() {
                "-y" => "yes",
                a => match a.strip_prefix("--") {
                    Some(n) => n,
                    None => {
                        positional.push(arg.clone());
                        continue;
                    }
                },
            };
            let (name, inline) = match name.split_once('=') {
                Some((n, v)) => (n, Some(v.to_owned())),
                None => (name, None),
            };
            if with_value.contains(&name) {
                let value = match inline {
                    Some(v) => v,
                    None => it
                        .next()
                        .cloned()
                        .ok_or_else(|| usage(format!("--{name} needs a value")))?,
                };
                values.push((name.to_owned(), Some(value)));
            } else if booleans.contains(&name) && inline.is_none() {
                values.push((name.to_owned(), None));
            } else {
                return Err(usage(format!("unknown flag --{name}")));
            }
        }
        Ok(Self { values, positional })
    }

    fn has(&self, name: &str) -> bool {
        self.values.iter().any(|(n, _)| n == name)
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.values.iter().find(|(n, _)| n == name).and_then(|(_, v)| v.as_deref())
    }
}

/// This program as `cmux` (argv[0]), so the `host` verbs, which exist only on the `cmux`
/// surface, run too when this is `cmux-tui` (the app runs its bundled `cmux-tui device …`).
fn cmux() -> anyhow::Result<Command> {
    let mut command = Command::new(self_exe()?);
    // Neither a join token nor the cmux credential reaches a child: the credential was read
    // once (`JoinAuth`) and a revoke step gets it on its stdin.
    command.env_remove("CMUX_JOIN").env_remove("CMUX_CLOUD_ACCESS_TOKEN");
    #[cfg(unix)]
    std::os::unix::process::CommandExt::arg0(&mut command, "cmux");
    Ok(command)
}

/// `cmux <args> --json` as JSON; a failed or silent run is `Err` with its stderr.
fn run_json(args: &[&str]) -> anyhow::Result<Value> {
    let out = cmux()?
        .args(args)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run cmux {}", args.join(" ")))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_owned();
        bail!("cmux {} failed: {err}", args.join(" "));
    }
    serde_json::from_slice(&out.stdout)
        .with_context(|| format!("cmux {} printed no JSON", args.join(" ")))
}

/// Reads every store. A store that does not answer (no acpmux daemon, no
/// remote-hosting file) adds nothing and a note, never a failure.
fn read_sources(auth: &JoinAuth, notes: &mut Vec<String>) -> Sources {
    let mut read = |args: &[&str], what: &str| match run_json(args) {
        Ok(v) => v,
        Err(e) => {
            notes.push(format!("{what}: {e:#}"));
            Value::Null
        }
    };
    let peers = read(&["acp", "host", "ls", "--json"], "agent peers");
    let pairing = read(&["acp", "host", "ticket", "ls", "--json"], "paired devices");
    let remote = match host_config::exists() {
        Ok(true) => match host_config::load() {
            Ok(c) => serde_json::to_value(&c).unwrap_or(Value::Null),
            Err(e) => {
                notes.push(format!("remote hosting: {e:#}"));
                Value::Null
            }
        },
        _ => Value::Null,
    };
    // The team's joined machines, when a cmux credential is set (cmux machine add).
    #[cfg(unix)]
    let joined =
        match crate::cli::joined_machine_rows(auth.platform.as_deref(), auth.credential.clone()) {
            Some(Ok(rows)) => Value::Array(rows),
            Some(Err(e)) => {
                notes.push(format!("joined machines: {e}"));
                Value::Null
            }
            None => Value::Null,
        };
    #[cfg(not(unix))]
    let joined = {
        let _ = auth;
        Value::Null
    };
    Sources {
        peers,
        pairing,
        remote,
        ssh_hosts: crate::machine_runtime::ssh_config_targets(),
        joined,
    }
}

fn choice(flags: &Flags) -> anyhow::Result<Choice> {
    let text = flags
        .value("network")
        .map(str::to_owned)
        .or_else(|| std::env::var("CMUX_DEVICES_NETWORK").ok())
        .unwrap_or_default();
    Choice::parse(&text)
        .ok_or_else(|| usage(format!("--network must be auto, tailscale or weft, not {text:?}")))
}

/// How `device list|remove` sign in to the cmux platform for joined machines.
#[derive(Default)]
struct JoinAuth {
    platform: Option<String>,
    credential: Option<String>,
}

/// The flags that name the platform and the cmux credential.
const JOIN_VALUES: [&str; 2] = ["platform", "cloud-token-file"];

impl JoinAuth {
    /// `--platform`, and the credential from `--cloud-token-stdin`, `--cloud-token-file` or
    /// `CMUX_CLOUD_ACCESS_TOKEN`. An unreadable one is a usage error that names neither.
    #[cfg(unix)]
    fn read(flags: &Flags) -> anyhow::Result<Self> {
        let credential = crate::cli::joined_machine_credential(
            flags.value("cloud-token-file").map(PathBuf::from),
            flags.has("cloud-token-stdin"),
        )
        .map_err(usage)?;
        Ok(Self { platform: flags.value("platform").map(str::to_owned), credential })
    }

    #[cfg(not(unix))]
    fn read(_flags: &Flags) -> anyhow::Result<Self> {
        Ok(Self::default())
    }
}

fn current(flags: &Flags, auth: &JoinAuth, notes: &mut Vec<String>) -> anyhow::Result<Listing> {
    let net =
        network::pick(choice(flags)?, Box::new(WeftNetwork), || Box::new(TailscaleNetwork::read()));
    let sources = read_sources(auth, notes);
    Ok(model::merge(&sources, net.status(), &net.nodes()))
}

fn list(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(
        args,
        &["network", JOIN_VALUES[0], JOIN_VALUES[1]],
        &["json", "cloud-token-stdin"],
    )?;
    let auth = JoinAuth::read(&flags)?;
    let mut notes = Vec::new();
    let listing = current(&flags, &auth, &mut notes)?;
    if flags.has("json") {
        let mut v = serde_json::to_value(&listing)?;
        v.set("notes", json!(notes));
        println!("{v}");
        return Ok(());
    }
    print_listing(&listing, &notes);
    Ok(())
}

fn role_words(role: Role) -> &'static str {
    match role {
        Role::RunsAgents => "runs your agents",
        Role::UsesThis => "can use this computer",
        Role::WatchOnly => "can watch only",
    }
}

fn state_words(state: State) -> &'static str {
    match state {
        State::Connected => "connected",
        State::Offline => "offline",
        State::Pending => "waiting for approval",
        State::Error => "not working",
    }
}

fn print_listing(listing: &Listing, notes: &[String]) {
    let net = &listing.network;
    match (&net.this, net.up) {
        (Some(this), true) => println!("Network: {} (this computer is {this})", net.kind.name()),
        _ => println!(
            "Network: none{}",
            net.detail.as_deref().map(|d| format!(" ({d})")).unwrap_or_default()
        ),
    }
    if listing.devices.is_empty() {
        println!("\nNo devices yet. Add one: cmux device add HOST, or Add Device in the cmux app.");
    } else {
        println!("\nDevices:");
        for d in &listing.devices {
            let roles: Vec<&str> = d.roles.iter().copied().map(role_words).collect();
            println!("  {:<28} {:<22} {}", d.name, state_words(d.state), roles.join(", "));
            if let Some(detail) = &d.detail {
                println!("  {:<28} {detail}", "");
            }
        }
    }
    if !listing.invites.is_empty() {
        println!("\nOpen invites:");
        for i in &listing.invites {
            println!(
                "  {} ({}) until {}",
                i.label.as_deref().unwrap_or(&i.id),
                i.role,
                i.expires_at
            );
        }
    }
    if !listing.available.is_empty() {
        println!("\nNot added yet (your network and ~/.ssh/config):");
        for a in &listing.available {
            println!(
                "  {:<28} {:<10} cmux device add {} --yes",
                a.name,
                a.os,
                shell_word(&a.address)
            );
        }
    }
    for note in notes {
        println!("\nNote: {note}");
    }
}

/// `text` as one shell word for a command a person copies: as is when it is
/// only letters, digits and `@%+=:,./-_`, else single-quoted (an ssh alias
/// may hold anything ssh's config grammar allows).
fn shell_word(text: &str) -> String {
    let plain = !text.is_empty()
        && text.chars().all(|c| c.is_ascii_alphanumeric() || "@%+=:,./-_".contains(c));
    if plain { text.to_owned() } else { format!("'{}'", text.replace('\'', "'\\''")) }
}

/// Who did it, for the audit: the login when known, else the OS user.
fn actor() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "unknown".into())
}

fn record(event: &str, fields: Value) {
    let mut entry = json!({"event": event, "by": actor(), "via": "cli"});
    if let (Some(map), Some(extra)) = (entry.as_object_mut(), fields.as_object()) {
        map.extend(extra.clone());
    }
    audit::append(&entry);
}

fn add(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["name"], &["json", "yes"])?;
    let [host] = flags.positional.as_slice() else {
        return Err(usage("needs exactly one HOST (a name, an address or user@host)"));
    };
    let mut enroll =
        vec!["acp".to_owned(), "host".into(), "enroll".into(), host.clone(), "--json".into()];
    if let Some(name) = flags.value("name") {
        enroll.extend(["--name".into(), name.to_owned()]);
    }
    let mut child = cmux()?
        .args(&enroll)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .context("cannot start the enroll")?;
    let stdout = child.stdout.take().context("no enroll output")?;
    let mut report = Value::Null;
    for line in std::io::BufReader::new(stdout).lines() {
        let line = line?;
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if flags.has("json") {
            println!("{line}");
        } else if let Some(step) = v["step"].as_str() {
            let state = v["state"].as_str().unwrap_or_default();
            let detail = v["detail"].as_str().unwrap_or_default();
            println!("  {step:<10} {state:<6} {detail}");
            if let Some(fix) = v["fix"].as_str() {
                println!("  {:<10} fix: {fix}", "");
            }
        }
        if v.get("report").is_some() {
            report = v["report"].clone();
        }
    }
    let status = child.wait()?;
    let ok = status.success() && report["ok"].as_bool() == Some(true);
    let name = report["name"].as_str().unwrap_or(host);
    record(
        if ok { "device.added" } else { "device.add_failed" },
        json!({"device": format!("peer:{name}"), "host": host, "method": "enroll"}),
    );
    if !ok {
        bail!("{name} was not added; the step that failed says why");
    }
    if !flags.has("json") {
        println!("Added {name}. It runs your agents now.");
    }
    Ok(())
}

fn invite(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["role", "ttl", "label", "url"], &["json"])?;
    let role = flags.value("role").unwrap_or("client");
    if !matches!(role, "client" | "read-only") {
        return Err(usage(
            "--role must be client or read-only (a daemon-role invite: cmux host ticket new)",
        ));
    }
    let mut cmd = vec!["acp", "host", "ticket", "new", "--role", role, "--json"];
    for key in ["ttl", "label", "url"] {
        if let Some(v) = flags.value(key) {
            cmd.push(match key {
                "ttl" => "--ttl",
                "label" => "--label",
                _ => "--url",
            });
            cmd.push(v);
        }
    }
    let v = run_json(&cmd)?;
    record(
        "device.invited",
        json!({"invite": v["id"], "role": role, "label": v["label"], "expires_at": v["expires_at"]}),
    );
    if flags.has("json") {
        println!("{v}");
    } else {
        println!(
            "On the new computer, run:\n\n  {}\n",
            v["install_command"].as_str().unwrap_or_default()
        );
        println!(
            "It works once, until {}. Cancel it: cmux device remove {}",
            v["expires_at"].as_str().unwrap_or_default(),
            v["id"].as_str().unwrap_or_default()
        );
    }
    Ok(())
}

/// Runs one removal step; `stdin_line` (a credential) goes to its stdin, then it closes.
fn run_step(args: &[&str], stdin_line: Option<&str>) -> std::io::Result<std::process::Output> {
    let Some(line) = stdin_line else {
        return cmux().map_err(std::io::Error::other)?.args(args).stdin(Stdio::null()).output();
    };
    let mut child = cmux()
        .map_err(std::io::Error::other)?
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(line.as_bytes())?;
        stdin.write_all(b"\n")?;
    }
    child.wait_with_output()
}

fn confirm(question: &str) -> anyhow::Result<bool> {
    if !std::io::stdin().is_terminal() {
        return Ok(false);
    }
    print!("{question} [y/N] ");
    std::io::stdout().flush()?;
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    Ok(matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
}

fn remove(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(
        args,
        &["network", JOIN_VALUES[0], JOIN_VALUES[1]],
        &["json", "yes", "cloud-token-stdin"],
    )?;
    let auth = JoinAuth::read(&flags)?;
    let [key] = flags.positional.as_slice() else {
        return Err(usage("needs exactly one device: its id, name or address (cmux device list)"));
    };
    let mut notes = Vec::new();
    let listing = current(&flags, &auth, &mut notes)?;
    // An open invite is removed by its ticket id.
    if let Some(invite) = listing.invites.iter().find(|i| i.id == *key) {
        let v = run_json(&["acp", "host", "ticket", "revoke", &invite.id, "--json"])?;
        record("device.invite_revoked", json!({"invite": invite.id}));
        if flags.has("json") {
            println!("{}", json!({"removed": {"invite": invite.id}, "result": v}));
        } else {
            println!("Cancelled the invite {}.", invite.id);
        }
        return Ok(());
    }
    let device: Device = model::find(&listing, key)
        .cloned()
        .ok_or_else(|| anyhow!("no device {key:?} here (cmux device list shows them)"))?;
    let steps = removal::plan(&device);
    if !flags.has("yes") {
        let what: Vec<&str> = steps.iter().map(|s| s.what.as_str()).collect();
        println!("Removing {} will:\n  - {}", device.name, what.join("\n  - "));
        if !confirm("Remove it?")? {
            bail!("not removed (pass --yes to remove without asking)");
        }
    }
    let mut done = Vec::new();
    let mut failed = Vec::new();
    for step in &steps {
        let mut args: Vec<&str> = step.args.iter().map(String::as_str).collect();
        // A joined machine's revoke signs in as this remove did: the credential on its
        // stdin, never in its argv or environment.
        let credential =
            if args.first() == Some(&"machine") { auth.credential.as_deref() } else { None };
        if args.first() == Some(&"machine")
            && let Some(platform) = auth.platform.as_deref()
        {
            args.extend(["--platform", platform]);
        }
        if credential.is_some() {
            args.push("--cloud-token-stdin");
        }
        let out = run_step(&args, credential);
        match out {
            Ok(o) if o.status.success() => done.push(step.what.clone()),
            Ok(o) => failed.push(
                json!({"step": step.what, "error": String::from_utf8_lossy(&o.stderr).trim()}),
            ),
            Err(e) => failed.push(json!({"step": step.what, "error": e.to_string()})),
        }
    }
    record(
        if failed.is_empty() { "device.removed" } else { "device.remove_partial" },
        json!({"device": device.id, "name": device.name, "done": done, "failed": failed}),
    );
    if flags.has("json") {
        println!("{}", json!({"removed": device, "done": done, "failed": failed}));
    } else {
        for d in &done {
            println!("  done: {d}");
        }
        for f in &failed {
            println!(
                "  failed: {} ({})",
                f["step"].as_str().unwrap_or_default(),
                f["error"].as_str().unwrap_or_default()
            );
        }
    }
    if !failed.is_empty() {
        bail!(
            "{} is only partly removed; run this again after fixing the failed step",
            device.name
        );
    }
    if !flags.has("json") {
        println!("Removed {}.", device.name);
    }
    Ok(())
}

fn audit_path() -> anyhow::Result<PathBuf> {
    Ok(host_config::dir()?.join(audit::FILE))
}

fn show_audit(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["limit"], &["json"])?;
    let limit: usize = match flags.value("limit") {
        Some(n) => n.parse().map_err(|_| usage("--limit must be a number"))?,
        None => 50,
    };
    let path = audit_path()?;
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let entries: Vec<Value> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    let start = entries.len().saturating_sub(limit);
    let recent: Vec<Value> = entries[start..].iter().rev().cloned().collect();
    if flags.has("json") {
        println!("{}", json!({"path": path.display().to_string(), "entries": recent}));
        return Ok(());
    }
    if recent.is_empty() {
        println!("No device activity on this computer yet.");
    }
    for e in &recent {
        let what = e["event"].as_str().or(e["decision"].as_str()).unwrap_or("event");
        let who = e["name"]
            .as_str()
            .or(e["device"].as_str())
            .or(e["login"].as_str())
            .or(e["invite"].as_str())
            .unwrap_or("");
        println!("{}  {what:<22} {who}", e["ts"].as_str().unwrap_or_default());
    }
    Ok(())
}

fn show_network(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["network"], &["json"])?;
    let net =
        network::pick(
            choice(&flags)?,
            Box::new(WeftNetwork),
            || Box::new(TailscaleNetwork::read()),
        );
    let status = net.status();
    if flags.has("json") {
        let nodes = net.nodes();
        println!(
            "{}",
            json!({"network": status, "nodes": nodes.len(), "online": nodes.iter().filter(|n| n.online).count()})
        );
    } else if status.up {
        println!(
            "{}: up, this computer is {}",
            status.kind.name(),
            status.this.unwrap_or_default()
        );
    } else {
        println!("{}: not up. {}", status.kind.name(), status.detail.unwrap_or_default());
    }
    Ok(())
}

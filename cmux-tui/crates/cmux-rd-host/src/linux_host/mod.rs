//! `cmux-rd linux-host`: this Linux desktop as a device hub screen host, viewed from cmux on
//! a Mac exactly like a shared Mac (docs/device-hub/PROTOCOL.md). The Mac app holds a Mac's
//! device key and hub link and drives `cmux-rd serve`; on Linux this command does that job.
//!
//!   enable --stack-token-file PATH|- [--hub URL] [--name NAME] [--allow-control]
//!       Signs in once with a cmux (Stack Auth) access token, registers this desktop as a
//!       `linux` device, anchors it (it renews its own host session for 30 days with its
//!       device key, no token) and turns sharing on. Control (input) is off unless
//!       `--allow-control`.
//!   share on --stack-token-file PATH|- | share off
//!   run [--display :0] [--xauthority PATH] [--capture x11|portal]
//!       The host: holds the hub socket and serves approved sessions. Run it in the desktop
//!       user's graphical session (the user systemd unit `systemd/cmux-screen-host.service`).
//!   requests                       viewers asking for access, waiting for the person
//!   approve SESSION [--always] [--scope view|full]
//!   deny SESSION
//!   status
//!
//! Consent: a viewer the person already allowed (the hub's `view`/`full` permission) is
//! served; any other request waits for `approve` and is never answered by the host itself
//! (consent.rs). A `view` session applies no input.

mod b64;
mod consent;
mod hub;
mod identity;
mod net;
mod rd_doc;
mod session;

use crate::Res;
use consent::{LocalConsent, Pending};
use hub::{now_ms, Hub, HubError};
use identity::{Account, Device};
use net::Message;
use serde_json::Value;
use session::{ServeArgs, Ticket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The production device hub (the Mac app's default).
const DEFAULT_HUB: &str = "https://cmux-device-hub.debussy.workers.dev";
const PING_EVERY: Duration = Duration::from_secs(30);

const USAGE: &str = "usage: cmux-rd linux-host enable --stack-token-file PATH|- [--hub URL] [--name NAME] [--allow-control]
       cmux-rd linux-host share on --stack-token-file PATH|- | share off
       cmux-rd linux-host run [--display :0] [--xauthority PATH] [--capture x11|portal]
       cmux-rd linux-host requests | approve SESSION [--always] [--scope view|full] | deny SESSION | status";

/// The exit code when the host cannot go on until the person acts (the hub removed this
/// desktop, its device key no longer matches, or its 30-day anchor ended). The user unit lists
/// it in `RestartPreventExitStatus=`, so systemd stops instead of restarting it forever.
/// 78 is sysexits' EX_CONFIG.
pub const EXIT_NEEDS_SETUP: i32 = 78;

/// A hub error restarting cannot fix, with the command that does.
#[derive(Debug)]
struct Fatal(String);

impl std::fmt::Display for Fatal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Fatal {}

impl Fatal {
    const ENABLE: &'static str = "cmux-rd linux-host enable --stack-token-file PATH|-";
    const SHARE_ON: &'static str = "cmux-rd linux-host share on --stack-token-file PATH|-";

    fn needs(what: &str, command: &str) -> Self {
        Self(format!(
            "{what}. The host stopped and will not restart by itself. To share this desktop again, run: {command}, then: systemctl --user restart cmux-screen-host.service"
        ))
    }

    /// The fatal form of a hub error, or None for one worth retrying.
    fn from_hub(e: &(dyn std::error::Error + Send + Sync + 'static)) -> Option<Self> {
        let h = e.downcast_ref::<HubError>()?;
        let detail = printable(&h.message);
        match h.code.as_str() {
            "device_removed" => Some(Self::needs(
                &format!("This desktop is no longer on the account ({detail})"),
                Self::ENABLE,
            )),
            "device_key_mismatch" => Some(Self::needs(
                &format!("The hub no longer knows this desktop's key ({detail})"),
                Self::ENABLE,
            )),
            "not_anchored" => Some(Self::needs(
                &format!("This desktop's 30-day sign-in ended ({detail})"),
                Self::SHARE_ON,
            )),
            _ => None,
        }
    }
}

/// The exit code for an error `run_cli` reports.
fn exit_code(e: &(dyn std::error::Error + Send + Sync + 'static)) -> i32 {
    if e.is::<Fatal>() {
        EXIT_NEEDS_SETUP
    } else {
        1
    }
}

/// Bidi formatting characters: they reorder what a terminal shows (U+202E turns a name
/// around) though `char::is_control` does not count them.
fn is_bidi_control(c: char) -> bool {
    matches!(
        c,
        '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
    )
}

/// Text from the hub or a viewer, safe to print to a terminal or the journal: C0 and C1
/// controls, whole ANSI escape sequences (CSI, OSC and the like) and bidi controls removed.
pub(crate) fn printable(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                // CSI: parameters and intermediates, then one final character in @..~.
                Some('[') => {
                    for c in chars.by_ref() {
                        if ('@'..='~').contains(&c) {
                            break;
                        }
                    }
                }
                // OSC, DCS, SOS, PM, APC: a string ended by BEL or ESC \.
                Some(']' | 'P' | 'X' | '^' | '_') => {
                    while let Some(c) = chars.next() {
                        if c == '\u{7}' {
                            break;
                        }
                        if c == '\u{1b}' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                // A two-character escape (ESC c, ESC 7, ...).
                _ => {}
            },
            c if c.is_control() || is_bidi_control(c) => {}
            c => out.push(c),
        }
    }
    out
}

/// One `requests` line.
fn request_line(r: &consent::Request) -> String {
    let what = if r.scope == "full" { "control" } else { "view" };
    let fp = match r.viewer_key_fingerprint.as_deref().map(printable) {
        // 16 characters, not bytes: a byte cut panics inside a multi-byte character.
        Some(f) if !f.is_empty() => f.chars().take(16).collect(),
        _ => "-".to_owned(),
    };
    format!(
        "{}  {} (key {fp}) asks to {what} this desktop",
        printable(&r.id),
        printable(&r.viewer_name)
    )
}

/// The journal line for a viewer waiting for the person.
fn ask_line(r: &consent::Request) -> String {
    let what = if r.scope == "full" { "control" } else { "view" };
    let id = printable(&r.id);
    format!(
        "linux-host: {} asks to {what} this desktop. Allow: cmux-rd linux-host approve {id} [--always]; refuse: cmux-rd linux-host deny {id}",
        printable(&r.viewer_name)
    )
}

/// Flags that take no value.
const FLAGS: &[&str] = &["always", "allow-control"];

struct Args {
    positional: Vec<String>,
    options: Vec<(String, String)>,
}

impl Args {
    fn parse(args: &[String]) -> Result<Self, String> {
        let (mut positional, mut options) = (Vec::new(), Vec::new());
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            match arg.strip_prefix("--") {
                Some(key) if FLAGS.contains(&key) => options.push((key.to_owned(), "1".to_owned())),
                Some(key) => {
                    let value = it.next().ok_or_else(|| format!("missing value for --{key}"))?;
                    options.push((key.to_owned(), value.clone()));
                }
                None => positional.push(arg.clone()),
            }
        }
        Ok(Self { positional, options })
    }

    fn get(&self, key: &str) -> Option<&str> {
        self.options.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }

    fn flag(&self, key: &str) -> bool {
        self.get(key) == Some("1")
    }

    fn only(&self, allowed: &[&str]) -> Result<(), String> {
        match self.options.iter().find(|(k, _)| !allowed.contains(&k.as_str())) {
            Some((k, _)) => Err(format!("--{k} is not an option of this command")),
            None => Ok(()),
        }
    }
}

/// Runs `cmux-rd linux-host ARGS`; the exit code.
pub fn run_cli(args: &[String]) -> i32 {
    let parsed = match Args::parse(args) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}\n{USAGE}");
            return 2;
        }
    };
    let words: Vec<&str> = parsed.positional.iter().map(String::as_str).collect();
    let result = match words.as_slice() {
        ["enable"] => parsed
            .only(&["stack-token-file", "hub", "name", "allow-control"])
            .map_err(Into::into)
            .and_then(|()| enable(&parsed)),
        ["share", "on"] => {
            parsed.only(&["stack-token-file"]).map_err(Into::into).and_then(|()| share_on(&parsed))
        }
        ["share", "off"] => parsed.only(&[]).map_err(Into::into).and_then(|()| share_off()),
        ["run"] => parsed
            .only(&["display", "xauthority", "capture"])
            .map_err(Into::into)
            .and_then(|()| run(&parsed)),
        ["requests"] => parsed.only(&[]).map_err(Into::into).and_then(|()| requests()),
        ["approve", id] => parsed
            .only(&["always", "scope"])
            .map_err(Into::into)
            .and_then(|()| approve(id, &parsed)),
        ["deny", id] => parsed.only(&[]).map_err(Into::into).and_then(|()| deny(id)),
        ["status"] => parsed.only(&[]).map_err(Into::into).and_then(|()| status()),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux-rd linux-host: {e}");
            exit_code(&*e)
        }
    }
}

/// The access token from `--stack-token-file` (this user's 0600 file, or `-` for stdin).
fn stack_token(args: &Args) -> Res<String> {
    let path = args
        .get("stack-token-file")
        .ok_or("needs --stack-token-file PATH (or - for stdin): a cmux sign-in access token")?;
    let text = if path == "-" {
        let mut text = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin().lock(), &mut text)?;
        text
    } else {
        let bytes = identity::read_private(std::path::Path::new(path))?
            .ok_or_else(|| format!("{path} does not exist"))?;
        String::from_utf8(bytes).map_err(|_| format!("{path} is not text"))?
    };
    let token = text.trim().to_owned();
    if token.is_empty() || token.contains(char::is_whitespace) {
        return Err("the access token file must hold one token".into());
    }
    Ok(token)
}

/// The enabled host: its device, account and hub.
fn load() -> Res<(std::path::PathBuf, Hub, Account)> {
    let dir = identity::config_dir()?;
    let device = Device::load(&dir)?.ok_or("not enabled: run `cmux-rd linux-host enable` first")?;
    let account =
        Account::load(&dir)?.ok_or("not enabled: run `cmux-rd linux-host enable` first")?;
    let hub = Hub::new(&account.hub, device, Some(account.user_id.clone()))?;
    Ok((dir, hub, account))
}

fn enable(args: &Args) -> Res<()> {
    let token = stack_token(args)?;
    let dir = identity::config_dir()?;
    identity::private_dir(&dir)?;
    let hub_url = match (args.get("hub"), Account::load(&dir)?) {
        (Some(url), _) => url.to_owned(),
        (None, Some(account)) => account.hub,
        (None, None) => DEFAULT_HUB.to_owned(),
    };
    let device = match Device::load(&dir)? {
        Some(mut device) => {
            if let Some(name) = args.get("name") {
                device.name = name.to_owned();
            }
            device
        }
        None => Device::generate(
            args.get("name").map_or_else(identity::host_name, str::to_owned).as_str(),
        )?,
    };
    device.save(&dir)?;
    let hub = Hub::new(&hub_url, device, None)?;
    let user_id = hub.sign_in_with_stack(&token)?;
    hub.register()?;
    let anchored_until = hub.anchor()?;
    hub.set_shared(true)?;
    Account { hub: hub_url, user_id, anchored_until }.save(&dir)?;
    let consent = LocalConsent { view: true, full: args.flag("allow-control") };
    consent.save(&dir)?;
    println!(
        "This desktop is shared as \"{}\" ({}), {}. Start the host: systemctl --user enable --now cmux-screen-host.service",
        hub.device.name,
        hub.device.id,
        if consent.full { "view and control" } else { "view only" }
    );
    Ok(())
}

fn share_on(args: &Args) -> Res<()> {
    let (dir, hub, mut account) = load()?;
    // Turning sharing on needs the account itself (a host session may only turn it off).
    hub.sign_in_with_stack(&stack_token(args)?)?;
    account.anchored_until = hub.anchor()?;
    hub.set_shared(true)?;
    account.save(&dir)?;
    println!("Sharing is on.");
    Ok(())
}

fn share_off() -> Res<()> {
    let (_, hub, _) = load()?;
    hub.set_shared(false)?;
    println!("Sharing is off; the hub ended any session.");
    Ok(())
}

fn requests() -> Res<()> {
    let list = Pending::new(&identity::runtime_dir()?).list(now_ms())?;
    if list.is_empty() {
        println!("No viewer is waiting.");
    }
    for r in list {
        println!("{}", request_line(&r));
    }
    Ok(())
}

fn approve(id: &str, args: &Args) -> Res<()> {
    let (dir, hub, _) = load()?;
    let runtime = identity::runtime_dir()?;
    let pending = Pending::new(&runtime);
    let now = now_ms();
    // Only a request this host recorded: an id from anywhere else is refused.
    let request =
        pending.list(now)?.into_iter().find(|r| r.id == id).ok_or_else(|| {
            format!("no waiting request {id} (see `cmux-rd linux-host requests`)")
        })?;
    let scope = consent::decision_scope(&request, args.get("scope"), LocalConsent::load(&dir)?)?;
    let decision = if args.flag("always") { "always" } else { "once" };
    hub.decide(id, decision, Some(&scope))?;
    pending.remove(id, now)?;
    println!(
        "Approved {} to {} this desktop{}.",
        printable(&request.viewer_name),
        if scope == "full" { "control" } else { "view" },
        if decision == "always" { " from now on" } else { " once" }
    );
    Ok(())
}

fn deny(id: &str) -> Res<()> {
    let (_, hub, _) = load()?;
    let runtime = identity::runtime_dir()?;
    let pending = Pending::new(&runtime);
    let now = now_ms();
    pending
        .list(now)?
        .into_iter()
        .find(|r| r.id == id)
        .ok_or_else(|| format!("no waiting request {id}"))?;
    hub.decide(id, "deny", None)?;
    pending.remove(id, now)?;
    println!("Denied.");
    Ok(())
}

fn status() -> Res<()> {
    let dir = identity::config_dir()?;
    let Some(device) = Device::load(&dir)? else {
        println!("Not enabled.");
        return Ok(());
    };
    let consent = LocalConsent::load(&dir)?;
    match Account::load(&dir)? {
        Some(a) => println!(
            "{} ({}) on {}, anchored until {} (Unix ms), {}",
            device.name,
            device.id,
            a.hub,
            a.anchored_until,
            if consent.full { "view and control" } else { "view only" }
        ),
        None => println!("{} ({}), not signed in", device.name, device.id),
    }
    Ok(())
}

/// The session this host serves now (one at a time; a newer ticket replaces it).
type Current = Arc<Mutex<Option<(String, Arc<AtomicBool>)>>>;

fn run(args: &Args) -> Res<()> {
    let (dir, hub, account) = load()?;
    let runtime = identity::runtime_dir()?;
    identity::private_dir(&runtime)?;
    let consent = LocalConsent::load(&dir)?;
    let mut serve_args = Vec::new();
    for key in ["display", "xauthority", "capture"] {
        if let Some(v) = args.get(key) {
            serve_args.extend([format!("--{key}"), v.to_owned()]);
        }
    }
    // The capture choice is checked now, so a bad --capture fails at start, not per session.
    crate::capture_backend::CaptureBackend::from_env(args.get("capture"))?;
    let serve_args = ServeArgs(serve_args);
    if account.anchored_until != 0 && account.anchored_until <= now_ms() {
        return Err(Fatal::needs("This desktop's 30-day sign-in ended", Fatal::SHARE_ON).into());
    }
    let hub = Arc::new(hub);
    let current: Current = Arc::new(Mutex::new(None));
    let mut backoff = Duration::from_secs(1);
    eprintln!("linux-host: serving \"{}\" ({})", hub.device.name, hub.device.id);
    loop {
        let started = Instant::now();
        match hold_socket(&hub, &runtime, consent, &serve_args, &current) {
            Ok(()) => {}
            Err(e) => {
                if let Some(fatal) = Fatal::from_hub(&*e) {
                    return Err(fatal.into());
                }
                eprintln!("linux-host: hub link: {e}");
            }
        }
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_secs(1);
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

/// Holds one User DO socket until it closes; handles its pushes.
fn hold_socket(
    hub: &Arc<Hub>,
    runtime: &std::path::Path,
    consent: LocalConsent,
    serve_args: &ServeArgs,
    current: &Current,
) -> Res<()> {
    let mut ws = hub.user_socket()?;
    let mut last_ping = Instant::now();
    loop {
        if last_ping.elapsed() >= PING_EVERY {
            // Exactly these bytes: the hub's auto-response matches them.
            ws.send_text(r#"{"type":"ping"}"#)?;
            last_ping = Instant::now();
        }
        match ws.recv(Duration::from_secs(1))? {
            None => {}
            Some(Message::Closed(code, reason)) => {
                return match code {
                    4001 => Err(HubError {
                        status: 403,
                        code: "device_removed".into(),
                        message: "this desktop was removed from the account".into(),
                    }
                    .into()),
                    4003 => Err(HubError {
                        status: 403,
                        code: "device_removed".into(),
                        message: "this desktop was signed out".into(),
                    }
                    .into()),
                    _ => Err(format!("socket closed ({code} {})", printable(&reason)).into()),
                };
            }
            Some(Message::Text(text)) => {
                let Ok(push) = serde_json::from_str::<Value>(&text) else { continue };
                handle_push(hub, &push, runtime, consent, serve_args, current);
            }
        }
    }
}

fn handle_push(
    hub: &Arc<Hub>,
    push: &Value,
    runtime: &std::path::Path,
    consent: LocalConsent,
    serve_args: &ServeArgs,
    current: &Current,
) {
    let pending = Pending::new(runtime);
    match push["type"].as_str() {
        Some("session.request") => {
            let Ok(mut request) =
                serde_json::from_value::<consent::Request>(push["session"].clone())
            else {
                return;
            };
            request.received_ms = now_ms();
            match consent::on_request(&request) {
                consent::OnRequest::AskThePerson => {
                    eprintln!("{}", ask_line(&request));
                    if let Err(e) = pending.add(request, now_ms()) {
                        eprintln!("linux-host: request not recorded: {e}");
                    }
                }
            }
        }
        Some("session.ticket") if push["role"].as_str() == Some("host") => {
            let ticket = match Ticket::from_push(push) {
                Ok(t) => t,
                Err(e) => {
                    eprintln!("linux-host: ticket refused: {e}");
                    return;
                }
            };
            let Some(view_only) = consent.serve(&ticket.scope) else {
                eprintln!(
                    "linux-host: a {} session is not allowed on this desktop; ended",
                    printable(&ticket.scope)
                );
                end_later(hub, &ticket.session_id, "failed");
                return;
            };
            start_session(hub, ticket, view_only, serve_args, current);
        }
        Some("session.revoked" | "session.ended" | "session.denied") => {
            let Some(id) = push["sessionId"].as_str() else { return };
            let _ = pending.remove(id, now_ms());
            let guard = current.lock().unwrap_or_else(|e| e.into_inner());
            if let Some((current_id, stop)) = guard.as_ref() {
                if current_id == id {
                    stop.store(true, Ordering::SeqCst);
                }
            }
        }
        _ => {}
    }
}

fn start_session(
    hub: &Arc<Hub>,
    ticket: Ticket,
    view_only: bool,
    serve_args: &ServeArgs,
    current: &Current,
) {
    let stop = Arc::new(AtomicBool::new(false));
    {
        let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((old, old_stop)) = guard.take() {
            // One viewer at a time, the newest. A reattach of the same session replaces its own.
            old_stop.store(true, Ordering::SeqCst);
            if old != ticket.session_id {
                end_later(hub, &old, "replaced");
            }
        }
        *guard = Some((ticket.session_id.clone(), stop.clone()));
    }
    let (hub, args, current) = (hub.clone(), serve_args.clone(), current.clone());
    let spawned = std::thread::Builder::new().name("linux-host-session".into()).spawn(move || {
        eprintln!(
            "linux-host: serving a {} session for {}",
            if view_only { "view" } else { "control" },
            printable(&ticket.peer_name)
        );
        let ended = session::serve(&hub, &ticket, view_only, &args, &stop);
        eprintln!("linux-host: session ended: {}", ended.reason);
        if let Some(reason) = ended.tell_hub {
            if let Err(e) = hub.end(&ticket.session_id, reason) {
                eprintln!("linux-host: end not sent: {e}");
            }
        }
        let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
        if guard.as_ref().is_some_and(|(id, s)| id == &ticket.session_id && Arc::ptr_eq(s, &stop)) {
            *guard = None;
        }
    });
    if let Err(e) = spawned {
        eprintln!("linux-host: session not started: {e}");
    }
}

/// `/end` off the socket thread.
fn end_later(hub: &Arc<Hub>, id: &str, reason: &'static str) {
    let (hub, id) = (hub.clone(), id.to_owned());
    let _ = std::thread::Builder::new().name("linux-host-end".into()).spawn(move || {
        if let Err(e) = hub.end(&id, reason) {
            eprintln!("linux-host: end not sent: {e}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn args_take_positionals_flags_and_values() {
        let a = Args::parse(&[
            "approve".into(),
            "s1".into(),
            "--always".into(),
            "--scope".into(),
            "view".into(),
        ])
        .unwrap();
        assert_eq!(a.positional, vec!["approve", "s1"]);
        assert!(a.flag("always"));
        assert_eq!(a.get("scope"), Some("view"));
        assert!(a.only(&["always", "scope"]).is_ok());
        assert!(a.only(&["always"]).is_err());
        assert!(Args::parse(&["--scope".into()]).is_err());
    }

    #[test]
    fn unknown_commands_are_usage_errors() {
        assert_eq!(run_cli(&["frobnicate".into()]), 2);
        assert_eq!(run_cli(&[]), 2);
    }

    const UNIT: &str = include_str!("../../systemd/cmux-screen-host.service");

    /// `[Service]` lines of the unit as (key, value), comments and blanks skipped.
    fn unit_directives() -> Vec<(String, String)> {
        UNIT.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#') && !l.starts_with(';'))
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
            .collect()
    }

    #[test]
    fn user_unit_needs_no_user_namespace() {
        // In a user unit each of these makes systemd set up a user namespace (PrivateUsers),
        // which Ubuntu 24.04+ forbids unprivileged processes through AppArmor: the unit would
        // not start. PrivateTmp also hides an XAUTHORITY or X socket kept in /tmp.
        const NEEDS_USERNS: &[&str] = &[
            "PrivateUsers",
            "PrivateTmp",
            "PrivateDevices",
            "PrivateNetwork",
            "PrivateIPC",
            "PrivateMounts",
            "PrivatePIDs",
            "ProtectSystem",
            "ProtectHome",
            "ProtectKernelTunables",
            "ProtectKernelModules",
            "ProtectKernelLogs",
            "ProtectControlGroups",
            "ProtectClock",
            "ProtectHostname",
            "ProtectProc",
            "ProcSubset",
            "ReadOnlyPaths",
            "ReadWritePaths",
            "InaccessiblePaths",
            "ExecPaths",
            "NoExecPaths",
            "TemporaryFileSystem",
            "BindPaths",
            "BindReadOnlyPaths",
            "MountAPIVFS",
            "RootDirectory",
            "RootImage",
            "NetworkNamespacePath",
            "IPCNamespacePath",
        ];
        let directives = unit_directives();
        assert!(directives.iter().any(|(k, _)| k == "ExecStart"), "unit not parsed");
        for (key, value) in &directives {
            assert!(
                !NEEDS_USERNS.contains(&key.as_str()),
                "{key}={value} needs a user namespace in a user unit"
            );
        }
    }

    #[test]
    fn fatal_hub_errors_stop_the_unit_with_a_next_step() {
        for (code, next) in [
            ("device_removed", "cmux-rd linux-host enable"),
            ("device_key_mismatch", "cmux-rd linux-host enable"),
            ("not_anchored", "cmux-rd linux-host share on"),
        ] {
            let e: Box<dyn std::error::Error + Send + Sync> =
                HubError { status: 403, code: code.into(), message: "m".into() }.into();
            let fatal = Fatal::from_hub(&*e).unwrap_or_else(|| panic!("{code} is not fatal"));
            assert!(fatal.to_string().contains(next), "{code}: {fatal}");
            let boxed: Box<dyn std::error::Error + Send + Sync> = fatal.into();
            assert_eq!(exit_code(&*boxed), EXIT_NEEDS_SETUP);
        }
        let transient: Box<dyn std::error::Error + Send + Sync> =
            HubError { status: 503, code: "unavailable".into(), message: "m".into() }.into();
        assert!(Fatal::from_hub(&*transient).is_none());
        assert_eq!(exit_code(&*transient), 1);
        assert_ne!(EXIT_NEEDS_SETUP, 1);
        assert_ne!(EXIT_NEEDS_SETUP, 2);
        // systemd must not restart it: the code is in RestartPreventExitStatus=.
        let prevented: Vec<String> = unit_directives()
            .into_iter()
            .filter(|(k, _)| k == "RestartPreventExitStatus")
            .flat_map(|(_, v)| v.split_whitespace().map(str::to_owned).collect::<Vec<_>>())
            .collect();
        assert!(
            prevented.contains(&EXIT_NEEDS_SETUP.to_string()),
            "RestartPreventExitStatus= lacks {EXIT_NEEDS_SETUP}: {prevented:?}"
        );
    }

    fn request(name: &str, fingerprint: Option<&str>) -> consent::Request {
        consent::Request {
            id: "s1".into(),
            viewer_id: "v1".into(),
            viewer_name: name.into(),
            viewer_key_fingerprint: fingerprint.map(str::to_owned),
            scope: "view".into(),
            received_ms: 0,
        }
    }

    #[test]
    fn hub_text_is_printed_without_control_characters() {
        assert_eq!(printable("Ann's Mac"), "Ann's Mac");
        assert_eq!(printable("\u{1b}[2J\u{1b}[31mEvil\u{1b}[0m"), "Evil");
        assert_eq!(printable("a\u{1b}]0;title\u{7}b"), "ab");
        assert_eq!(printable("x\ny\rz\t\u{0}\u{7f}\u{9b}1m"), "xyz1m");
        assert_eq!(printable("\u{202e}cod.exe\u{202c}\u{2066}\u{200f}"), "cod.exe");
        let hostile = "\u{1b}[2J\u{202e}Mallory\nlinux-host: approved";
        for line in [request_line(&request(hostile, None)), ask_line(&request(hostile, None))] {
            assert!(!line.chars().any(|c| c.is_control() || is_bidi_control(c)), "{line:?}");
            assert!(line.contains("Mallorylinux-host: approved"), "{line:?}");
        }
    }

    #[test]
    fn fingerprints_are_cut_on_a_character_boundary() {
        // 15 ASCII bytes then a 3-byte character across the 16-byte mark.
        let fp = "0123456789abcde\u{20ac}\u{20ac}tail";
        let line = request_line(&request("Ann", Some(fp)));
        assert!(line.contains("(key 0123456789abcde\u{20ac})"), "{line}");
        let line = request_line(&request("Ann", Some("\u{1b}[31m\u{e9}")));
        assert!(line.contains("(key \u{e9})"), "{line}");
        assert!(request_line(&request("Ann", None)).contains("(key -)"));
    }
}

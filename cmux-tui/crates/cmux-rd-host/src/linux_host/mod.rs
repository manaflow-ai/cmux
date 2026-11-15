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
            1
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
        let what = if r.scope == "full" { "control" } else { "view" };
        let fp = r.viewer_key_fingerprint.as_deref().map(|f| &f[..f.len().min(16)]).unwrap_or("-");
        println!("{}  {} (key {fp}) asks to {what} this desktop", r.id, r.viewer_name);
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
        request.viewer_name,
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
        return Err("the 30-day anchor ended: run `cmux-rd linux-host share on --stack-token-file ...` again".into());
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
                if let Some(h) = e.downcast_ref::<HubError>() {
                    if matches!(
                        h.code.as_str(),
                        "device_removed" | "not_anchored" | "device_key_mismatch"
                    ) {
                        return Err(e);
                    }
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
                    _ => Err(format!("socket closed ({code} {reason})").into()),
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
                    let what = if request.scope == "full" { "control" } else { "view" };
                    eprintln!(
                        "linux-host: {} asks to {what} this desktop. Allow: cmux-rd linux-host approve {} [--always]; refuse: cmux-rd linux-host deny {}",
                        request.viewer_name, request.id, request.id
                    );
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
                    ticket.scope
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
            ticket.peer_name
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
}

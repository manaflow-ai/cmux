//! `cmux-rd windows-host`: this Windows PC on the account's device hub, next to `cmux-rd
//! linux-host` and sharing its hub client (the cmux-hub-host crate). It registers the PC as a
//! `windows` device with its own device key, anchors it (it renews its own host session for 30
//! days with that key, no token) and holds the hub socket, so the PC lists on the account's
//! Macs as a Windows PC and as online while the host runs. It checks that it can capture this
//! desktop (GDI, the same capture as `cmux-rd host`) and reports what it captured.
//!
//!   enable --stack-token-file PATH|- [--hub URL] [--name NAME]
//!   run                            the host: holds the hub socket (run it in the desktop
//!                                  user's session, e.g. a logon scheduled task)
//!   status
//!   share off
//!
//! What it does not do yet: serve a viewing session. A hub session runs over the secure link
//! (`cmux-rd serve`, crate cmux-rd-link), whose UDP driver and session loop wait on Unix file
//! descriptors; until that loop has a Windows port, this host does not turn sharing on, so no
//! Mac offers to view it, and any session the hub still hands it is ended with the reason.
//! The plan is in docs/device-hub/windows-host.md.

use crate::screen_host::consent::LocalConsent;
use crate::Res;
use cmux_hub_host::hub::{now_ms, Hub, HubError};
use cmux_hub_host::identity::{self, Account, Device};
use cmux_hub_host::net::Message;
use cmux_hub_host::printable;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use std::time::{Duration, Instant};

/// The production device hub (the Mac app's default).
const DEFAULT_HUB: &str = "https://cmux-device-hub.debussy.workers.dev";
const PING_EVERY: Duration = Duration::from_secs(30);

const USAGE: &str =
    "usage: cmux-rd windows-host enable --stack-token-file PATH|- [--hub URL] [--name NAME]
       cmux-rd windows-host run | status | share off";

/// Why this host serves no session yet; the end reason's text in its log and the next step.
pub const NOT_SERVED: &str = "viewing a Windows PC is not available yet: cmux-rd serve has no Windows port (docs/device-hub/windows-host.md)";

/// The exit code when the host cannot go on until the person acts (removed from the account,
/// key mismatch, anchor ended): the scheduled task should not restart it. sysexits EX_CONFIG.
pub const EXIT_NEEDS_SETUP: i32 = 78;

/// A hub refusal restarting cannot fix, with the command that does.
#[derive(Debug)]
struct Fatal(String);

impl std::fmt::Display for Fatal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Fatal {}

impl Fatal {
    fn from_hub(e: &(dyn std::error::Error + Send + Sync + 'static)) -> Option<Self> {
        let h = e.downcast_ref::<HubError>()?;
        let what = match h.code.as_str() {
            "device_removed" => "This PC is no longer on the account",
            "device_key_mismatch" => "The hub no longer knows this PC's key",
            "not_anchored" => "This PC's 30-day sign-in ended",
            _ => return None,
        };
        Some(Self(format!(
            "{what} ({}). The host stopped. Run: cmux-rd windows-host enable --stack-token-file PATH|-",
            printable(&h.message)
        )))
    }
}

/// Flags that take no value.
const FLAGS: &[&str] = &[];

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

    fn only(&self, allowed: &[&str]) -> Res<()> {
        match self.options.iter().find(|(k, _)| !allowed.contains(&k.as_str())) {
            Some((k, _)) => Err(format!("--{k} is not an option of this command").into()),
            None => Ok(()),
        }
    }
}

/// Runs `cmux-rd windows-host ARGS`; the exit code.
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
        ["enable"] => {
            parsed.only(&["stack-token-file", "hub", "name"]).and_then(|()| enable(&parsed))
        }
        ["run"] => parsed.only(&[]).and_then(|()| run()),
        ["status"] => parsed.only(&[]).and_then(|()| status()),
        ["share", "off"] => parsed.only(&[]).and_then(|()| share_off()),
        ["share", "on"] => Err(NOT_SERVED.into()),
        _ => {
            eprintln!("{USAGE}");
            return 2;
        }
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux-rd windows-host: {e}");
            if e.is::<Fatal>() {
                EXIT_NEEDS_SETUP
            } else {
                1
            }
        }
    }
}

/// The access token from `--stack-token-file` (a file in this user's profile, or `-` for stdin).
fn stack_token(args: &Args) -> Res<String> {
    let path = args
        .get("stack-token-file")
        .ok_or("needs --stack-token-file PATH (or - for stdin): a cmux sign-in access token")?;
    let text = if path == "-" {
        let mut text = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin().lock(), &mut text)?;
        text
    } else {
        let bytes = identity::read_private(Path::new(path))?
            .ok_or_else(|| format!("{path} does not exist"))?;
        String::from_utf8(bytes).map_err(|_| format!("{path} is not text"))?
    };
    let token = text.trim().to_owned();
    if token.is_empty() || token.contains(char::is_whitespace) {
        return Err("the access token file must hold one token".into());
    }
    Ok(token)
}

fn load() -> Res<(Hub, Account)> {
    let dir = identity::config_dir()?;
    let device =
        Device::load(&dir)?.ok_or("not enabled: run `cmux-rd windows-host enable` first")?;
    let account =
        Account::load(&dir)?.ok_or("not enabled: run `cmux-rd windows-host enable` first")?;
    let hub = Hub::new(&account.hub, device, Some(account.user_id.clone()))?;
    Ok((hub, account))
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
    let mut device = match Device::load(&dir)? {
        Some(device) => device,
        None => Device::generate(
            args.get("name").map_or_else(identity::host_name, str::to_owned).as_str(),
        )?,
    };
    if let Some(name) = args.get("name") {
        device.name = name.to_owned();
    }
    let register = |device: &Device| -> Res<(Hub, String)> {
        device.save(&dir)?;
        let hub = Hub::new(&hub_url, device.clone(), None)?;
        let user_id = hub.sign_in_with_stack(&token)?;
        hub.register(crate::screen_host::PLATFORM)?;
        Ok((hub, user_id))
    };
    // The hub never registers a removed id again: a refused identity gets a fresh one, as the
    // Mac app and `linux-host enable` do.
    let (hub, user_id) = match register(&device) {
        Err(e)
            if e.downcast_ref::<HubError>().is_some_and(|h| {
                matches!(h.code.as_str(), "device_removed" | "device_key_mismatch")
            }) =>
        {
            eprintln!("cmux-rd windows-host: the hub refused this PC's old id ({e}); registering it as a new device");
            register(&Device::generate(&device.name)?)?
        }
        other => other?,
    };
    let anchored_until = hub.anchor()?;
    Account { hub: hub_url, user_id, anchored_until }.save(&dir)?;
    // View only, as `linux-host enable` without --allow-control; nothing is served yet anyway.
    LocalConsent { view: true, full: false }.save(&dir)?;
    let capture = capture_line(&check_capture());
    println!(
        "This PC is on the account as \"{}\" ({}), a Windows device. {capture}. Its screen is not offered for viewing yet: {NOT_SERVED}. Keep it online: cmux-rd windows-host run (at logon: schtasks /Create /SC ONLOGON /TN cmux-screen-host /TR \"<path>\\cmux-rd.exe windows-host run\")",
        printable(&hub.device.name),
        hub.device.id,
    );
    Ok(())
}

fn share_off() -> Res<()> {
    let (hub, _) = load()?;
    hub.set_shared(false)?;
    println!("Sharing is off.");
    Ok(())
}

/// What the host captured of this desktop, recorded by `run` for `status`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct CaptureCheck {
    /// `gdi` (BitBlt from the screen DC).
    pub backend: String,
    pub width: u32,
    pub height: u32,
    /// Distinct pixel values among a sample of the frame: 1 is a uniform (often black) frame,
    /// which a secure desktop (UAC prompt, lock screen) or a disconnected session gives.
    pub distinct: usize,
    /// When it was taken (Unix ms).
    pub at_ms: u64,
    /// The capture's error, when it failed.
    #[serde(default)]
    pub error: Option<String>,
}

/// Captures one frame of this desktop.
pub fn check_capture() -> CaptureCheck {
    let mut check = CaptureCheck {
        backend: "gdi".into(),
        width: 0,
        height: 0,
        distinct: 0,
        at_ms: now_ms(),
        error: None,
    };
    let frame = crate::windows::GdiCapture::new(None).and_then(|mut capture| {
        let (w, h) = capture.size();
        let pixels = capture.capture()?.to_vec();
        Ok((w, h, pixels))
    });
    match frame {
        Ok((w, h, pixels)) => {
            check.width = w;
            check.height = h;
            check.distinct = distinct_pixels(&pixels);
        }
        Err(e) => check.error = Some(e.to_string()),
    }
    check
}

/// Distinct BGRX values among up to 4096 pixels sampled evenly across `bgrx`.
pub fn distinct_pixels(bgrx: &[u8]) -> usize {
    let count = bgrx.len() / 4;
    if count == 0 {
        return 0;
    }
    let step = (count / 4096).max(1);
    let mut seen = std::collections::BTreeSet::new();
    for i in (0..count).step_by(step) {
        let p = &bgrx[i * 4..i * 4 + 3];
        seen.insert([p[0], p[1], p[2]]);
    }
    seen.len()
}

/// One sentence on a capture check.
pub fn capture_line(check: &CaptureCheck) -> String {
    match &check.error {
        Some(e) => format!("Capture failed: {}", printable(e)),
        None if check.distinct <= 1 => format!(
            "Captured {}x{} ({}), but the frame is one color: a locked, secure or disconnected desktop",
            check.width, check.height, check.backend
        ),
        None => format!(
            "Captured this desktop at {}x{} ({}, {} distinct colors sampled)",
            check.width, check.height, check.backend, check.distinct
        ),
    }
}

fn status() -> Res<()> {
    let dir = identity::config_dir()?;
    let device = Device::load(&dir)?;
    match (device, Account::load(&dir)?) {
        (None, _) => println!("Not enabled."),
        (Some(device), Some(a)) => println!(
            "{} ({}) on {} as windows, anchored until {} (Unix ms)",
            printable(&device.name),
            device.id,
            a.hub,
            a.anchored_until
        ),
        (Some(device), None) => {
            println!("{} ({}), not signed in", printable(&device.name), device.id)
        }
    }
    let recorded = identity::runtime_dir()
        .ok()
        .and_then(|run| identity::read_private(&run.join("capture.json")).ok().flatten())
        .and_then(|bytes| serde_json::from_slice::<CaptureCheck>(&bytes).ok());
    let check = recorded.unwrap_or_else(check_capture);
    println!("{}", capture_line(&check));
    println!("Viewing: {NOT_SERVED}");
    Ok(())
}

fn run() -> Res<()> {
    let (hub, account) = load()?;
    let runtime = identity::runtime_dir()?;
    identity::private_dir(&runtime)?;
    if account.anchored_until != 0 && account.anchored_until <= now_ms() {
        return Err(Fatal("This PC's 30-day sign-in ended. Run: cmux-rd windows-host enable --stack-token-file PATH|-".into()).into());
    }
    let check = check_capture();
    eprintln!("windows-host: {}", capture_line(&check));
    identity::write_private(&runtime.join("capture.json"), &serde_json::to_vec_pretty(&check)?)?;
    eprintln!("windows-host: online as \"{}\" ({})", printable(&hub.device.name), hub.device.id);
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = Instant::now();
        if let Err(e) = hold_socket(&hub) {
            if let Some(fatal) = Fatal::from_hub(&*e) {
                return Err(fatal.into());
            }
            eprintln!("windows-host: hub link: {e}");
        }
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_secs(1);
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

/// Holds one User DO socket until it closes: online for the account's devices.
fn hold_socket(hub: &Hub) -> Res<()> {
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
                return Err(match code {
                    4001 | 4003 => HubError {
                        status: 403,
                        code: "device_removed".into(),
                        message: "this PC was removed from the account or signed out".into(),
                    }
                    .into(),
                    _ => format!("socket closed ({code} {})", printable(&reason)).into(),
                });
            }
            Some(Message::Text(text)) => {
                let Ok(push) = serde_json::from_str::<Value>(&text) else { continue };
                if let Some((id, close)) = unserved(&push) {
                    eprintln!("windows-host: session {}: {NOT_SERVED}; closed", printable(&id));
                    let sent = match close {
                        Close::Deny => hub.decide(&id, "deny", None).map(drop),
                        Close::End => hub.end(&id, "failed"),
                    };
                    if let Err(e) = sent {
                        eprintln!("windows-host: not sent: {e}");
                    }
                }
            }
        }
    }
}

/// How a session this host cannot serve is closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Close {
    /// A viewer's pending request: denied (`/decision` deny), so it does not wait 5 minutes.
    Deny,
    /// An approved session's host ticket: ended (`/end` failed).
    End,
}

/// A session push this host must close because it serves none: the session id and how.
/// Sharing stays off, so the hub sends none; one that still comes (sharing turned on from
/// elsewhere) is closed at once instead of leaving the viewer waiting.
pub fn unserved(push: &Value) -> Option<(String, Close)> {
    let (id, close) = match push["type"].as_str()? {
        "session.request" => (push["session"]["id"].as_str()?, Close::Deny),
        "session.ticket" if push["role"].as_str() == Some("host") => {
            (push["sessionId"].as_str()?, Close::End)
        }
        _ => return None,
    };
    (!id.is_empty()).then(|| (id.to_owned(), close))
}

#[cfg(test)]
#[path = "windows_host_tests.rs"]
mod tests;

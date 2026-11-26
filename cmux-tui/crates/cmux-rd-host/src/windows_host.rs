//! `cmux-rd windows-host`: this Windows PC as a device hub screen host, viewed from cmux on a
//! Mac exactly like a shared Mac or a `cmux-rd linux-host` desktop, with the same hub client,
//! consent and session serving (the cmux-hub-host crate, src/screen_host/). It registers the PC as a `windows` device
//! with its own device key, anchors it (it renews its own host session for 30 days with that
//! key, no token), turns sharing on, and while `run` runs holds the hub socket and serves each
//! approved session through a `cmux-rd serve` child (src/windows_serve.rs: GDI capture,
//! OpenH264, SendInput over the secure link).
//!
//!   enable --stack-token-file PATH|- [--hub URL] [--name NAME] [--allow-control]
//!       Signs in once, registers, anchors, turns sharing on and downloads Cisco's OpenH264
//!       (the encoder; never bundled). Control (input) is off unless `--allow-control`.
//!   share on --stack-token-file PATH|- | share off
//!   run [--openh264-lib PATH]      the host: run it in the desktop user's session (a logon
//!                                  scheduled task), never as a service in session 0
//!   requests                       viewers asking for access, waiting for the person
//!   approve SESSION [--always] [--scope view|full]
//!   deny SESSION
//!   status
//!
//! Consent: a viewer the person already allowed (the hub's `view`/`full` permission, which the
//! account owner's own Macs get) is served; any other request waits for `approve`. A `view`
//! session applies no input; `full` needs `--allow-control` at `enable`. What Windows itself
//! keeps from any user-session host (UAC prompts, the lock screen, elevated windows) is in
//! docs/device-hub/windows-host.md.

use crate::screen_host::consent::LocalConsent;
use crate::screen_host::requests;
use crate::screen_host::serving::Host;
use crate::Res;
use cmux_hub_host::hub::{now_ms, Hub, HubError};
use cmux_hub_host::identity::{self, Account, Device};
use cmux_hub_host::printable;
use cmux_hub_host::session::ServeCommand;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The production device hub (the Mac app's default).
const DEFAULT_HUB: &str = "https://cmux-device-hub.debussy.workers.dev";

const USAGE: &str =
    "usage: cmux-rd windows-host enable --stack-token-file PATH|- [--hub URL] [--name NAME] [--allow-control]
       cmux-rd windows-host share on --stack-token-file PATH|- | share off
       cmux-rd windows-host run [--openh264-lib PATH]
       cmux-rd windows-host requests | approve SESSION [--always] [--scope view|full] | deny SESSION | status";

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
    const ENABLE: &'static str = "cmux-rd windows-host enable --stack-token-file PATH|-";
    const SHARE_ON: &'static str = "cmux-rd windows-host share on --stack-token-file PATH|-";

    fn needs(what: &str, command: &str) -> Self {
        Self(format!("{what}. The host stopped. To share this PC again, run: {command}"))
    }

    fn from_hub(e: &(dyn std::error::Error + Send + Sync + 'static)) -> Option<Self> {
        let h = e.downcast_ref::<HubError>()?;
        let detail = printable(&h.message);
        let (what, command) = match h.code.as_str() {
            "device_removed" => ("This PC is no longer on the account", Self::ENABLE),
            "device_key_mismatch" => ("The hub no longer knows this PC's key", Self::ENABLE),
            "not_anchored" => ("This PC's 30-day sign-in ended", Self::SHARE_ON),
            _ => return None,
        };
        Some(Self::needs(&format!("{what} ({detail})"), command))
    }
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
        ["enable"] => parsed
            .only(&["stack-token-file", "hub", "name", "allow-control"])
            .and_then(|()| enable(&parsed)),
        ["share", "on"] => parsed.only(&["stack-token-file"]).and_then(|()| share_on(&parsed)),
        ["share", "off"] => parsed.only(&[]).and_then(|()| share_off()),
        ["run"] => parsed.only(&["openh264-lib"]).and_then(|()| run(&parsed)),
        ["requests"] => parsed.only(&[]).and_then(|()| requests::list(&identity::runtime_dir()?)),
        ["approve", id] => parsed.only(&["always", "scope"]).and_then(|()| approve(id, &parsed)),
        ["deny", id] => parsed.only(&[]).and_then(|()| deny(id)),
        ["status"] => parsed.only(&[]).and_then(|()| status()),
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

/// The enabled host: its config directory, hub and account.
fn load() -> Res<(PathBuf, Hub, Account)> {
    let dir = identity::config_dir()?;
    let device =
        Device::load(&dir)?.ok_or("not enabled: run `cmux-rd windows-host enable` first")?;
    let account =
        Account::load(&dir)?.ok_or("not enabled: run `cmux-rd windows-host enable` first")?;
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
    let consent = LocalConsent { view: true, full: args.flag("allow-control") };
    consent.save(&dir)?;
    // The encoder before sharing turns on: a viewer must not reach a host that cannot encode.
    let encoder = openh264_line();
    hub.set_shared(true)?;
    Account { hub: hub_url, user_id, anchored_until }.save(&dir)?;
    let capture = capture_line(&check_capture());
    println!(
        "This PC is shared as \"{}\" ({}), {}, a Windows device. {capture}. {encoder}. Start the host in this session: cmux-rd windows-host run (at logon: schtasks /Create /SC ONLOGON /TN cmux-screen-host /TR \"<path>\\cmux-rd.exe windows-host run\")",
        printable(&hub.device.name),
        hub.device.id,
        shares_line(&Ok(consent)),
    );
    Ok(())
}

/// Cisco's OpenH264 in the per-user data directory (downloaded from Cisco the first time), in
/// one sentence.
fn openh264_line() -> String {
    #[cfg(feature = "openh264")]
    return match crate::encoder::ensure_openh264_in(cmux_encode::cisco::default_dir()) {
        Ok(path) => format!("OpenH264 is at {}", path.display()),
        Err(e) => format!(
            "OpenH264 is not installed ({}): run cmux-rd openh264-install before a viewer connects",
            printable(&e.to_string())
        ),
    };
    #[cfg(not(feature = "openh264"))]
    "This build has no OpenH264 download; pass --openh264-lib PATH to run".to_owned()
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

fn approve(id: &str, args: &Args) -> Res<()> {
    let (dir, hub, _) = load()?;
    // SendInput applies every control session's input: nothing is lowered for the capture.
    requests::approve(
        &dir,
        &identity::runtime_dir()?,
        &hub,
        id,
        args.get("scope"),
        args.flag("always"),
        None,
    )
}

fn deny(id: &str) -> Res<()> {
    let (_, hub, _) = load()?;
    requests::deny(&identity::runtime_dir()?, &hub, id)
}

/// What this PC shares under `consent`.
fn shares_line(consent: &Res<LocalConsent>) -> &'static str {
    match consent {
        Ok(c) if c.full => "view and control",
        Ok(_) => "view only",
        Err(_) => "nothing shared (consent.json missing or unreadable)",
    }
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
    let shares = shares_line(&LocalConsent::load(&dir));
    match (Device::load(&dir)?, Account::load(&dir)?) {
        (None, _) => println!("Not enabled."),
        (Some(device), Some(a)) => println!(
            "{} ({}) on {} as windows, anchored until {} (Unix ms), {shares}",
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
    Ok(())
}

fn run(args: &Args) -> Res<()> {
    let (dir, hub, account) = load()?;
    let runtime = identity::runtime_dir()?;
    identity::private_dir(&runtime)?;
    // Read at start so a bad file fails now; read again for every ticket and every second.
    let consent = LocalConsent::load(&dir)?;
    if account.anchored_until != 0 && account.anchored_until <= now_ms() {
        return Err(Fatal::needs("This PC's 30-day sign-in ended", Fatal::SHARE_ON).into());
    }
    let check = check_capture();
    eprintln!("windows-host: {}", capture_line(&check));
    identity::write_private(&runtime.join("capture.json"), &serde_json::to_vec_pretty(&check)?)?;
    // Each approved session runs this executable's `serve` (src/windows_serve.rs).
    let mut serve_args = vec!["serve".to_owned()];
    if let Some(lib) = args.get("openh264-lib") {
        serve_args.extend(["--openh264-lib".to_owned(), lib.to_owned()]);
    }
    let command = ServeCommand {
        program: std::env::current_exe()?,
        args: serve_args,
        disclaim: false,
        log_prefix: crate::screen_host::TAG.to_owned(),
        status_prefix: crate::screen_host::COMMAND.to_owned(),
    };
    eprintln!(
        "windows-host: serving \"{}\" ({}), {}",
        printable(&hub.device.name),
        hub.device.id,
        shares_line(&Ok(consent))
    );
    // SendInput applies a control session's input: `full` tickets are served with control.
    let host = Host::new(hub, dir, runtime, command, true);
    host.run(|e| Fatal::from_hub(e).map(Into::into))
}

#[cfg(test)]
#[path = "windows_host_tests.rs"]
mod tests;

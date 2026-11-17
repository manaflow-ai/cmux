//! `cmux-rd linux-host`: this Linux desktop as a device hub screen host, viewed from cmux on
//! a Mac exactly like a shared Mac (docs/device-hub/PROTOCOL.md). The Mac app holds a Mac's
//! device key and hub link and drives `cmux-rd serve`; on Linux this command does that job.
//!
//!   enable [--stack-token-file PATH|-] [--hub URL] [--name NAME] [--view-only] [--non-interactive]
//!       Signs in once with a cmux (Stack Auth) access token (without a token file, through
//!       a browser sign-in link: stack_login.rs), registers this desktop as a
//!       `linux` device, anchors it (it renews its own host session for 30 days with its
//!       device key, no token), downloads Cisco's OpenH264 (the encoder; never bundled) and
//!       turns sharing on. The person's own devices view and control it with no prompt here
//!       (`--view-only` keeps control off); on Wayland it asks the portal once, now (`grant`),
//!       so no viewer's session asks again.
//!       `--non-interactive` (the machine join, often over ssh): takes no account token and opens
//!       no browser, finds the desktop through logind, waits a minute at most on the portal
//!       dialog, sets up a virtual X display (started on demand) when there is no graphical
//!       session, and installs the host unit on a desktop still enabled or a machine joined to
//!       cmux, which signs itself in with its machine credential (machine.rs); else prints one
//!       `not_installed:` line (setup.rs).
//!   grant [--control]
//!       Wayland: asks the xdg-desktop-portal once (its dialog, on this screen) for the screen
//!       and, with `--control`, keyboard and pointer, and saves the restore token in
//!       `~/.config/cmux/screen-host/`, so no share asks again (portal.rs). Enable runs it.
//!   share on [--stack-token-file PATH|-] | share off
//!   run [--display :0] [--xauthority PATH] [--capture x11|portal]
//!       The host: holds the hub socket and serves approved sessions. Run it in the desktop
//!       user's graphical session (the user systemd unit `systemd/cmux-screen-host.service`).
//!   display                        the X display an app launched here opens on (`:N`): the
//!                                  virtual display, started now if down, else the desktop's
//!   requests                       viewers asking for access, waiting for the person
//!   approve SESSION [--always] [--scope view|full]
//!   deny SESSION
//!   status [--json]                `--json`: the cmux.screen-share.status/1 document cmux
//!                                  reads from every share host (status_json.rs)
//!
//! Consent: the hub serves the account's own devices at once (a viewer with no saved permission
//! reads `full`) and a viewer the person allowed; a request under a saved Ask waits for `approve` and is
//! never answered by the host itself
//! (consent.rs). A `view` session applies no input, and so does every session of a host that
//! captures through the Wayland portal without a RemoteDesktop grant: there it is served view
//! only.

mod consent;
mod machine;
mod setup;
pub(crate) mod stack_login;
mod status_json;

use crate::capture_backend::CaptureBackend;
use crate::Res;
use cmux_hub_host::hub::{now_ms, utc_stamp, Hub, HubError, Renewal};
use cmux_hub_host::identity::{self, Account, Device};
use cmux_hub_host::net::{Message, WebSocket};
use cmux_hub_host::printable;
use cmux_hub_host::session::{self, ServeCommand, Ticket};
use consent::{LocalConsent, Pending};
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The production device hub (the Mac app's default).
pub(crate) const DEFAULT_HUB: &str = "https://cmux-device-hub.debussy.workers.dev";
const PING_EVERY: Duration = Duration::from_secs(30);

const USAGE: &str = "usage: cmux-rd linux-host enable [--stack-token-file PATH|-] [--hub URL] [--name NAME] [--view-only] [--non-interactive]
       cmux-rd linux-host grant [--control]
       cmux-rd linux-host share on [--stack-token-file PATH|-] | share off
       cmux-rd linux-host run [--display :0] [--xauthority PATH] [--capture x11|portal]
       cmux-rd linux-host display | requests | approve SESSION [--always] [--scope view|full] | deny SESSION | status [--json]";

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
    const ENABLE: &'static str = "cmux-rd linux-host enable";
    const SHARE_ON: &'static str = "cmux-rd linux-host share on";
    const JOIN: &'static str = "acpmux host join (a new join line from cmux machine add)";

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
const FLAGS: &[&str] =
    &["always", "allow-control", "control", "view-only", "json", "non-interactive"];

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
            .only(&[
                "stack-token-file",
                "hub",
                "name",
                "allow-control",
                "view-only",
                "non-interactive",
            ])
            .map_err(Into::into)
            .and_then(|()| enable(&parsed)),
        ["grant"] => parsed
            .only(&["control"])
            .map_err(Into::into)
            .and_then(|()| grant(parsed.flag("control"))),
        ["share", "on"] => {
            parsed.only(&["stack-token-file"]).map_err(Into::into).and_then(|()| share_on(&parsed))
        }
        ["share", "off"] => parsed.only(&[]).map_err(Into::into).and_then(|()| share_off()),
        ["run"] => parsed
            .only(&["display", "xauthority", "capture"])
            .map_err(Into::into)
            .and_then(|()| run(&parsed)),
        ["display"] => parsed.only(&[]).map_err(Into::into).and_then(|()| display()),
        ["requests"] => parsed.only(&[]).map_err(Into::into).and_then(|()| requests()),
        ["approve", id] => parsed
            .only(&["always", "scope"])
            .map_err(Into::into)
            .and_then(|()| approve(id, &parsed)),
        ["deny", id] => parsed.only(&[]).map_err(Into::into).and_then(|()| deny(id)),
        ["status"] => parsed.only(&["json"]).map_err(Into::into).and_then(|()| {
            if parsed.flag("json") {
                print_status_json();
                Ok(())
            } else {
                status()
            }
        }),
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

/// The access token: `--stack-token-file`, or a browser sign-in (stack_login.rs).
fn stack_token(args: &Args) -> Res<String> {
    stack_login::access_token(args.get("stack-token-file"))
}

/// The enabled host: its device, account and hub.
/// A desktop never enabled and never joined signs in first; a joined machine signs itself in
/// with its machine credential, so the host needs no step on it (machine.rs).
fn load() -> Res<(std::path::PathBuf, Hub, Account)> {
    const NOT_ENABLED: &str = "not enabled: run `cmux-rd linux-host enable` first";
    let dir = identity::config_dir()?;
    let Some(account) = Account::load(&dir)? else {
        let (home, credential) = machine::current()?.ok_or(NOT_ENABLED)?;
        identity::private_dir(&dir)?;
        let (hub, account) = sign_in_machine(&dir, DEFAULT_HUB, &home, credential)?;
        return Ok((dir, hub, account));
    };
    let device = Device::load(&dir)?.ok_or(NOT_ENABLED)?;
    let hub = match machine::Joined::load(&dir)? {
        Some(joined) => {
            let credential = machine::load(&joined.acpmux_home)?.ok_or_else(|| {
                Fatal::needs("This machine's join was revoked or removed", Fatal::JOIN)
            })?;
            Hub::with_renewal(&account.hub, device, None, machine_renewal(credential))?
        }
        None => Hub::new(&account.hub, device, Some(account.user_id.clone()))?,
    };
    Ok((dir, hub, account))
}

/// Signs a joined machine in with its credential (`POST /v1/auth/machine`), registers this
/// desktop (a new identity when the hub refuses the old one) and turns sharing on: joining is
/// the consent (hq docs/design/remote-screen-share-zero-touch.md, L3). Sharing is turned on
/// only here, at the first sign-in, so a person's later "off" from any device stays off.
fn sign_in_machine(
    dir: &std::path::Path,
    hub_url: &str,
    acpmux_home: &std::path::Path,
    credential: machine::MachineCredential,
) -> Res<(Hub, Account)> {
    let device = match Device::load(dir)? {
        Some(device) => device,
        None => {
            let name = Some(credential.name.trim()).filter(|n| !n.is_empty());
            Device::generate(name.map_or_else(identity::host_name, str::to_owned).as_str())?
        }
    };
    let (_, hub) = with_fresh_identity(device, |device| {
        device.save(dir)?;
        let hub =
            Hub::with_renewal(hub_url, device.clone(), None, machine_renewal(credential.clone()))?;
        hub.register("linux")?;
        Ok(hub)
    })?;
    hub.set_shared(true)?;
    let user_id = hub.user_id().ok_or("no userId in the hub's answer")?;
    let account = Account { hub: hub_url.to_owned(), user_id, anchored_until: 0 };
    account.save(dir)?;
    machine::Joined { acpmux_home: acpmux_home.to_owned() }.save(dir)?;
    Ok((hub, account))
}

/// How a joined machine's hub client renews: with its machine credential, never an anchor.
fn machine_renewal(credential: machine::MachineCredential) -> Renewal {
    Renewal::Machine { credential: credential.credential }
}

/// The line `enable --non-interactive` prints on a machine it could not sign in: neither an
/// earlier `enable` nor a join left a sign-in here, and no person's token ever lands on a
/// joined machine (hq docs/design/remote-spin-up.md section 5), so nothing else is asked for.
const NOT_INSTALLED: &str = "not_installed: screen sharing is set up on this machine but not signed in: it is not joined to cmux (no machine credential in ACPMUX_HOME)";

/// How long `enable --non-interactive` leaves the portal's dialog up for someone at the screen;
/// past it the join goes on and the first share asks once.
const JOIN_GRANT_WAIT: Duration = Duration::from_secs(60);

fn enable(args: &Args) -> Res<()> {
    if args.flag("non-interactive") {
        return enable_for_join(args);
    }
    let dir = identity::config_dir()?;
    identity::private_dir(&dir)?;
    let (device, encoder) = sign_in_and_register(args, &dir)?;
    let consent = enable_consent(args);
    consent.save(&dir)?;
    grant_capture_now(consent.full, &setup::detect_desktop(), None);
    println!(
        "This desktop is shared as \"{}\" ({}), {}. {encoder}. Start the host: systemctl --user enable --now cmux-screen-host.service",
        device.name,
        device.id,
        shares_line(&Ok(consent), host_applies_input())
    );
    Ok(())
}

/// `enable --non-interactive`, the one command the machine join runs (often over ssh, with no
/// display): sets up capture for the desktop this machine has, the portal grant or a virtual
/// display, and installs the host when this machine is still signed in. It takes no account
/// token and opens no browser, and never fails the join: what it could not do is one line.
fn enable_for_join(args: &Args) -> Res<()> {
    if args.get("stack-token-file").is_some() {
        return Err(
            "--non-interactive takes no account token: no person's credential is kept on a joined machine"
                .into(),
        );
    }
    if let Err(e) = set_up_for_join(args) {
        println!("not_installed: {e}");
    }
    Ok(())
}

fn set_up_for_join(args: &Args) -> Res<()> {
    let dir = identity::config_dir()?;
    identity::private_dir(&dir)?;
    let consent = enable_consent(args);
    consent.save(&dir)?;
    let desktop = setup::detect_desktop();
    grant_capture_now(consent.full, &desktop, Some(JOIN_GRANT_WAIT));
    let virtual_display = desktop == setup::Desktop::None;
    if virtual_display {
        let display = setup::set_up_virtual_display()?;
        println!("{}", setup::virtual_display_line(display));
    }
    // Signed in by an earlier `enable` and still anchored: the host renews by its device key.
    // Else a joined machine signs itself in with its machine credential.
    let device = match (Account::load(&dir)?, Device::load(&dir)?, machine::current()?) {
        (Some(account), Some(device), _) if account.anchored_until > now_ms() => device,
        (Some(_), Some(device), Some((home, _)))
            if machine::Joined::load(&dir)?.is_some_and(|j| j.acpmux_home == home) =>
        {
            device
        }
        (_, _, Some((home, credential))) => {
            let hub_url = args.get("hub").unwrap_or(DEFAULT_HUB);
            sign_in_machine(&dir, hub_url, &home, credential)?.0.device
        }
        _ => {
            println!("{NOT_INSTALLED}");
            return Ok(());
        }
    };
    // The host this installs serves sessions at once, so its encoder is there first.
    let encoder = openh264_line();
    setup::install_host(virtual_display)?;
    println!(
        "This desktop is shared as \"{}\" ({}), {}; the host runs as {}. {encoder}.",
        device.name,
        device.id,
        shares_line(&Ok(consent), host_applies_input()),
        setup::HOST_UNIT
    );
    Ok(())
}

/// Signs in, registers this desktop (a new identity when the hub refuses the old one), anchors
/// it, installs the encoder and turns sharing on; the device and the encoder's line.
fn sign_in_and_register(args: &Args, dir: &std::path::Path) -> Res<(Device, String)> {
    let token = stack_token(args)?;
    let hub_url = match (args.get("hub"), Account::load(dir)?) {
        (Some(url), _) => url.to_owned(),
        (None, Some(account)) => account.hub,
        (None, None) => DEFAULT_HUB.to_owned(),
    };
    let device = match Device::load(dir)? {
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
    let (_, (hub, user_id)) = with_fresh_identity(device, |device| {
        device.save(dir)?;
        let hub = Hub::new(&hub_url, device.clone(), None)?;
        let user_id = hub.sign_in_with_stack(&token)?;
        hub.register("linux")?;
        Ok((hub, user_id))
    })?;
    let anchored_until = hub.anchor()?;
    // The encoder before sharing turns on: a viewer must not reach a host that cannot encode.
    let encoder = openh264_line();
    hub.set_shared(true)?;
    Account { hub: hub_url, user_id, anchored_until }.save(dir)?;
    machine::Joined::clear(dir)?;
    Ok((hub.device, encoder))
}

/// Cisco's OpenH264 in the per-user data directory (downloaded from Cisco the first time), in
/// one sentence. Without it every session ends with "openh264 is not installed".
fn openh264_line() -> String {
    #[cfg(feature = "openh264")]
    return match crate::encoder::ensure_openh264() {
        Ok(path) => format!("OpenH264 is at {}", path.display()),
        Err(e) => format!(
            "OpenH264 is not installed ({}): run cmux-rd openh264-install before a viewer connects",
            printable(&e.to_string())
        ),
    };
    #[cfg(not(feature = "openh264"))]
    "This build has no OpenH264 download; pass --openh264-lib PATH to run".to_owned()
}

/// `grant [--control]`: the Wayland portal's grant, made now so no share asks.
fn grant(control: bool) -> Res<()> {
    if CaptureBackend::from_env(None)? != CaptureBackend::Portal {
        println!("This is not a Wayland session: sharing it needs no portal grant.");
        return Ok(());
    }
    println!("{}", portal_grant(control, None)?);
    if identity::runtime_dir().is_ok_and(|dir| dir.join("capture").exists()) {
        println!("Restart the host to use it: systemctl --user restart cmux-screen-host.service");
    }
    Ok(())
}

/// Asks the portal once for the screen (and, with `control`, keyboard and pointer) and saves
/// its restore token (portal.rs); what it granted. Prints the join's notes on what this portal
/// cannot keep (setup.rs). `within` bounds the wait on the dialog: past it nothing is saved and
/// the first share asks. A build that cannot capture through the portal asks nothing: a grant
/// would show a dialog for shares it cannot serve.
#[cfg(feature = "portal-dbus")]
fn portal_grant(control: bool, within: Option<Duration>) -> Res<String> {
    use crate::portal::{PortalState, SessionKind};
    CaptureBackend::Portal.available()?;
    let (done, result) = std::sync::mpsc::channel();
    // On its own thread, so a dialog nobody answers cannot hold the join past `within`. Not
    // joined: past `within` it is left to the process, which ends with `enable`.
    std::thread::Builder::new().name("linux-host-grant".into()).spawn(move || {
        let granted = crate::portal::grant(
            control,
            &mut |screen_cast, remote_desktop| {
                let versions = setup::PortalVersions { screen_cast, remote_desktop };
                for note in setup::portal_notes(versions, control) {
                    println!("{note}");
                }
            },
            &mut |state| {
                if state == PortalState::WaitingForConsent {
                    eprintln!("linux-host: allow screen sharing in the dialog on this screen; cmux asks only this once");
                }
            },
        );
        let _ = done.send(granted);
    })?;
    let granted = match within {
        None => result.recv().map_err(|_| "the portal grant stopped")?,
        Some(wait) => result.recv_timeout(wait).map_err(|_| {
            format!("nobody allowed the dialog on this screen within {} seconds", wait.as_secs())
        })?,
    }?;
    let what = match granted.kind {
        SessionKind::RemoteDesktop => "view and control this desktop",
        SessionKind::ScreenCast if control => {
            "view this desktop (this portal cannot keep a grant for keyboard and pointer, so it is shared view only)"
        }
        SessionKind::ScreenCast => "view this desktop",
    };
    Ok(format!(
        "The screen sharing portal lets cmux {what}; shares start with no prompt on this screen."
    ))
}

#[cfg(not(feature = "portal-dbus"))]
fn portal_grant(_control: bool, _within: Option<Duration>) -> Res<String> {
    CaptureBackend::Portal.available()?;
    Err("this cmux-rd is built without the Wayland portal".into())
}

/// The consent `enable` writes: view and control, since the person joined this desktop to their own
/// account and their devices view and control it with no prompt here; `--view-only` keeps control off.
/// `--allow-control`, the flag control used to need, is still accepted.
fn enable_consent(args: &Args) -> LocalConsent {
    LocalConsent { view: true, full: !args.flag("view-only") }
}

/// On a Wayland desktop, asks the portal for its grant now, while the person who ran `enable` is
/// at the screen (with `control`, the RemoteDesktop grant: keyboard and pointer too), and keeps
/// the restore token it returns: later sessions start from that token with no dialog, so no
/// viewer's session waits on an Allow here. An X11 desktop or a virtual display needs no grant.
/// A refusal, a missing portal or no answer `within` only says so: the host still serves, and
/// its first session asks.
fn grant_capture_now(control: bool, desktop: &setup::Desktop, within: Option<Duration>) {
    if *desktop != setup::Desktop::Wayland {
        return;
    }
    match portal_grant(control, within) {
        Ok(line) => println!("{line}"),
        Err(e) => eprintln!(
            "cmux-rd linux-host: the screen capture grant was not saved ({e}); the first session asks for it on this desktop, or run: cmux-rd linux-host grant{}",
            if control { " --control" } else { "" }
        ),
    }
}

/// Whether the hub refused this device's identity itself: it never registers a removed id
/// again, and a key mismatch means another key holds the id.
fn refuses_identity(e: &(dyn std::error::Error + Send + Sync + 'static)) -> bool {
    e.downcast_ref::<HubError>()
        .is_some_and(|h| matches!(h.code.as_str(), "device_removed" | "device_key_mismatch"))
}

/// Runs `attempt` (sign in and register) with `device`; the device it succeeded with. When
/// the hub refuses that identity (`device_removed`, `device_key_mismatch`), once more with a
/// new device of the same name, as the Mac app does.
pub(crate) fn with_fresh_identity<T>(
    device: Device,
    mut attempt: impl FnMut(&Device) -> Res<T>,
) -> Res<(Device, T)> {
    match attempt(&device) {
        Ok(done) => Ok((device, done)),
        Err(e) if refuses_identity(&*e) => {
            let fresh = Device::generate(&device.name)?;
            eprintln!(
                "cmux-rd linux-host: the hub refused this desktop's old id ({e}); registering it as a new device"
            );
            let done = attempt(&fresh)?;
            Ok((fresh, done))
        }
        Err(e) => Err(e),
    }
}

fn share_on(args: &Args) -> Res<()> {
    let (dir, hub, mut account) = load()?;
    if machine::Joined::load(&dir)?.is_some() {
        // A joined machine's session may turn its own sharing on (PROTOCOL.md, Machine sign-in).
        hub.set_shared(true)?;
        println!("Sharing is on.");
        return Ok(());
    }
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

/// `display`: the X display an app launched on this machine should open on, so a share shows
/// it (`cmux app launch --on`): the virtual display, started now if it is down, else the
/// desktop's X display. Prints `:N`.
fn display() -> Res<()> {
    if let Some(display) = setup::virtual_display() {
        println!("{}", setup::ensure_virtual_display(display)?);
        return Ok(());
    }
    match setup::detect_desktop() {
        setup::Desktop::X11(Some(display)) => println!("{display}"),
        setup::Desktop::X11(None) => println!(":0"),
        setup::Desktop::Wayland => {
            return Err("this desktop is a Wayland session: apps open in it with WAYLAND_DISPLAY, not an X display".into())
        }
        setup::Desktop::None => {
            return Err("no graphical session and no virtual display: run `cmux-rd linux-host enable --non-interactive`".into())
        }
    }
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
    let applies_input = host_applies_input();
    let scope = consent::decision_scope(
        &request,
        args.get("scope"),
        LocalConsent::load(&dir)?,
        applies_input,
    )?;
    let decision = if args.flag("always") { "always" } else { "once" };
    hub.decide(id, decision, Some(&scope))?;
    pending.remove(id, now)?;
    let lowered = request.scope == "full" && scope == "view" && args.get("scope").is_none();
    println!(
        "Approved {} to {} this desktop{}{}.",
        printable(&request.viewer_name),
        if scope == "full" { "control" } else { "view" },
        if decision == "always" { " from now on" } else { " once" },
        if lowered { NO_INPUT_NOTE } else { "" }
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
    let shares = shares_line(&LocalConsent::load(&dir), host_applies_input());
    match Account::load(&dir)? {
        Some(a) => println!(
            "{} ({}) on {}, anchored until {} (Unix ms), {}",
            device.name, device.id, a.hub, a.anchored_until, shares
        ),
        None => println!("{} ({}), not signed in", device.name, device.id),
    }
    Ok(())
}

/// `status --json`: never fails; a missing piece is a state (status_json.rs).
fn print_status_json() {
    let facts = status_json::gather(now_ms());
    println!("{}", status_json::status_json(&facts, env!("CARGO_PKG_VERSION")));
}

/// Why a host whose capture applies no input shares view only.
const NO_INPUT_NOTE: &str = " (view only: this desktop is captured through the Wayland portal, which has no keyboard and pointer grant; `cmux-rd linux-host grant --control` asks for it once)";

/// What `status` says this desktop shares, under `consent` and a capture that does or does
/// not apply input.
fn shares_line(consent: &Res<LocalConsent>, applies_input: bool) -> &'static str {
    // A missing consent file serves nothing; say so instead of failing.
    match consent {
        Ok(c) if c.full && applies_input => "view and control",
        Ok(c) if c.full => {
            "view only (control is allowed, but this desktop is captured through the Wayland portal, which has no keyboard and pointer grant; `cmux-rd linux-host grant --control` asks for it once)"
        }
        Ok(_) => "view only",
        Err(_) => "nothing shared (consent.json missing or unreadable)",
    }
}

/// The capture backend the running host chose (`run` records it in the runtime directory),
/// else this session's own choice.
fn host_capture(runtime: Option<&std::path::Path>) -> CaptureBackend {
    let recorded = runtime
        .and_then(|dir| identity::read_private(&dir.join("capture")).ok().flatten())
        .and_then(|bytes| CaptureBackend::parse(&String::from_utf8_lossy(&bytes)).ok());
    recorded.unwrap_or_else(|| CaptureBackend::from_env(None).unwrap_or_default())
}

/// Whether a viewer's input reaches this desktop with the host's capture.
fn host_applies_input() -> bool {
    host_capture(identity::runtime_dir().ok().as_deref()).applies_input()
}

/// A session this host serves: its id, its scope (`view`/`full`) and its stop flag.
struct Served {
    id: String,
    scope: String,
    stop: Arc<AtomicBool>,
}

/// The session this host serves now (one at a time; a newer ticket replaces it).
type Current = Arc<Mutex<Option<Served>>>;

/// How often the running host reads its consent file again.
const CONSENT_EVERY: Duration = Duration::from_secs(1);

/// Stops the session being served, if any; its id.
fn stop_current(current: &Current) -> Option<String> {
    let served = current.lock().unwrap_or_else(|e| e.into_inner()).take()?;
    served.stop.store(true, Ordering::SeqCst);
    Some(served.id)
}

/// How long a dropped hub link has to come back, with the hub saying the session it served
/// is still on, before that session stops.
const RELINK_WITHIN: Duration = Duration::from_secs(10);

/// What became of the session served when a hub link ended.
#[derive(Debug)]
enum AfterLink<S> {
    /// Nothing was served.
    Idle,
    /// It goes on: a new link is up (`S`) and the hub said the session is still on.
    Kept(String, S),
    /// It stopped: its id and why.
    Stopped(String, String),
}

/// Holds one hub link with `hold`. When it ends with a session served, `relink` (given the
/// session's id) must open the next link and then have the hub say the session is still
/// approved or live, all within `within`, or the session stops. The hub does not replay a
/// revocation, an end or sharing turned off that it pushed while the link was down, but it
/// ends the session in every one of those, so asking after the new link is up misses
/// nothing: what happened before shows in the answer, and what happens after comes over the
/// new link (fail closed). A link the hub ended for good (this desktop removed or signed
/// out) stops the session at once. The result of `hold` and what became of the session.
fn hold_link<S: Send + 'static>(
    current: &Current,
    hold: impl FnOnce() -> Res<()>,
    relink: impl FnOnce(String) -> Res<S> + Send + 'static,
    within: Duration,
) -> (Res<()>, AfterLink<S>) {
    let result = hold();
    let served = current.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|s| s.id.clone());
    let Some(id) = served else { return (result, AfterLink::Idle) };
    let why = match &result {
        Err(e) if Fatal::from_hub(&**e).is_some() => e.to_string(),
        _ => match relink_within(id, relink, within) {
            Ok(kept) => return (result, kept),
            Err(why) => why,
        },
    };
    match stop_current(current) {
        Some(id) => (result, AfterLink::Stopped(id, why)),
        None => (result, AfterLink::Idle),
    }
}

/// Runs `relink(id)` on its own thread; `Kept` when it answers a link within `within`,
/// otherwise why not.
fn relink_within<S: Send + 'static>(
    id: String,
    relink: impl FnOnce(String) -> Res<S> + Send + 'static,
    within: Duration,
) -> Result<AfterLink<S>, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let asked = id.clone();
    std::thread::Builder::new()
        .name("linux-host-relink".into())
        .spawn(move || {
            let _ = tx.send(relink(asked).map_err(|e| e.to_string()));
        })
        .map_err(|e| format!("no relink: {e}"))?;
    match rx.recv_timeout(within) {
        Ok(Ok(link)) => Ok(AfterLink::Kept(id, link)),
        Ok(Err(why)) => Err(why),
        Err(_) => Err(format!("no new hub link and answer within {} s", within.as_secs())),
    }
}

/// A link's lifetime as `1h2m3s`, `4m5s` or `6s`.
fn lasted(d: Duration) -> String {
    let s = d.as_secs();
    match (s / 3600, s % 3600 / 60, s % 60) {
        (0, 0, sec) => format!("{sec}s"),
        (0, min, sec) => format!("{min}m{sec}s"),
        (h, min, sec) => format!("{h}h{min}m{sec}s"),
    }
}

/// How a ticket with `scope` is served under the consent on disk now: `Some(view_only)`,
/// or None when this desktop does not allow it or its consent file cannot be read.
fn admit(dir: &std::path::Path, scope: &str, applies_input: bool) -> Option<bool> {
    match LocalConsent::load(dir) {
        Ok(consent) => consent.serve(scope, applies_input),
        Err(e) => {
            eprintln!("linux-host: consent unreadable, nothing is served: {e}");
            None
        }
    }
}

/// Stops the session being served when `consent` (read again from disk; an error when it
/// cannot be read) no longer allows its scope; its id.
fn withdraw_unconsented(
    current: &Current,
    consent: Res<LocalConsent>,
    applies_input: bool,
) -> Option<String> {
    let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
    let allowed = match (&consent, guard.as_ref()) {
        (_, None) => return None,
        (Ok(consent), Some(served)) => consent.serve(&served.scope, applies_input).is_some(),
        (Err(_), Some(_)) => false,
    };
    if allowed {
        return None;
    }
    let served = guard.take()?;
    served.stop.store(true, Ordering::SeqCst);
    Some(served.id)
}

fn run(args: &Args) -> Res<()> {
    let (dir, hub, account) = load()?;
    let runtime = identity::runtime_dir()?;
    identity::private_dir(&runtime)?;
    // Read at start so a bad file fails now; read again for every ticket and every second.
    LocalConsent::load(&dir)?;
    let mut serve_args = Vec::new();
    for key in ["display", "xauthority", "capture"] {
        if let Some(v) = args.get(key) {
            serve_args.extend([format!("--{key}"), v.to_owned()]);
        }
    }
    // The capture choice is checked now, so a bad --capture fails at start, not per session.
    let capture = CaptureBackend::from_env(args.get("capture"))?;
    // Every session is served with this capture: a portal one without the RemoteDesktop grant
    // applies no input, so control tickets are served view only, and `approve` and `status`
    // read this to say so. A grant made later takes a restart.
    let applies_input = capture.applies_input();
    identity::write_private(&runtime.join("capture"), capture.name().as_bytes())?;
    // `cmux-rd serve` from this same binary, logging as `linux-host`.
    let serve_args = ServeCommand {
        program: std::env::current_exe()?,
        args: ["serve".to_owned()].into_iter().chain(serve_args).collect(),
        disclaim: false,
        log_prefix: "linux-host".into(),
        status_prefix: "cmux-rd linux-host".into(),
    };
    if account.anchored_until != 0 && account.anchored_until <= now_ms() {
        return Err(Fatal::needs("This desktop's 30-day sign-in ended", Fatal::SHARE_ON).into());
    }
    let hub = Arc::new(hub);
    let current: Current = Arc::new(Mutex::new(None));
    if let Some(display) = setup::virtual_display() {
        stop_idle_display(display, current.clone());
    }
    let mut backoff = Duration::from_secs(1);
    eprintln!(
        "linux-host: serving \"{}\" ({}){}",
        hub.device.name,
        hub.device.id,
        if applies_input { "" } else { NO_INPUT_NOTE }
    );
    let mut next: Option<WebSocket> = None;
    loop {
        let started = Instant::now();
        let opened = next.take();
        let relink_hub = hub.clone();
        let relink = move |id: String| -> Res<WebSocket> {
            // The new link first: a revocation after the answer below comes over it.
            let ws = relink_hub.user_socket()?;
            if relink_hub.session_live(&id)? {
                Ok(ws)
            } else {
                Err("the hub no longer has it on".into())
            }
        };
        let (result, after) = hold_link(
            &current,
            || hold_socket(&hub, opened, &dir, &runtime, &serve_args, &current, applies_input),
            relink,
            RELINK_WITHIN,
        );
        let why = match &result {
            Ok(()) => "closed".to_owned(),
            Err(e) => e.to_string(),
        };
        eprintln!(
            "linux-host: {} hub link: dropped after {}: {why}",
            utc_stamp(now_ms()),
            lasted(started.elapsed())
        );
        match after {
            AfterLink::Idle => {}
            AfterLink::Kept(_, ws) => {
                eprintln!(
                    "linux-host: a new hub link is up and the hub has the session on; it goes on"
                );
                next = Some(ws);
            }
            AfterLink::Stopped(id, why) => {
                eprintln!("linux-host: the session it served stopped: {why}");
                end_later(&hub, &id, "peer_offline");
            }
        }
        if let Err(e) = result {
            if let Some(fatal) = Fatal::from_hub(&*e) {
                return Err(fatal.into());
            }
        }
        if next.is_some() {
            backoff = Duration::from_secs(1);
            continue;
        }
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_secs(1);
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

/// How long the virtual display stays up with no share and no app window on it.
const DISPLAY_IDLE: Duration = Duration::from_secs(10 * 60);
/// How often the host looks at the virtual display.
const DISPLAY_CHECK_EVERY: Duration = Duration::from_secs(30);

/// Whether the virtual display has been idle long enough to stop, given when it was last
/// seen busy and whether it is busy now (a share, or a program on it).
fn display_idle(busy_now: bool, last_busy: &mut Instant, now: Instant) -> bool {
    if busy_now {
        *last_busy = now;
        return false;
    }
    now.duration_since(*last_busy) >= DISPLAY_IDLE
}

/// Stops the virtual display this host starts on demand once it has had no share and no app
/// window for [`DISPLAY_IDLE`], so nothing sits busy between shares. Runs as long as the host.
fn stop_idle_display(display: u32, current: Current) {
    let socket = std::path::PathBuf::from(format!("/tmp/.X11-unix/X{display}"));
    let spawned = std::thread::Builder::new().name("linux-host-display".into()).spawn(move || {
        let mut last_busy = Instant::now();
        loop {
            std::thread::sleep(DISPLAY_CHECK_EVERY);
            if !socket.exists() {
                last_busy = Instant::now();
                continue;
            }
            let sharing = current.lock().unwrap_or_else(|e| e.into_inner()).is_some();
            let busy = sharing || setup::display_in_use(display);
            if display_idle(busy, &mut last_busy, Instant::now()) {
                match setup::stop_virtual_display() {
                    Ok(()) => {
                        eprintln!("linux-host: the virtual display :{display} was idle; stopped")
                    }
                    Err(e) => eprintln!("linux-host: {e}"),
                }
                last_busy = Instant::now();
            }
        }
    });
    if let Err(e) = spawned {
        eprintln!("linux-host: the virtual display will not be stopped when idle: {e}");
    }
}

/// Holds one User DO socket (`opened`, or a new one) until it closes; handles its pushes.
fn hold_socket(
    hub: &Arc<Hub>,
    opened: Option<WebSocket>,
    dir: &std::path::Path,
    runtime: &std::path::Path,
    serve_args: &ServeCommand,
    current: &Current,
    applies_input: bool,
) -> Res<()> {
    let mut ws = match opened {
        Some(ws) => ws,
        None => hub.user_socket()?,
    };
    let mut last_ping = Instant::now();
    let mut last_consent = Instant::now();
    loop {
        if last_consent.elapsed() >= CONSENT_EVERY {
            // `enable --view-only` while this runs: a control session stops now.
            let consent = LocalConsent::load(dir);
            if let Some(id) = withdraw_unconsented(current, consent, applies_input) {
                eprintln!(
                    "linux-host: this desktop's consent no longer allows the session; stopped"
                );
                end_later(hub, &id, "host_stopped");
            }
            last_consent = Instant::now();
        }
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
                handle_push(hub, &push, dir, runtime, serve_args, current, applies_input);
            }
        }
    }
}

/// What a host `session.ticket` push leads to.
#[derive(Debug)]
enum OnTicket {
    /// Serve it; whether view only.
    Serve(Ticket, bool),
    /// End the session unserved: its id, the reason given to the hub, and why.
    End(String, &'static str, String),
    /// Nothing to serve or end: why.
    Drop(String),
}

/// The answer to a host ticket `push`; `admit` maps its scope to `Some(view_only)` or None
/// when this desktop does not allow it. A ticket that does not parse is ended too, as the
/// Mac host does: the hub approved the session, and only `/end` closes it.
fn on_ticket(push: &Value, admit: impl FnOnce(&str) -> Option<bool>) -> OnTicket {
    let ticket = match Ticket::from_push(push) {
        Ok(t) => t,
        Err(e) => {
            return match push["sessionId"].as_str().filter(|id| !id.is_empty()) {
                Some(id) => OnTicket::End(id.to_owned(), "failed", format!("ticket refused: {e}")),
                None => OnTicket::Drop(e.to_string()),
            }
        }
    };
    match admit(&ticket.scope) {
        Some(view_only) => OnTicket::Serve(ticket, view_only),
        None => OnTicket::End(
            ticket.session_id,
            "failed",
            format!("a {} session is not allowed on this desktop", printable(&ticket.scope)),
        ),
    }
}

fn handle_push(
    hub: &Arc<Hub>,
    push: &Value,
    dir: &std::path::Path,
    runtime: &std::path::Path,
    serve_args: &ServeCommand,
    current: &Current,
    applies_input: bool,
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
            match on_ticket(push, |scope| admit(dir, scope, applies_input)) {
                OnTicket::Serve(ticket, view_only) => {
                    start_session(hub, ticket, view_only, serve_args, current);
                }
                OnTicket::End(id, reason, why) => {
                    eprintln!("linux-host: {why}; ended");
                    end_later(hub, &id, reason);
                }
                OnTicket::Drop(why) => eprintln!("linux-host: ticket refused: {why}"),
            }
        }
        Some("session.revoked" | "session.ended" | "session.denied") => {
            let Some(id) = push["sessionId"].as_str() else { return };
            let _ = pending.remove(id, now_ms());
            let guard = current.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(served) = guard.as_ref() {
                if served.id == id {
                    served.stop.store(true, Ordering::SeqCst);
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
    serve_args: &ServeCommand,
    current: &Current,
) {
    let stop = Arc::new(AtomicBool::new(false));
    {
        let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = guard.take() {
            // One viewer at a time, the newest. A reattach of the same session replaces its own.
            old.stop.store(true, Ordering::SeqCst);
            if old.id != ticket.session_id {
                end_later(hub, &old.id, "replaced");
            }
        }
        *guard = Some(Served {
            id: ticket.session_id.clone(),
            scope: ticket.scope.clone(),
            stop: stop.clone(),
        });
    }
    let (hub, args, current) = (hub.clone(), serve_args.clone(), current.clone());
    let spawned = std::thread::Builder::new().name("linux-host-session".into()).spawn(move || {
        eprintln!(
            "linux-host: serving a {} session for {}",
            if view_only { "view" } else { "control" },
            printable(&ticket.peer_name)
        );
        // No graphical session here: the virtual display starts now, for this share.
        if let Some(display) = setup::virtual_display() {
            if let Err(e) = setup::ensure_virtual_display(display) {
                eprintln!("linux-host: {e}");
            }
        }
        let ended = session::serve(&hub, &ticket, view_only, &args, &stop);
        eprintln!("linux-host: session ended: {}", ended.reason);
        if let Some(reason) = ended.tell_hub {
            if let Err(e) = hub.end(&ticket.session_id, reason) {
                eprintln!("linux-host: end not sent: {e}");
            }
        }
        let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
        let ours = |s: &Served| s.id == ticket.session_id && Arc::ptr_eq(&s.stop, &stop);
        if guard.as_ref().is_some_and(ours) {
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
    use cmux_hub_host::b64;

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
    fn enable_consents_to_control_unless_view_only() {
        // A desktop joined to the person's own account: their devices control it with no prompt here.
        let enable = |extra: &[&str]| {
            let words: Vec<String> =
                std::iter::once("enable").chain(extra.iter().copied()).map(String::from).collect();
            let args = Args::parse(&words).unwrap();
            assert!(args
                .only(&[
                    "stack-token-file",
                    "hub",
                    "name",
                    "allow-control",
                    "view-only",
                    "non-interactive"
                ])
                .is_ok());
            enable_consent(&args)
        };
        assert_eq!(enable(&[]), LocalConsent { view: true, full: true });
        assert_eq!(enable(&["--allow-control"]), LocalConsent { view: true, full: true });
        assert_eq!(enable(&["--view-only"]), LocalConsent { view: true, full: false });
    }

    #[test]
    fn the_join_takes_no_account_token() {
        // No person's credential lands on a joined machine: a token on any flag is refused before
        // anything is read or written, and the join's command is otherwise never a failure.
        for path in ["-", "/tmp/token"] {
            let args = Args::parse(&[
                "enable".into(),
                "--non-interactive".into(),
                "--stack-token-file".into(),
                path.into(),
            ])
            .unwrap();
            let Err(e) = enable_for_join(&args) else { panic!("took a token") };
            assert!(e.to_string().contains("no account token"), "{e}");
        }
        assert!(NOT_INSTALLED.starts_with("not_installed: "));
    }

    #[test]
    fn status_takes_json_and_never_fails() {
        // Whatever this machine has set up, `status --json` maps it to a state.
        assert_eq!(run_cli(&["status".into(), "--json".into()]), 0);
        assert_eq!(run_cli(&["status".into(), "--always".into()]), 1);
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
    fn request_lines_are_printed_without_control_characters() {
        use cmux_hub_host::text::is_bidi_control;
        let hostile = "\u{1b}[2J\u{202e}Mallory\nlinux-host: approved";
        for line in [request_line(&request(hostile, None)), ask_line(&request(hostile, None))] {
            assert!(!line.chars().any(|c| c.is_control() || is_bidi_control(c)), "{line:?}");
            assert!(line.contains("Mallorylinux-host: approved"), "{line:?}");
        }
    }

    /// A `Current` serving session `s1` with `scope`, and its stop flag.
    fn serving(scope: &str) -> (Current, Arc<AtomicBool>) {
        let stop = Arc::new(AtomicBool::new(false));
        let served = Served { id: "s1".into(), scope: scope.into(), stop: stop.clone() };
        (Arc::new(Mutex::new(Some(served))), stop)
    }

    fn is_empty(current: &Current) -> bool {
        current.lock().unwrap().is_none()
    }

    const RESET: &str = "Connection reset by peer (os error 104)";
    const SOON: Duration = Duration::from_millis(500);

    fn stopped(after: &AfterLink<u32>) -> Option<&str> {
        match after {
            AfterLink::Stopped(id, _) => Some(id),
            _ => None,
        }
    }

    #[test]
    fn a_session_the_hub_still_has_on_survives_a_dropped_hub_link() {
        // The link reset under a live session; a new link came up and the hub answered 200.
        let (current, stop) = serving("full");
        let (result, after) = hold_link(
            &current,
            || Err(RESET.into()),
            |id| {
                assert_eq!(id, "s1");
                Ok(7u32)
            },
            SOON,
        );
        assert!(result.is_err());
        assert!(matches!(after, AfterLink::Kept(ref id, 7) if id == "s1"), "{after:?}");
        assert!(!stop.load(Ordering::SeqCst), "the session stopped although the hub has it on");
        assert!(!is_empty(&current));
    }

    #[test]
    fn a_dropped_hub_link_stops_the_session_unless_the_hub_says_it_is_on() {
        // The hub does not replay revocations pushed while the link was down: anything but
        // a new link and the hub's word that the session is on stops it (fail closed).
        let held_up = |stop: &Arc<AtomicBool>| {
            let held = stop.clone();
            move || -> Res<()> {
                assert!(!held.load(Ordering::SeqCst), "stopped while the link was up");
                Err(RESET.into())
            }
        };
        // The hub says the session is no longer on (409), or the new link failed.
        let (current, stop) = serving("full");
        let (result, after) = hold_link(
            &current,
            held_up(&stop),
            |_| -> Res<u32> { Err("the hub no longer has it on".into()) },
            SOON,
        );
        assert!(result.is_err());
        assert_eq!(stopped(&after), Some("s1"));
        assert!(stop.load(Ordering::SeqCst));
        assert!(is_empty(&current));
        // No new link and answer within the bound.
        let (current, stop) = serving("view");
        let (_, after) = hold_link(
            &current,
            held_up(&stop),
            |_| -> Res<u32> {
                std::thread::sleep(Duration::from_secs(2));
                Ok(1)
            },
            Duration::from_millis(50),
        );
        assert_eq!(stopped(&after), Some("s1"));
        assert!(stop.load(Ordering::SeqCst));
        // This desktop removed: stopped at once, no relink asked.
        let (current, stop) = serving("view");
        let removed = || -> Res<()> {
            Err(HubError { status: 403, code: "device_removed".into(), message: "gone".into() }
                .into())
        };
        let (_, after) = hold_link(
            &current,
            removed,
            |_| -> Res<u32> { panic!("relinked a removed desktop") },
            SOON,
        );
        assert_eq!(stopped(&after), Some("s1"));
        assert!(stop.load(Ordering::SeqCst));
        // Nothing served, nothing stopped or asked.
        let current: Current = Arc::new(Mutex::new(None));
        let (_, after) = hold_link(
            &current,
            || Ok(()),
            |_| -> Res<u32> { panic!("relinked for nothing") },
            SOON,
        );
        assert!(matches!(after, AfterLink::Idle));
    }

    #[test]
    fn link_lifetimes_read_short() {
        assert_eq!(lasted(Duration::from_secs(6)), "6s");
        assert_eq!(lasted(Duration::from_secs(432)), "7m12s");
        assert_eq!(lasted(Duration::from_secs(3723)), "1h2m3s");
    }

    fn consent_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("cmux-screen-host-consent-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    /// `enable` finds the encoder a session needs: an installed copy is used as it is, with no
    /// download (the only test that reads `XDG_DATA_HOME`).
    #[cfg(feature = "openh264")]
    #[test]
    fn enable_finds_an_installed_openh264() {
        let platform = cmux_encode::openh264::Platform::current().unwrap();
        let data = consent_dir("openh264");
        let dir = cmux_encode::cisco::dir_from("linux", |key| {
            (key == "XDG_DATA_HOME").then(|| data.clone().into_os_string())
        })
        .unwrap();
        std::fs::create_dir_all(&dir).unwrap();
        let lib = cmux_encode::cisco::library_path(&dir, platform);
        std::fs::write(&lib, b"stand-in").unwrap();
        std::env::set_var("XDG_DATA_HOME", &data);
        assert_eq!(openh264_line(), format!("OpenH264 is at {}", lib.display()));
        std::fs::remove_dir_all(&data).unwrap();
    }

    #[test]
    fn consent_is_read_again_for_each_ticket() {
        let dir = consent_dir("admit");
        LocalConsent { view: true, full: true }.save(&dir).unwrap();
        assert_eq!(admit(&dir, "full", true), Some(false));
        // `enable --view-only`, the host still running.
        LocalConsent { view: true, full: false }.save(&dir).unwrap();
        assert_eq!(admit(&dir, "full", true), None);
        assert_eq!(admit(&dir, "view", true), Some(true));
        // A consent file it cannot trust admits nothing.
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir.join("consent.json"), std::fs::Permissions::from_mode(0o644))
            .unwrap();
        assert_eq!(admit(&dir, "view", true), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn withdrawn_consent_stops_the_session_it_no_longer_allows() {
        let both = LocalConsent { view: true, full: true };
        let view_only = LocalConsent { view: true, full: false };
        let (current, stop) = serving("full");
        assert_eq!(withdraw_unconsented(&current, Ok(both), true), None);
        assert!(!stop.load(Ordering::SeqCst));
        assert_eq!(withdraw_unconsented(&current, Ok(view_only), true).as_deref(), Some("s1"));
        assert!(stop.load(Ordering::SeqCst));
        assert!(is_empty(&current));
        // A view session goes on under view-only consent.
        let (current, stop) = serving("view");
        assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
        assert!(!stop.load(Ordering::SeqCst));
        // An unreadable consent file stops it.
        assert_eq!(
            withdraw_unconsented(&current, Err("consent.json: bad mode".into()), true).as_deref(),
            Some("s1")
        );
        assert!(stop.load(Ordering::SeqCst));
        let current: Current = Arc::new(Mutex::new(None));
        assert_eq!(withdraw_unconsented(&current, Ok(view_only), true), None);
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

    #[test]
    fn a_deleted_consent_file_admits_nothing_and_stops_the_view_session() {
        let dir = consent_dir("deleted");
        LocalConsent { view: true, full: false }.save(&dir).unwrap();
        let (current, stop) = serving("view");
        assert_eq!(withdraw_unconsented(&current, LocalConsent::load(&dir), true), None);
        std::fs::remove_file(dir.join("consent.json")).unwrap();
        assert_eq!(admit(&dir, "view", true), None);
        assert_eq!(
            withdraw_unconsented(&current, LocalConsent::load(&dir), true).as_deref(),
            Some("s1")
        );
        assert!(stop.load(Ordering::SeqCst));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_portal_host_serves_view_only_and_says_so() {
        let dir = consent_dir("portal");
        LocalConsent { view: true, full: true }.save(&dir).unwrap();
        // The portal capture applies no input: a control ticket is served view only.
        assert_eq!(admit(&dir, "full", false), Some(true));
        assert_eq!(admit(&dir, "full", true), Some(false));
        let all = LocalConsent::load(&dir);
        assert_eq!(shares_line(&all, true), "view and control");
        let line = shares_line(&all, false);
        assert!(line.starts_with("view only") && line.contains("portal"), "{line}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn hub_refusal(code: &str) -> Box<dyn std::error::Error + Send + Sync> {
        HubError { status: 403, code: code.into(), message: "m".into() }.into()
    }

    #[test]
    fn enable_mints_a_new_identity_when_the_hub_refuses_this_one() {
        // The hub never registers a removed id again: `enable` must not reuse it.
        for code in ["device_removed", "device_key_mismatch"] {
            let old = Device::generate("desk").unwrap();
            let old_id = old.id.clone();
            let mut tried = Vec::new();
            let (device, ()) = with_fresh_identity(old, |d| {
                tried.push(d.id.clone());
                if d.id == old_id {
                    Err(hub_refusal(code))
                } else {
                    Ok(())
                }
            })
            .unwrap_or_else(|e| panic!("{code}: {e}"));
            assert_ne!(device.id, old_id, "{code}");
            assert_eq!(device.name, "desk");
            assert_eq!(tried, vec![old_id, device.id.clone()], "{code}");
        }
        // Any other error is returned as it is, with no new identity.
        let mut tries = 0;
        let result = with_fresh_identity(Device::generate("desk").unwrap(), |_| -> Res<()> {
            tries += 1;
            Err(hub_refusal("unavailable"))
        });
        assert!(result.is_err());
        assert_eq!(tries, 1);
        // A new identity refused too is not replaced again.
        let mut tries = 0;
        let result = with_fresh_identity(Device::generate("desk").unwrap(), |_| -> Res<()> {
            tries += 1;
            Err(hub_refusal("device_removed"))
        });
        assert!(result.is_err());
        assert_eq!(tries, 2);
    }

    #[test]
    fn a_joined_machine_signs_itself_in_registers_and_turns_sharing_on() {
        use super::stack_login::tests::stub;
        let (origin, seen) = stub(|_, request| match request.path.as_str() {
            "/v1/auth/machine" => (
                200,
                serde_json::json!({ "session": "s", "userId": "p:u", "expiresAt": now_ms() + 3_600_000 }),
            ),
            _ => (200, serde_json::json!({ "ok": true })),
        });
        let dir = consent_dir("machine-sign-in");
        identity::private_dir(&dir).unwrap();
        let credential: machine::MachineCredential =
            serde_json::from_str(r#"{"credential":"cmm_x","name":"lane-vm"}"#).unwrap();
        let (hub, account) =
            sign_in_machine(&dir, &origin, std::path::Path::new("/acpmux-home"), credential)
                .unwrap();
        assert_eq!(hub.device.name, "lane-vm", "named as the join named the machine");
        assert_eq!(
            account,
            Account { hub: origin.clone(), user_id: "p:u".into(), anchored_until: 0 }
        );
        assert_eq!(Account::load(&dir).unwrap(), Some(account));
        assert_eq!(
            machine::Joined::load(&dir).unwrap(),
            Some(machine::Joined { acpmux_home: "/acpmux-home".into() })
        );
        machine::Joined::clear(&dir).unwrap();
        assert_eq!(machine::Joined::load(&dir).unwrap(), None);
        machine::Joined::clear(&dir).unwrap();
        assert_eq!(Device::load(&dir).unwrap().unwrap().id, hub.device.id);
        let seen = seen.lock().unwrap().clone();
        let calls: Vec<(String, String)> =
            seen.iter().map(|s| (s.method.clone(), s.path.clone())).collect();
        let screen = format!("/v1/devices/{}/mac-screen", hub.device.id);
        assert_eq!(
            calls,
            [
                ("POST".to_owned(), "/v1/auth/machine".to_owned()),
                ("POST".to_owned(), "/v1/devices".to_owned()),
                ("PUT".to_owned(), screen),
            ]
        );
        // Registered as a Linux desktop, and joining is the consent: sharing on.
        assert_eq!(serde_json::from_str::<Value>(&seen[1].body).unwrap()["platform"], "linux");
        assert_eq!(serde_json::from_str::<Value>(&seen[2].body).unwrap()["shared"], true);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_virtual_display_stops_only_after_ten_idle_minutes() {
        let start = Instant::now();
        let mut last_busy = start;
        assert!(!display_idle(false, &mut last_busy, start + Duration::from_secs(9 * 60)));
        // A share or an app on it keeps it up, and the idle time starts again.
        assert!(!display_idle(true, &mut last_busy, start + Duration::from_secs(9 * 60)));
        assert!(!display_idle(false, &mut last_busy, start + Duration::from_secs(18 * 60)));
        assert!(display_idle(false, &mut last_busy, start + Duration::from_secs(19 * 60)));
    }

    fn ticket_push(sid_in_jws: &str) -> Value {
        let claims = serde_json::json!({"sid": sid_in_jws, "role": "host", "peerKey": "KEY"});
        let payload = b64::encode(claims.to_string().as_bytes())
            .trim_end_matches('=')
            .replace('+', "-")
            .replace('/', "_");
        serde_json::json!({
            "type": "session.ticket", "sessionId": "s1", "role": "host", "scope": "full",
            "ticket": format!("eyJhbGciOiJFUzI1NiJ9.{payload}.c2ln"),
            "signalURL": "wss://hub.example/v1/sessions/s1/ws", "ice": [],
            "peer": {"id": "v1", "name": "Mac", "signingKey": "KEY"}
        })
    }

    #[test]
    fn a_refused_host_ticket_ends_its_session() {
        assert!(matches!(on_ticket(&ticket_push("s1"), |_| Some(true)), OnTicket::Serve(_, true)));
        assert!(matches!(
            on_ticket(&ticket_push("s1"), |_| None),
            OnTicket::End(id, "failed", _) if id == "s1"
        ));
        // A ticket that does not agree with its JWS is ended too, as the Mac host does: the
        // approved session would otherwise stay open on the hub.
        let mut malformed = ticket_push("s2");
        assert!(matches!(
            on_ticket(&malformed, |_| Some(true)),
            OnTicket::End(id, "failed", _) if id == "s1"
        ));
        malformed["ticket"] = "not a jws".into();
        assert!(matches!(
            on_ticket(&malformed, |_| Some(true)),
            OnTicket::End(id, "failed", _) if id == "s1"
        ));
        // With no session id there is nothing to end.
        malformed["sessionId"] = Value::Null;
        assert!(matches!(on_ticket(&malformed, |_| Some(true)), OnTicket::Drop(_)));
    }

    #[test]
    fn approve_and_status_read_the_capture_the_host_recorded() {
        let dir = consent_dir("capture");
        identity::write_private(&dir.join("capture"), CaptureBackend::Portal.name().as_bytes())
            .unwrap();
        assert_eq!(host_capture(Some(&dir)), CaptureBackend::Portal);
        assert!(!host_capture(Some(&dir)).applies_input_with(false));
        identity::write_private(&dir.join("capture"), b"x11").unwrap();
        assert_eq!(host_capture(Some(&dir)), CaptureBackend::X11);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

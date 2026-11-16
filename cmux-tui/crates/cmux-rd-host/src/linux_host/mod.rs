//! `cmux-rd linux-host`: this Linux desktop as a device hub screen host, viewed from cmux on
//! a Mac exactly like a shared Mac (docs/device-hub/PROTOCOL.md). The Mac app holds a Mac's
//! device key and hub link and drives `cmux-rd serve`; on Linux this command does that job.
//!
//!   enable [--stack-token-file PATH|-] [--hub URL] [--name NAME] [--view-only] [--non-interactive]
//!       Signs in once with a cmux (Stack Auth) access token (without a token file, through
//!       a browser sign-in link: stack_login.rs), registers this desktop as a
//!       `linux` device, anchors it (it renews its own host session for 30 days with its
//!       device key, no token) and turns sharing on. The person's own devices view and control
//!       it with no prompt here (`--view-only` keeps control off); on Wayland it asks the portal
//!       once, now (`grant`), so no viewer's session asks again.
//!       `--non-interactive` (the machine join, often over ssh): takes no account token and opens
//!       no browser, finds the desktop through logind, waits a minute at most on the portal
//!       dialog, starts a virtual X display when there is no graphical session, installs the host
//!       unit on a desktop still enabled, else prints one `not_installed:` line (setup.rs).
//!   grant [--control]
//!       Wayland: asks the xdg-desktop-portal once (its dialog, on this screen) for the screen
//!       and, with `--control`, keyboard and pointer, and saves the restore token in
//!       `~/.config/cmux/screen-host/`, so no share asks again (portal.rs). Enable runs it.
//!   share on [--stack-token-file PATH|-] | share off
//!   run [--display :0] [--xauthority PATH] [--capture x11|portal]
//!       The host: holds the hub socket and serves approved sessions. Run it in the desktop
//!       user's graphical session (the user systemd unit `systemd/cmux-screen-host.service`).
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

// The device hub client and the session serving this host shares with `cmux-rd windows-host`
// (src/screen_host/); `cmux-rd view` (src/view/) reaches the client through this module too.
pub(crate) use crate::screen_host::printable;
use crate::screen_host::serving::Host;
use crate::screen_host::session::ServeArgs;
pub(crate) use crate::screen_host::{hub, identity, net};
// Only `cmux-rd view` reaches these through this module.
#[cfg(feature = "openh264")]
pub(crate) use crate::screen_host::{b64, rd_doc, session};
use crate::screen_host::{consent, requests};
mod setup;
pub(crate) mod stack_login;
mod status_json;

use crate::capture_backend::CaptureBackend;
use crate::Res;
use consent::LocalConsent;
use hub::{now_ms, Hub, HubError};
use identity::{Account, Device};
use std::time::Duration;

/// The production device hub (the Mac app's default).
pub(crate) const DEFAULT_HUB: &str = "https://cmux-device-hub.debussy.workers.dev";

const USAGE: &str = "usage: cmux-rd linux-host enable [--stack-token-file PATH|-] [--hub URL] [--name NAME] [--view-only] [--non-interactive]
       cmux-rd linux-host grant [--control]
       cmux-rd linux-host share on [--stack-token-file PATH|-] | share off
       cmux-rd linux-host run [--display :0] [--xauthority PATH] [--capture x11|portal]
       cmux-rd linux-host requests | approve SESSION [--always] [--scope view|full] | deny SESSION | status [--json]";

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
fn load() -> Res<(std::path::PathBuf, Hub, Account)> {
    let dir = identity::config_dir()?;
    let device = Device::load(&dir)?.ok_or("not enabled: run `cmux-rd linux-host enable` first")?;
    let account =
        Account::load(&dir)?.ok_or("not enabled: run `cmux-rd linux-host enable` first")?;
    let hub = Hub::new(&account.hub, device, Some(account.user_id.clone()))?;
    Ok((dir, hub, account))
}

/// The line `enable --non-interactive` prints on a machine it could not sign in: the hub has no
/// sign-in yet for the credential the join keeps, and no person's token ever lands on a joined
/// machine (hq docs/design/remote-spin-up.md section 5), so nothing else is asked for.
const NOT_INSTALLED: &str = "not_installed: screen sharing is set up on this machine but not signed in: the device hub cannot sign a joined machine in with its machine credential yet";

/// How long `enable --non-interactive` leaves the portal's dialog up for someone at the screen;
/// past it the join goes on and the first share asks once.
const JOIN_GRANT_WAIT: Duration = Duration::from_secs(60);

fn enable(args: &Args) -> Res<()> {
    if args.flag("non-interactive") {
        return enable_for_join(args);
    }
    let dir = identity::config_dir()?;
    identity::private_dir(&dir)?;
    let device = sign_in_and_register(args, &dir)?;
    let consent = enable_consent(args);
    consent.save(&dir)?;
    grant_capture_now(consent.full, &setup::detect_desktop(), None);
    println!(
        "This desktop is shared as \"{}\" ({}), {}. Start the host: systemctl --user enable --now cmux-screen-host.service",
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
        let display = setup::start_virtual_display()?;
        println!("{}", setup::virtual_display_line(display));
    }
    // Signed in by an earlier `enable` and still anchored: the host renews by its device key.
    let device = match (Account::load(&dir)?, Device::load(&dir)?) {
        (Some(account), Some(device)) if account.anchored_until > now_ms() => device,
        _ => {
            println!("{NOT_INSTALLED}");
            return Ok(());
        }
    };
    setup::install_host(virtual_display)?;
    println!(
        "This desktop is shared as \"{}\" ({}), {}; the host runs as {}.",
        device.name,
        device.id,
        shares_line(&Ok(consent), host_applies_input()),
        setup::HOST_UNIT
    );
    Ok(())
}

/// Signs in, registers this desktop (a new identity when the hub refuses the old one), anchors
/// it and turns sharing on; the device.
fn sign_in_and_register(args: &Args, dir: &std::path::Path) -> Res<Device> {
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
        hub.register()?;
        Ok((hub, user_id))
    })?;
    let anchored_until = hub.anchor()?;
    hub.set_shared(true)?;
    Account { hub: hub_url, user_id, anchored_until }.save(dir)?;
    Ok(hub.device)
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
    requests::list(&identity::runtime_dir()?)
}

fn approve(id: &str, args: &Args) -> Res<()> {
    let (dir, hub, _) = load()?;
    let no_input = (!host_applies_input()).then_some(NO_INPUT_NOTE);
    requests::approve(
        &dir,
        &identity::runtime_dir()?,
        &hub,
        id,
        args.get("scope"),
        args.flag("always"),
        no_input,
    )
}

fn deny(id: &str) -> Res<()> {
    let (_, hub, _) = load()?;
    requests::deny(&identity::runtime_dir()?, &hub, id)
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
    let serve_args = ServeArgs(serve_args);
    if account.anchored_until != 0 && account.anchored_until <= now_ms() {
        return Err(Fatal::needs("This desktop's 30-day sign-in ended", Fatal::SHARE_ON).into());
    }
    eprintln!(
        "linux-host: serving \"{}\" ({}){}",
        hub.device.name,
        hub.device.id,
        if applies_input { "" } else { NO_INPUT_NOTE }
    );
    let host = Host::new(hub, dir, runtime, serve_args, applies_input);
    host.run(|e| Fatal::from_hub(e).map(Into::into))
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

    fn consent_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("cmux-screen-host-consent-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_portal_host_says_it_serves_view_only() {
        let dir = consent_dir("portal");
        LocalConsent { view: true, full: true }.save(&dir).unwrap();
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

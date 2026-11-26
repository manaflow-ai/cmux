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
//!       `--non-interactive` (the machine join: acpmux's daemon runs it at its start on a joined
//!       machine, with no one there): takes no account token and opens
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
//!   remove-device DEVICE           removes one of the account's other devices from the hub
//!                                  (`DELETE /v1/devices/DEVICE`): an identity this host left
//!                                  behind when it joined again, still listed in every viewer
//!
//! Consent: the hub serves the account's own devices at once (a viewer with no saved permission
//! reads `full`) and a viewer the person allowed; a request under a saved Ask waits for `approve` and is
//! never answered by the host itself
//! (consent.rs). A `view` session applies no input, and so does every session of a host that
//! captures through the Wayland portal without a RemoteDesktop grant: there it is served view
//! only.

// Consent is shared with `cmux-rd windows-host` (src/screen_host/).
use crate::screen_host::consent;
mod machine;
mod serving;
mod setup;
pub(crate) mod stack_login;
mod status_json;

use crate::capture_backend::CaptureBackend;
use crate::Res;
use cmux_hub_host::hub::{now_ms, Hub, HubError, Renewal};
use cmux_hub_host::identity::{self, Account, Device};
use cmux_hub_host::net::Message;
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
       cmux-rd linux-host display | requests | approve SESSION [--always] [--scope view|full] | deny SESSION | status [--json]
       cmux-rd linux-host remove-device DEVICE";

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
        ["remove-device", id] => {
            parsed.only(&[]).map_err(Into::into).and_then(|()| remove_device(id))
        }
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
fn load(old: serving::OldRecord) -> Res<(std::path::PathBuf, Hub, Account)> {
    let (dir, hub, account, _) = load_locked(old)?;
    Ok((dir, hub, account))
}

/// [`load`], with the identity's [`serving::Lock`] still held for a caller that writes.
fn load_locked(old: serving::OldRecord) -> Res<(std::path::PathBuf, Hub, Account, serving::Lock)> {
    const NOT_ENABLED: &str = "not enabled: run `cmux-rd linux-host enable` first";
    let dir = identity::config_dir()?;
    let lock = serving::lock(&dir)?;
    let Some(account) = Account::load(&dir)? else {
        let (home, credential) = machine::current()?.ok_or(NOT_ENABLED)?;
        let join = machine::Join::of(&home, credential)?;
        identity::private_dir(&dir)?;
        // Nothing is signed in, so no host serves yet: there is no unit to stop first.
        let device = serving::join(&dir, &join, &serving::ThisProcess)?;
        let account = Account::load(&dir)?.ok_or(NOT_ENABLED)?;
        let hub = Hub::with_renewal(&join.hub, device, None, machine_renewal(join.credential))?;
        return Ok((dir, hub, account, lock));
    };
    if let Some(joined) = machine::Joined::load(&dir)? {
        // Only the current join's host serves, at its own hub (serving.rs); a record from
        // before joins were marked may sign in again, so the device and account are read after.
        let join = serving::current_join(&dir, &joined, machine::Join::read, old)?;
        let account = Account::load(&dir)?.ok_or(NOT_ENABLED)?;
        let device = Device::load(&dir)?.ok_or(NOT_ENABLED)?;
        let hub = Hub::with_renewal(&join.hub, device, None, machine_renewal(join.credential))?;
        return Ok((dir, hub, account, lock));
    }
    let device = Device::load(&dir)?.ok_or(NOT_ENABLED)?;
    // A person's sign-in is always anchored; an unanchored one with no join record is a join
    // whose sign-in did not finish, and serves nobody.
    if account.anchored_until == 0 {
        return Err(Fatal::needs(
            "This desktop's sign-in is incomplete: it has no join and no anchor",
            Fatal::ENABLE,
        )
        .into());
    }
    let hub = Hub::new(&account.hub, device, Some(account.user_id.clone()))?;
    Ok((dir, hub, account, lock))
}

/// Signs a joined machine in with its credential (`POST /v1/auth/machine`), registers this
/// desktop (a new identity when the hub refuses the old one) and turns sharing on: joining is
/// the consent (hq docs/design/remote-screen-share-zero-touch.md, L3). Sharing is turned on
/// only here, at the first sign-in, so a person's later "off" from any device stays off.
fn sign_in_machine(
    dir: &std::path::Path,
    join: &machine::Join,
    previous: Option<&machine::Joined>,
) -> Res<(Hub, Account)> {
    let (hub_url, acpmux_home, credential) = (join.hub.as_str(), &join.home, &join.credential);
    // The join record first: records that a crash leaves half written are never read as a
    // person's (`load`).
    machine::Joined::signed_in(previous, acpmux_home, credential).save(dir)?;
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
    // Held until the host is installed: a person's `enable` waits, then sees the join.
    let _lock = serving::lock(&dir)?;
    // The identity first, before any step that can fail: a person's host that was here is torn
    // down now, not left running when a later step fails.
    let joined = machine::current()?;
    let from_join = joined.is_some();
    // The join this machine was signed in for before this run signs it in again: a join from
    // before consent-join.json existed keeps its consent through that ([`join_consent`]).
    let before = machine::Joined::load(&dir).ok().flatten();
    let mark = joined.as_ref().map(|(home, credential)| machine::Joined::of(home, credential));
    // Before signing in: signing in rewrites joined.json, so a run stopped after it would
    // otherwise make a join from before the marker read as this build's stopped first run.
    mark_join_from_before_marker(&dir, before.as_ref(), mark.as_ref())?;
    let Some(device) = join_device(&dir, args.get("hub"), joined, &serving::HostUnit)? else {
        println!("{NOT_INSTALLED}");
        return Ok(());
    };
    let desktop = setup::detect_desktop();
    // The portal's grant is asked for only with consent this run wrote: a join's kept (or
    // withdrawn) choice is never asked again on someone's screen.
    let consent = join_consent(&dir, mark.as_ref(), args, &mut |control| {
        grant_capture_now(control, &desktop, Some(JOIN_GRANT_WAIT))
    })?;
    let virtual_display = desktop == setup::Desktop::None;
    if virtual_display {
        let display = setup::set_up_virtual_display()?;
        println!("{}", setup::virtual_display_line(display));
    }
    // The host this installs serves sessions at once, so its encoder is there first.
    let encoder = openh264_line();
    if from_join {
        serving::still_current(&dir, &serving::HostUnit)?;
    }
    setup::install_host(virtual_display)?;
    println!(
        "This desktop is shared as \"{}\" ({}), {}; the host runs as {}. {encoder}.",
        device.name,
        device.id,
        shares_line(&consent, host_applies_input()),
        setup::HOST_UNIT
    );
    Ok(())
}

/// The device `enable --non-interactive` installs the host as, or None when nothing signed
/// this machine in. A join always goes through [`serving::join`]: the host is the joiner's, at
/// the hub of the credential's own deployment ([`machine::Join`]). `expected_hub` is the hub the
/// caller (the acpmux daemon's `--hub`) read for the join: when the credential read here is
/// another deployment's (a leave and a join elsewhere came since), nothing is sent anywhere and
/// the daemon sets the new join up at its next check, from its own read of it.
fn join_device(
    dir: &std::path::Path,
    expected_hub: Option<&str>,
    joined: Option<(std::path::PathBuf, machine::MachineCredential)>,
    unit: &dyn serving::Unit,
) -> Res<Option<Device>> {
    let Some((home, credential)) = joined else {
        // Not joined: a person's own `enable`, while anchored, renews by its device key.
        return Ok(match (Account::load(dir)?, Device::load(dir)?) {
            (Some(account), Some(device)) if account.anchored_until > now_ms() => Some(device),
            _ => None,
        });
    };
    let join = machine::Join::of(&home, credential)?;
    if let Some(expected) = expected_hub.filter(|hub| hub.trim_end_matches('/') != join.hub) {
        return Err(format!(
            "this machine's join is now at {}, not {}: it was joined again since the caller read it, so nothing was signed in",
            join.hub,
            printable(expected)
        )
        .into());
    }
    serving::join(dir, &join, unit).map(Some)
}

/// The seam the identity tests stop the unit through.
#[cfg(test)]
struct NoUnit;

#[cfg(test)]
impl serving::Unit for NoUnit {
    fn stop(&self) -> Res<()> {
        Ok(())
    }
}

/// Deletes this desktop's sign-in: its device key, account and join records. Every one is tried
/// even when one fails; the first failure is returned.
fn forget_sign_in(dir: &std::path::Path) -> Res<()> {
    let mut first = None;
    for file in ["device.json", "account.json", machine::JOINED_FILE] {
        match std::fs::remove_file(dir.join(file)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
                first.get_or_insert(e);
            }
            _ => {}
        }
    }
    first.map_or(Ok(()), |e| Err(e.into()))
}

/// A person's own `enable`: signs in, registers this desktop, anchors it, installs the encoder
/// and turns sharing on ([`serving::person`]); the device and the encoder's line.
fn sign_in_and_register(args: &Args, dir: &std::path::Path) -> Res<(Device, String)> {
    // Held through the sign-in, so a join's enable cannot begin between the check and the
    // writes; one already under way finishes first and is seen.
    let _lock = serving::lock(dir)?;
    // A joined machine's host is the joiner's (#45369): refused before any token is read.
    if let Some(account) = serving::join_owner(dir)? {
        return Err(format!(
            "this machine is joined to {account}; run `acpmux machine leave` first"
        )
        .into());
    }
    let token = stack_token(args)?;
    let hub_url = match (args.get("hub"), Account::load(dir)?) {
        (Some(url), _) => url.to_owned(),
        (None, Some(account)) => account.hub,
        (None, None) => DEFAULT_HUB.to_owned(),
    };
    serving::person(dir, &hub_url, &token, args.get("name"), &openh264_line, &serving::HostUnit)
}

/// Cisco's OpenH264 in the per-user data directory (downloaded from Cisco the first time), in
/// one sentence. Without it every session ends with "openh264 is not installed".
fn openh264_line() -> String {
    #[cfg(feature = "openh264")]
    return openh264_line_in(cmux_encode::cisco::default_dir());
    #[cfg(not(feature = "openh264"))]
    "This build has no OpenH264 download; pass --openh264-lib PATH to run".to_owned()
}

/// [`openh264_line`] with the installer's directory given.
#[cfg(feature = "openh264")]
fn openh264_line_in(dir: Option<std::path::PathBuf>) -> String {
    match crate::encoder::ensure_openh264_in(dir) {
        Ok(path) => format!("OpenH264 is at {}", path.display()),
        Err(e) => format!(
            "OpenH264 is not installed ({}): run cmux-rd openh264-install before a viewer connects",
            printable(&e.to_string())
        ),
    }
}

/// `grant [--control]`: the Wayland portal's grant, made now so no share asks. A GNOME
/// desktop (mutter on the session bus) needs none and is asked nothing.
fn grant(control: bool) -> Res<()> {
    if CaptureBackend::from_env(None)? != CaptureBackend::Portal {
        println!("This is not a Wayland session: sharing it needs no portal grant.");
        return Ok(());
    }
    let line = portal_grant(control, None)?;
    println!("{line}");
    if line.starts_with(MUTTER_LINE_START) {
        return Ok(());
    }
    if identity::runtime_dir().is_ok_and(|dir| dir.join("capture").exists()) {
        println!("Restart the host to use it: systemctl --user restart cmux-screen-host.service");
    }
    Ok(())
}

/// How [`mutter_line`] starts (`grant` tells it from a portal grant by it).
const MUTTER_LINE_START: &str = "Screen sharing on this GNOME desktop needs no approval";

/// What a join says on a GNOME desktop, where shares go through mutter's own screen cast
/// (mutter.rs) and nothing is asked: `None` when the portal is the path. `remote_desktop`:
/// mutter offers keyboard and pointer.
fn mutter_line(
    capture: crate::capture_backend::WaylandCapture,
    remote_desktop: bool,
    control: bool,
) -> Option<String> {
    if capture.needs_grant() {
        return None;
    }
    let what = if !control {
        ""
    } else if remote_desktop {
        " (view and control)"
    } else {
        " (view only: this desktop offers no keyboard and pointer control)"
    };
    Some(format!("{MUTTER_LINE_START}{what}: no dialog appears on this screen."))
}

/// Asks the portal once for the screen (and, with `control`, keyboard and pointer) and saves
/// its restore token (portal.rs); what it granted. Prints the join's notes on what this portal
/// cannot keep (setup.rs). `within` bounds the wait on the dialog: past it nothing is saved and
/// the first share asks. A build that cannot capture through the portal asks nothing: a grant
/// would show a dialog for shares it cannot serve. On GNOME (mutter on the session bus) it asks
/// nothing either: mutter casts with no grant, and it says so ([`mutter_line`]).
#[cfg(feature = "portal-dbus")]
fn portal_grant(control: bool, within: Option<Duration>) -> Res<String> {
    use crate::capture_backend::WaylandCapture;
    use crate::portal::{PortalState, SessionKind};
    CaptureBackend::Portal.available()?;
    let (screen_cast, remote_desktop) = crate::capture_backend::mutter_on_bus();
    if let Some(line) = mutter_line(WaylandCapture::choose(screen_cast), remote_desktop, control) {
        return Ok(line);
    }
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

/// Beside `consent.json`: the join whose consent it is, written only after the consent itself
/// (review F1 of #45480). A rerun for that join keeps the consent as its person left it; a run
/// that stopped before this file was written writes the consent again on its next run, so a
/// joined machine is never left unshared by a crash.
const CONSENT_JOIN_FILE: &str = "consent-join.json";

fn write_consent_join(dir: &std::path::Path, mark: &machine::Joined) -> Res<()> {
    identity::write_private(&dir.join(CONSENT_JOIN_FILE), &serde_json::to_vec_pretty(mark)?)
}

/// The join `consent.json` was written for, if a run finished writing it.
fn consent_join(dir: &std::path::Path) -> Res<Option<machine::Joined>> {
    match identity::read_private(&dir.join(CONSENT_JOIN_FILE))? {
        Some(bytes) => Ok(serde_json::from_slice(&bytes).ok()),
        None => Ok(None),
    }
}

/// Writes the marker for the join `mark` when `before` (joined.json as this run found it, before
/// signing in) is that join from a build before the marker: from this home, naming this machine
/// or no machine at all (a record from before joins were marked), without
/// [`machine::Joined::consent_tracked`]. Its consent is then kept exactly as found: present,
/// missing (withdrawn) or unreadable. A record with the flag is this build's, so no marker
/// means its first run stopped before the consent, and [`join_consent`] writes it.
fn mark_join_from_before_marker(
    dir: &std::path::Path,
    before: Option<&machine::Joined>,
    mark: Option<&machine::Joined>,
) -> Res<()> {
    let (Some(before), Some(mark)) = (before, mark) else { return Ok(()) };
    let from_before = !before.consent_tracked
        && (before.same_machine(mark) || before.unmarked_from(&mark.acpmux_home));
    if from_before && consent_join(dir)?.is_none() {
        write_consent_join(dir, mark)?;
    }
    Ok(())
}

/// The consent `enable --non-interactive` leaves in `dir` for the join `mark` (None: not a
/// join), asking `grant` for the portal's grant (with control or not) only when it wrote it.
/// One join is one machine from one acpmux home: a credential generation the hub raises for
/// it (recovery) is no choice made at this screen.
fn join_consent(
    dir: &std::path::Path,
    mark: Option<&machine::Joined>,
    args: &Args,
    grant: &mut dyn FnMut(bool),
) -> Res<Res<LocalConsent>> {
    let same_join = match (mark, consent_join(dir)?) {
        (Some(mark), Some(written)) => mark.same_machine(&written),
        _ => false,
    };
    if same_join {
        // The person's choice stays, including a withdrawn one (no file). Only a narrower one
        // is taken: `--view-only` turns control off, never on.
        return match LocalConsent::load(dir) {
            Ok(kept) if kept.full && args.flag("view-only") => {
                let narrowed = LocalConsent { full: false, ..kept };
                narrowed.save(dir)?;
                Ok(Ok(narrowed))
            }
            kept => Ok(kept),
        };
    }
    let consent = enable_consent(args);
    consent.save(dir)?;
    // The consent first, then whose it is: a run cut off between the two writes it again.
    match mark {
        Some(mark) => write_consent_join(dir, mark)?,
        None => match std::fs::remove_file(dir.join(CONSENT_JOIN_FILE)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
            _ => {}
        },
    }
    grant(consent.full);
    Ok(Ok(consent))
}

/// On a Wayland desktop, asks the portal for its grant now, while the person who ran `enable` is
/// at the screen (with `control`, the RemoteDesktop grant: keyboard and pointer too), and keeps
/// the restore token it returns: later sessions start from that token with no dialog, so no
/// viewer's session waits on an Allow here. An X11 desktop or a virtual display needs no grant,
/// and neither does GNOME, which is cast through mutter directly: it asks nothing.
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
    let (dir, hub, mut account, _lock) = load_locked(serving::OldRecord::Keep)?;
    if machine::Joined::load(&dir)?.is_some() {
        // A joined machine's session may turn its own sharing on (PROTOCOL.md, Machine sign-in).
        hub.set_shared(true)?;
        println!("Sharing is on.");
        return Ok(());
    }
    // Turning sharing on needs the account itself (a host session may only turn it off), and
    // only this desktop's own: another account's token anchors nothing here (serving.rs).
    let user = hub.sign_in_with_stack(&stack_token(args)?)?;
    if user != account.user_id {
        return Err(format!(
            "this desktop is signed in as {}, not {user}; to share it as {user}, run: cmux-rd linux-host enable",
            account.user_id
        )
        .into());
    }
    account.anchored_until = hub.anchor()?;
    hub.set_shared(true)?;
    account.save(&dir)?;
    println!("Sharing is on.");
    Ok(())
}

fn share_off() -> Res<()> {
    let (_, hub, _) = load(serving::OldRecord::Keep)?;
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
    let (dir, hub, _) = load(serving::OldRecord::Keep)?;
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
    let (_, hub, _) = load(serving::OldRecord::Keep)?;
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

/// `remove-device DEVICE`: the hub forgets one of the account's devices, signed by this host.
fn remove_device(id: &str) -> Res<()> {
    let (_, hub, _) = load(serving::OldRecord::Keep)?;
    remove_device_on(&hub, id)?;
    println!("Removed device {id} from the hub.");
    Ok(())
}

/// Asks `hub` to remove device `id`: a hub device id (letters, digits and dashes), never this
/// host's own, which would end its serving (`share off` stops sharing instead).
fn remove_device_on(hub: &Hub, id: &str) -> Res<()> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
        return Err(format!(
            "{id:?} is not a device id (the hub's ids are like 281f0b45-b1b9-...)"
        )
        .into());
    }
    if id.eq_ignore_ascii_case(&hub.device.id) {
        return Err(format!(
            "{id} is this host's own device; run `cmux-rd linux-host share off` to stop sharing"
        )
        .into());
    }
    hub.call("DELETE", &format!("/v1/devices/{id}"), None).map(|_| ())
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

/// Holds one hub link with `hold`; when it ends, for any reason, the session it served stops.
/// The hub does not replay a revocation, an end or sharing turned off that it pushed while
/// the link was down, so a session must not outlive the link that would hear them (fail
/// closed). The result of `hold` and the id of the session stopped.
fn hold_link(current: &Current, hold: impl FnOnce() -> Res<()>) -> (Res<()>, Option<String>) {
    let result = hold();
    (result, stop_current(current))
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
    let (dir, hub, account) = load(serving::OldRecord::Heal)?;
    // What this process serves as, read now; it exits once the records say otherwise.
    let serving_as = serving::Serving::now(&dir)?;
    // Held while this process lives: a teardown that takes it knows no host serves.
    let _running = cmux_hub_host::host_process::hold(&dir)?;
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
    // What the daemon that set this host up reads to tell a host on the hub from one that only
    // runs (cmux_hub_host::host_link).
    let mut link = cmux_hub_host::host_link::Reporter::starting(&dir, now_ms());
    eprintln!(
        "linux-host: serving \"{}\" ({}){}",
        hub.device.name,
        hub.device.id,
        if applies_input { "" } else { NO_INPUT_NOTE }
    );
    loop {
        let started = Instant::now();
        let (result, stopped) = hold_link(&current, || {
            hold_socket(
                &hub,
                &dir,
                &runtime,
                &serve_args,
                &current,
                applies_input,
                &serving_as,
                &mut link,
            )
        });
        link.offline(
            &match &result {
                Ok(()) => "the hub link closed".to_owned(),
                Err(e) => format!("hub link: {e}"),
            },
            now_ms(),
        );
        // The host keeps the identity invariant itself (serving.rs): a sign-in that changed or
        // went away, or a join that was replaced or left, ends the link, the session (above)
        // and this process.
        if let Some(why) = serving_as.changed(&dir) {
            return Err(retired(&why));
        }
        if let Some(id) = stopped {
            eprintln!("linux-host: the hub link dropped; the session it served stopped");
            end_later(&hub, &id, "peer_offline");
        }
        match result {
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
        if let Some(why) = serving::wait_serving(&serving_as, &dir, backoff, serving::WATCH_EVERY) {
            return Err(retired(&why));
        }
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

/// Why a host that is no longer this desktop's identity exits; it is not restarted.
fn retired(why: &str) -> Box<dyn std::error::Error + Send + Sync> {
    eprintln!("linux-host: {why}; the session stopped and the host exits");
    Fatal::needs(
        &format!("The host no longer serves as this desktop's sign-in: {why}"),
        Fatal::ENABLE,
    )
    .into()
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

/// Holds one User DO socket until it closes; handles its pushes.
#[allow(clippy::too_many_arguments)]
fn hold_socket(
    hub: &Arc<Hub>,
    dir: &std::path::Path,
    runtime: &std::path::Path,
    serve_args: &ServeCommand,
    current: &Current,
    applies_input: bool,
    serving_as: &serving::Serving,
    link: &mut cmux_hub_host::host_link::Reporter,
) -> Res<()> {
    let mut ws = hub.user_socket()?;
    link.online(now_ms());
    let mut last_ping = Instant::now();
    let mut last_consent = Instant::now();
    let mut last_identity = Instant::now();
    loop {
        if last_identity.elapsed() >= serving::WATCH_EVERY {
            // No longer this desktop's identity: `run` stops the session and exits.
            if serving_as.changed(dir).is_some() {
                return Ok(());
            }
            last_identity = Instant::now();
        }
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

/// The hub says both devices are signed in to one account (`ownerKind: "user"`, which the hub
/// writes from its own authenticated record, never from the viewer): the person reaching their
/// own desktop. A missing field (an older hub) or any other owner is not shown to be own.
fn own_account(push: &Value) -> bool {
    push.get("ownerKind").and_then(Value::as_str) == Some("user")
}

/// The answer to a host ticket `push`; `admit` maps a scope to `Some(view_only)` or None
/// when this desktop does not allow it. A ticket that does not parse is ended too, as the
/// Mac host does: the hub approved the session, and only `/end` closes it.
///
/// The person's own device (``own_account``) is never refused a screen this desktop shares
/// (Leo, 2026-11-17, ask-834a26b463: "if i've connected, i need to share the screen"): a
/// control ticket on a desktop enabled `--view-only` is served view only, as a `view` session,
/// instead of ended. This desktop's `--view-only` still keeps control off. A refusal ends the
/// session `consent_required`, as the Mac hosts do, so the viewer reads why.
fn on_ticket(push: &Value, admit: impl Fn(&str) -> Option<bool>) -> OnTicket {
    let mut ticket = match Ticket::from_push(push) {
        Ok(t) => t,
        Err(e) => {
            return match push["sessionId"].as_str().filter(|id| !id.is_empty()) {
                Some(id) => OnTicket::End(id.to_owned(), "failed", format!("ticket refused: {e}")),
                None => OnTicket::Drop(e.to_string()),
            }
        }
    };
    if let Some(view_only) = admit(&ticket.scope) {
        return OnTicket::Serve(ticket, view_only);
    }
    if own_account(push) && ticket.scope == "full" && admit("view").is_some() {
        // Served and watched as the view session it is (`withdraw_unconsented` reads this scope).
        ticket.scope = "view".to_owned();
        return OnTicket::Serve(ticket, true);
    }
    OnTicket::End(
        ticket.session_id,
        "consent_required",
        format!("a {} session is not allowed on this desktop", printable(&ticket.scope)),
    )
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
        if let Some(reason) = ended.tell_hub.as_deref() {
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
mod tests;

#[cfg(test)]
mod join_consent_tests;

//! Remote hosting (plans/cmux-next/remote-hosts.md): this machine's cmux
//! sessions served to the owner's other machines over the user's tailnet,
//! and the client verbs that find and dial such hosts.
//!
//! `cmux host enable|disable|status|serve|allow|deny|list|dial`, on macOS,
//! Linux and Windows. `cmux host ticket|join` (Unix) are acpmux's pairing
//! verbs (`cmux acp host ticket|join`, acpmux `src/pairing/`). `cmux host status` on a cmux Cloud machine (its
//! supervisor status file exists) stays the supervisor's status; pass
//! `--remote` there for remote hosting.

mod admit;
mod agent_proxy;
pub(crate) mod audit;
mod client;
pub(crate) mod config;
mod grant;
mod preface;
mod serve;
mod service;
mod shares;
#[cfg(test)]
mod teammate_tests;

/// The tailnet CLI wrapper lives in acpmux, which `acpmux host candidates`
/// also uses.
use acpmux::tailnet;

use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail};
use serde_json::{Value, json};

const USAGE: &str = "usage: cmux host enable [--owner LOGIN] [--session NAME] [--port N] [--no-service] [--no-spawn] [--json]
       cmux host disable [--json]
       cmux host status [--json] [--remote]
       cmux host allow LOGIN | deny LOGIN
       cmux host grant LOGIN [--scope status|agents|shell]... [--json]
       cmux host revoke LOGIN [--json]
       cmux host grants [--json]
       cmux host share SURFACE LOGIN [--role member|guest] [--json]
       cmux host unshare SURFACE LOGIN [--json]
       cmux host shares [--json]
       cmux host list [--json] [--all] [--port N]
       cmux host dial HOST [--port N]
       cmux host serve [--dir DIR]
       cmux host ticket new [--role daemon|client|read-only] [--ttl 15m] [--url WSS_URL] [--label TEXT] [--json]
       cmux host ticket ls [--json] | ticket revoke ID [--json]
       cmux host join TICKET [--name NAME] [--peer-name NAME] [--advertise WSS_URL] [--serve] [--json]";

const VERBS: &[&str] = &[
    "enable",
    "disable",
    "serve",
    "serve-detached",
    "allow",
    "deny",
    "list",
    "dial",
    "grant",
    "revoke",
    "grants",
    "share",
    "unshare",
    "shares",
];

/// Pairing verbs, forwarded to acpmux (`cmux acp host …`), which runs in
/// this process on Unix only.
const PAIRING_VERBS: &[&str] = &["ticket", "join"];

/// Whether `cmux host <rest>` is a remote hosting verb (the other `host`
/// verbs belong to the machine supervisor, crate `cmux-host`).
pub(crate) fn handles(raw_args: &[String]) -> bool {
    if raw_args.first().map(String::as_str) != Some("host") {
        return false;
    }
    let rest = &raw_args[1..];
    match rest.first().map(String::as_str) {
        Some(verb) if VERBS.contains(&verb) => true,
        Some(verb) if PAIRING_VERBS.contains(&verb) => cfg!(unix),
        Some("status") => status_is_remote(&rest[1..]),
        _ => false,
    }
}

/// `status` is remote hosting's unless this is a supervised cmux machine
/// (its status file exists, or `--root` names one) and `--remote` is absent.
fn status_is_remote(args: &[String]) -> bool {
    if args.iter().any(|a| a == "--remote") {
        return true;
    }
    if args.iter().any(|a| a == "--root") {
        return false;
    }
    !(cfg!(target_os = "linux") && Path::new("/run/cmux-host/status.json").exists())
}

/// Runs `cmux host <rest>`; returns the exit code.
pub(crate) fn run(rest: &[String]) -> i32 {
    let verb = rest.first().map(String::as_str).unwrap_or_default();
    let args = &rest[1.min(rest.len())..];
    if verb == "dial" {
        return dial(args);
    }
    #[cfg(unix)]
    if PAIRING_VERBS.contains(&verb) {
        return pairing(verb, args);
    }
    let result = require_safe_host_user(verb).and_then(|()| match verb {
        "enable" => enable(args),
        "disable" => disable(args),
        "status" => status(args),
        "serve" => serve_dir(args).and_then(|()| serve::run(self_exe()?)),
        "serve-detached" => serve_dir(args).and_then(|()| {
            service::spawn_detached(&self_exe()?)?;
            Ok(())
        }),
        "allow" => edit_allow(args, true),
        "deny" => edit_allow(args, false),
        "list" => list(args),
        "grant" => grant_access(args),
        "revoke" => revoke_access(args),
        "grants" => list_grants(args),
        "share" | "unshare" | "shares" => shares::run(verb, args),
        _ => Err(anyhow!("unknown verb")),
    });
    match result {
        Ok(()) => 0,
        Err(e) if e.downcast_ref::<Usage>().is_some() => {
            eprintln!("cmux host {verb}: {e}\n{USAGE}");
            2
        }
        Err(e) => {
            eprintln!("cmux host {verb}: {e:#}");
            1
        }
    }
}

/// `cmux host ticket|join …` = `cmux acp host ticket|join …`. `join --serve`
/// first turns remote hosting on (`cmux host enable`, which needs a signed-in
/// tailnet and changes nothing in it); its report goes to stderr, so stdout
/// stays the join's one JSON object, and a failure there never stops the join.
#[cfg(unix)]
fn pairing(verb: &str, args: &[String]) -> i32 {
    let mut rest = args.to_vec();
    let before = rest.len();
    rest.retain(|arg| verb != "join" || arg != "--serve");
    if rest.len() != before {
        let enabled = self_exe().and_then(|exe| {
            Ok(std::process::Command::new(exe)
                .args(["host", "enable"])
                .stdout(std::process::Stdio::from(std::io::stderr()))
                .status()?)
        });
        match enabled {
            Ok(status) if status.success() => {}
            Ok(_) => {
                eprintln!("cmux host join: remote hosting is not on (see above); joining anyway");
            }
            Err(e) => eprintln!("cmux host join: remote hosting is not on ({e:#}); joining anyway"),
        }
    }
    let argv = ["host", verb].into_iter().map(String::from).chain(rest);
    crate::acp::run_scope("acp", argv.map(std::ffi::OsString::from).collect())
}

#[cfg(unix)]
fn require_safe_host_user(verb: &str) -> anyhow::Result<()> {
    require_safe_host_user_for(verb, cmux_tui_core::platform::effective_uid())
}

#[cfg(not(unix))]
fn require_safe_host_user(_verb: &str) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn require_safe_host_user_for(verb: &str, uid: u32) -> anyhow::Result<()> {
    // Hosting serves this user's sessions. A privileged listener would hand
    // root's terminals to the remote owner (for example after `sudo` starts
    // `serve` directly), so every listener-starting verb shares this guard.
    if uid == 0 && matches!(verb, "enable" | "serve" | "serve-detached") {
        bail!(
            "remote hosting runs as a user, not root: run `cmux host enable` as the user whose sessions to serve"
        );
    }
    Ok(())
}

#[derive(Debug)]
struct Usage(String);

impl std::fmt::Display for Usage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Usage {}

fn usage(message: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(Usage(message.into()))
}

/// Flags of one verb: `--name value` pairs and booleans, each at most once.
struct Flags {
    values: Vec<(String, Option<String>)>,
    positional: Vec<String>,
}

impl Flags {
    fn parse(args: &[String], with_value: &[&str], booleans: &[&str]) -> anyhow::Result<Self> {
        let mut values: Vec<(String, Option<String>)> = Vec::new();
        let mut positional = Vec::new();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let Some(name) = arg.strip_prefix("--") else {
                positional.push(arg.clone());
                continue;
            };
            let (name, inline) = match name.split_once('=') {
                Some((n, v)) => (n, Some(v.to_owned())),
                None => (name, None),
            };
            if values.iter().any(|(n, _)| n == name) {
                return Err(usage(format!("--{name} may be given once")));
            }
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

    fn value(&self, name: &str) -> Option<&str> {
        self.values.iter().find(|(n, _)| n == name).and_then(|(_, v)| v.as_deref())
    }

    fn has(&self, name: &str) -> bool {
        self.values.iter().any(|(n, _)| n == name)
    }

    fn port(&self) -> anyhow::Result<Option<u16>> {
        self.value("port")
            .map(|v| {
                v.parse::<u16>()
                    .ok()
                    .filter(|p| *p != 0)
                    .ok_or_else(|| usage("--port needs a port number"))
            })
            .transpose()
    }
}

/// `serve [--dir DIR]`: the services name the state directory `enable`
/// wrote, so the listener reads the same config.
fn serve_dir(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["dir"], &[])?;
    if !flags.positional.is_empty() {
        return Err(usage("takes no positional arguments"));
    }
    if let Some(dir) = flags.value("dir") {
        config::set_dir(PathBuf::from(dir));
    }
    Ok(())
}

/// The program the service runs: an absolute argv[0] named `cmux` (the
/// `host` verb exists only on the `cmux` surface), else this executable.
/// The path the services and detached starts run. It must be named `cmux`:
/// the `host` verbs exist only on the `cmux` surface, which is chosen from
/// argv[0]. `current_exe()` resolves symlinks, so a `cmux -> cmux-tui`
/// install would start `cmux-tui host serve` and fail; prefer the `cmux`
/// name this process was started by (absolute, relative or through PATH),
/// then a `cmux` next to the binary, when it is the same file.
pub(crate) fn self_exe() -> anyhow::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    if is_cmux_name(&exe) {
        return Ok(exe);
    }
    let real = std::fs::canonicalize(&exe).unwrap_or_else(|_| exe.clone());
    let same =
        |candidate: &Path| std::fs::canonicalize(candidate).is_ok_and(|resolved| resolved == real);
    let mut candidates = Vec::new();
    if let Some(argv0) = std::env::args_os().next().map(PathBuf::from)
        && is_cmux_name(&argv0)
    {
        if argv0.is_absolute() {
            candidates.push(argv0);
        } else if argv0.components().count() > 1 {
            if let Ok(cwd) = std::env::current_dir() {
                candidates.push(cwd.join(argv0));
            }
        } else if let Some(path) = std::env::var_os("PATH") {
            candidates.extend(std::env::split_paths(&path).map(|dir| dir.join(&argv0)));
        }
    }
    if let Some(dir) = exe.parent() {
        candidates.push(dir.join(if cfg!(windows) { "cmux.exe" } else { "cmux" }));
    }
    Ok(candidates.into_iter().find(|c| c.is_absolute() && same(c)).unwrap_or(exe))
}

fn is_cmux_name(path: &Path) -> bool {
    path.file_stem().and_then(|s| s.to_str()) == Some("cmux")
}

fn enable(args: &[String]) -> anyhow::Result<()> {
    let flags =
        Flags::parse(args, &["owner", "session", "port"], &["no-service", "no-spawn", "json"])?;
    if !flags.positional.is_empty() {
        return Err(usage("takes no positional arguments"));
    }
    let value = enable_report(&flags)?;
    output(&value, flags.has("json"));
    Ok(())
}

/// `cmux setup tailnet`'s change: what `cmux host enable [--owner LOGIN]
/// --json` does and prints, as its JSON (one mutation path for both).
pub(crate) fn setup_enable(owner: Option<&str>) -> anyhow::Result<Value> {
    let mut args = vec!["--json".to_owned()];
    if let Some(owner) = owner {
        args.extend(["--owner".to_owned(), owner.to_owned()]);
    }
    enable_report(&Flags::parse(
        &args,
        &["owner", "session", "port"],
        &["no-service", "no-spawn", "json"],
    )?)
}

/// `cmux setup tailnet`'s check: what `cmux host status --json` prints.
pub(crate) fn setup_status() -> Value {
    let config = match config::load() {
        Ok(config) => config,
        Err(e) => return json!({"error": format!("{e:#}")}),
    };
    let status = tailnet::Tailnet::locate().and_then(|t| t.status());
    let notes: Vec<String> =
        status.as_ref().err().map(|e| format!("tailnet: {e:#}")).into_iter().collect();
    status_value(&config, status.as_ref().ok(), &notes)
}

fn enable_report(flags: &Flags) -> anyhow::Result<Value> {
    let tailnet = tailnet::Tailnet::locate()?;
    let status = tailnet.status()?;
    if status.backend_state != "Running" {
        bail!(
            "Tailscale is {} on this machine. Sign in to Tailscale first, then run this again.",
            status.backend_state
        );
    }
    let owner = match flags.value("owner") {
        Some(owner) if owner.trim().eq_ignore_ascii_case(tailnet::TAGGED_LOGIN) => {
            return Err(usage("--owner needs a person's tailnet login"));
        }
        Some(owner) if !owner.trim().is_empty() => owner.trim().to_owned(),
        _ => match status.this.login.clone() {
            Some(login) => login,
            None => bail!(
                "this machine is a tagged tailnet node ({}), so it has no owner. Pass --owner <tailnet login> to name who may use it.",
                status.this.tags.join(", ")
            ),
        },
    };
    let lock = config::lock()?;
    let mut config = config::load()?;
    config.enabled = true;
    config.owner = Some(owner);
    if let Some(session) = flags.value("session") {
        cmux_tui_core::server::try_default_socket_path(session)
            .map_err(|e| usage(format!("--session: {e}")))?;
        config.session = Some(session.to_owned());
    }
    if let Some(port) = flags.port()? {
        config.port = port;
    }
    if flags.has("no-spawn") {
        if config.session.is_none() {
            return Err(usage("--no-spawn needs --session (the session another program starts)"));
        }
        config.spawn = false;
    }
    // The listener is replaced below on every enable.
    config::commit(&config, &lock, config::Listener::Caller)?;
    let exe = self_exe()?;
    let mut notes = Vec::new();
    let with_service = !flags.has("no-service");
    if with_service {
        match service::install(&exe) {
            Ok(what) => notes.push(format!("service: {what}")),
            Err(e) => notes.push(format!(
                "service not installed ({e:#}); started for this login session only"
            )),
        }
    }
    // A service from an earlier `enable` would start a second listener at the next login. Its
    // removal failing still replaces the running listener first: the config is already saved.
    let uninstalled = if with_service { Ok(()) } else { service::uninstall() };
    // A running `serve` keeps its old port and session; replace it.
    notes.push(service::restart(&exe, with_service)?);
    uninstalled?;
    if cfg!(target_os = "linux") && !flags.has("no-service") {
        notes.push(
            "headless machine: run `loginctl enable-linger $USER` once so hosting survives logout"
                .to_owned(),
        );
    }
    Ok(status_value(&config, Some(&status), &notes))
}

fn disable(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &[], &["json"])?;
    let lock = config::lock()?;
    let mut config = config::load()?;
    config.enabled = false;
    // The listener is stopped below.
    config::commit(&config, &lock, config::Listener::Caller)?;
    // Stopped even when removing the service fails: the config already says off.
    let uninstalled = service::uninstall();
    service::stop_running()?;
    uninstalled?;
    let status = tailnet::Tailnet::locate().and_then(|t| t.status()).ok();
    print_status(&config, status.as_ref(), flags.has("json"), &["remote hosting is off".to_owned()])
}

fn status(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &[], &["json", "remote"])?;
    let config = config::load()?;
    let status = tailnet::Tailnet::locate().and_then(|t| t.status());
    let mut notes = Vec::new();
    if let Err(e) = &status {
        notes.push(format!("tailnet: {e:#}"));
    }
    print_status(&config, status.as_ref().ok(), flags.has("json"), &notes)
}

fn print_status(
    config: &config::Config,
    status: Option<&tailnet::Status>,
    json_out: bool,
    notes: &[String],
) -> anyhow::Result<()> {
    output(&status_value(config, status, notes), json_out);
    Ok(())
}

fn output(value: &Value, json_out: bool) {
    if json_out {
        println!("{value}");
    } else {
        print_human(value);
    }
}

fn status_value(
    config: &config::Config,
    status: Option<&tailnet::Status>,
    notes: &[String],
) -> Value {
    let pid = service::running_pid();
    // A listener this command just started takes its lock after it checks
    // the tailnet, so right after a start it is "starting", not "off".
    let starting = pid.is_none() && notes.iter().any(|n| n.starts_with("started"));
    let addresses: Vec<String> = status
        .map(|s| {
            s.this
                .ips
                .iter()
                .filter(|ip| tailnet::is_tailnet_ip(**ip))
                .map(|ip| std::net::SocketAddr::new(*ip, config.port).to_string())
                .collect()
        })
        .unwrap_or_default();
    json!({
        "enabled": config.enabled,
        "serving": pid.is_some(),
        "starting": starting,
        "pid": pid,
        "owner": config.owner,
        "allow": config.allow,
        "session": config.session.clone().unwrap_or_else(|| "main".to_owned()),
        "spawn": config.spawn,
        "port": config.port,
        "name": status.map(|s| s.this.short_name()),
        "dns_name": status.map(|s| s.this.dns_name.clone()),
        "tailnet": status.map(|s| s.backend_state.clone()),
        "addresses": addresses,
        "teammate_access": config.teammate_access,
        "grants": config.grants,
        "teammate_connections": active_guests(),
        "audit_log": config::dir().ok().map(|d| d.join(audit::FILE).display().to_string()),
        "service": service::describe(),
        "config": config::shown_path(),
        "log": service::log_path().ok().map(|p| p.display().to_string()),
        "notes": notes,
    })
}

fn print_human(value: &Value) {
    let text = |key: &str| value[key].as_str().unwrap_or("-").to_owned();
    let state = match (value["enabled"].as_bool(), value["serving"].as_bool()) {
        (Some(true), Some(true)) => "on, serving",
        (Some(true), _) if value["starting"].as_bool() == Some(true) => "on, starting",
        (Some(true), _) => "on, not serving",
        _ => "off",
    };
    println!("Remote hosting: {state}");
    println!("  host:     {} ({})", text("name"), text("dns_name"));
    println!("  owner:    {}", text("owner"));
    let allow: Vec<&str> = value["allow"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if !allow.is_empty() {
        println!("  allowed:  {} (full access)", allow.join(", "));
    }
    print_teammates(value);
    println!("  session:  {}", text("session"));
    let addrs: Vec<&str> = value["addresses"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    println!("  listens:  {}", if addrs.is_empty() { "-".to_owned() } else { addrs.join(", ") });
    println!("  service:  {}", text("service"));
    println!("  log:      {}", text("log"));
    for note in value["notes"].as_array().into_iter().flatten().filter_map(Value::as_str) {
        println!("  note:     {note}");
    }
}

fn edit_allow(args: &[String], add: bool) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &[], &["json"])?;
    let [login] = flags.positional.as_slice() else {
        return Err(usage("needs exactly one tailnet login"));
    };
    let login = login.trim();
    if login.is_empty() || login.eq_ignore_ascii_case("tagged-devices") {
        return Err(usage("needs a person's tailnet login"));
    }
    let lock = config::lock()?;
    let mut config = config::load()?;
    // Checked under the lock, as `share` checks the list: neither change slips past the other.
    if add {
        shares::allowable(&config, login)?;
    }
    config.allow.retain(|l| !config::same_login(l, login));
    if add {
        config.allow.push(login.to_owned());
        eprintln!(
            "{login} can now use this machine's cmux sessions with full access (run commands as you)."
        );
    }
    let mut notes = Vec::new();
    if let Some(restarted) = config::commit(&config, &lock, config::Listener::Restart)? {
        notes.push(restarted);
        notes.push("open connections were closed".to_owned());
    }
    let status = tailnet::Tailnet::locate().and_then(|t| t.status()).ok();
    print_status(&config, status.as_ref(), flags.has("json"), &notes)
}

fn list(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &["port"], &["json", "all"])?;
    if !flags.positional.is_empty() {
        return Err(usage("takes no positional arguments"));
    }
    client::list(flags.has("json"), flags.has("all"), flags.port()?)
}

fn dial(args: &[String]) -> i32 {
    let flags = match Flags::parse(args, &["port"], &[]) {
        Ok(flags) => flags,
        Err(e) => {
            eprintln!("cmux host dial: {e}\n{USAGE}");
            return 2;
        }
    };
    let ([host], Ok(port)) = (flags.positional.as_slice(), flags.port()) else {
        eprintln!("cmux host dial: needs one host\n{USAGE}");
        return 2;
    };
    client::dial(host, port.unwrap_or(config::DEFAULT_PORT))
}

#[cfg(all(test, unix))]
mod privilege_tests {
    #[test]
    fn root_never_runs_remote_host_listener() {
        assert!(super::require_safe_host_user_for("enable", 0).is_err());
        assert!(super::require_safe_host_user_for("serve", 0).is_err());
        assert!(super::require_safe_host_user_for("serve-detached", 0).is_err());
        assert!(super::require_safe_host_user_for("status", 0).is_ok());
        assert!(super::require_safe_host_user_for("serve", 501).is_ok());
    }
}

/// Open teammate connections the listener recorded (empty when none or
/// when the listener is not running).
fn active_guests() -> Value {
    if service::running_pid().is_none() {
        return json!([]);
    }
    config::dir()
        .ok()
        .and_then(|dir| std::fs::read(dir.join(serve::ACTIVE_FILE)).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_else(|| json!([]))
}

fn print_teammates(value: &Value) {
    let on = value["teammate_access"].as_bool() == Some(true);
    let grants = value["grants"].as_array().cloned().unwrap_or_default();
    if !on && grants.is_empty() {
        return;
    }
    println!("  teammate access: {}", if on { "on" } else { "off" });
    for g in &grants {
        let scopes: Vec<&str> =
            g["scopes"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        let state = if g["revoked_at"].is_string() {
            "revoked"
        } else if g["consented_at"].is_string() {
            "approved"
        } else {
            "waiting for approval"
        };
        println!("    {} ({}): {state}", g["login"].as_str().unwrap_or("-"), scopes.join(", "));
    }
    for c in value["teammate_connections"].as_array().into_iter().flatten() {
        println!(
            "  CONNECTED NOW: {} from {} since {} (revoke: cmux host revoke {})",
            c["login"].as_str().unwrap_or("-"),
            c["node"].as_str().unwrap_or("-"),
            c["since"].as_str().unwrap_or("-"),
            c["login"].as_str().unwrap_or("LOGIN"),
        );
    }
    if let Some(log) = value["audit_log"].as_str() {
        println!("  audit:    {log}");
    }
}

/// `cmux host grant LOGIN [--scope S]...`: a teammate approves scoped
/// access for an allowlisted login, at a terminal (teammate-access-DESIGN.md 5).
fn grant_access(args: &[String]) -> anyhow::Result<()> {
    use std::io::IsTerminal as _;
    // Scopes repeat, so they are collected before the once-only flag parser.
    let mut scopes = Vec::new();
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let value = if arg == "--scope" {
            Some(it.next().cloned().ok_or_else(|| usage("--scope needs a value"))?)
        } else {
            arg.strip_prefix("--scope=").map(str::to_owned)
        };
        match value {
            Some(v) => scopes.push(
                grant::Scope::parse(&v)
                    .ok_or_else(|| usage(format!("unknown scope {v} (status, agents, shell)")))?,
            ),
            None => rest.push(arg.clone()),
        }
    }
    let flags = Flags::parse(&rest, &[], &["json"])?;
    let [login] = flags.positional.as_slice() else {
        return Err(usage("needs exactly one tailnet login"));
    };
    let login = login.trim().to_owned();
    if !grant::on_allowlist(&login) {
        bail!(
            "{login} is not on the teammate allowlist ({}); teammate access can only be granted to those logins",
            grant::TEAMMATE_ALLOWLIST.join(", ")
        );
    }
    if scopes.is_empty() {
        scopes.push(grant::Scope::Status);
    }
    scopes.sort();
    scopes.dedup();
    grant::require_interactive(std::io::stdin().is_terminal(), std::io::stderr().is_terminal())?;
    eprint!("{}\nType yes to allow: ", grant::consent_text(&login, &scopes));
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    if !grant::confirmed(&answer) {
        bail!("not approved; nothing changed");
    }
    let lock = config::lock()?;
    let mut config = config::load()?;
    grant::replace(&mut config, &login, scopes);
    config.teammate_access = true;
    let restarted = config::commit(&config, &lock, config::Listener::Restart)?;
    audit::append(&json!({"decision": "grant", "login": login, "outcome": "approved"}));
    let mut notes = vec![format!("approved teammate access for {login}")];
    if let Some(restarted) = restarted {
        notes.push(restarted);
        notes.push("open connections were closed".to_owned());
    }
    if !config.enabled {
        notes.push("remote hosting is off: run `cmux host enable` to start listening".to_owned());
    }
    let status = tailnet::Tailnet::locate().and_then(|t| t.status()).ok();
    print_status(&config, status.as_ref(), flags.has("json"), &notes)
}

/// `cmux host revoke LOGIN`: ends a teammate grant and closes its open
/// connections (the listener restarts).
fn revoke_access(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &[], &["json"])?;
    let [login] = flags.positional.as_slice() else {
        return Err(usage("needs exactly one tailnet login"));
    };
    let login = login.trim();
    let lock = config::lock()?;
    let mut config = config::load()?;
    let now = grant::now_rfc3339();
    let mut found = false;
    for g in config.grants.iter_mut().filter(|g| config::same_login(&g.login, login)) {
        g.revoked_at.get_or_insert_with(|| now.clone());
        found = true;
    }
    if !found {
        bail!("{login} has no teammate grant on this machine");
    }
    if config.grants.iter().all(|g| g.revoked_at.is_some()) {
        config.teammate_access = false;
    }
    let restarted = config::commit(&config, &lock, config::Listener::Restart)?;
    audit::append(&json!({"decision": "revoke", "login": login, "outcome": "revoked"}));
    let mut notes = vec![format!("revoked teammate access for {login}")];
    if let Some(restarted) = restarted {
        notes.push(restarted);
        notes.push("open connections were closed".to_owned());
    }
    let status = tailnet::Tailnet::locate().and_then(|t| t.status()).ok();
    print_status(&config, status.as_ref(), flags.has("json"), &notes)
}

fn list_grants(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &[], &["json"])?;
    let config = config::load()?;
    let value = json!({
        "teammate_access": config.teammate_access,
        "grants": config.grants,
        "teammate_connections": active_guests(),
        "audit_log": config::dir().ok().map(|d| d.join(audit::FILE).display().to_string()),
    });
    if flags.has("json") {
        println!("{value}");
    } else if config.grants.is_empty() {
        println!(
            "No teammate grants. Teammate access: {}.",
            if config.teammate_access { "on" } else { "off" }
        );
    } else {
        print_teammates(&value);
    }
    Ok(())
}

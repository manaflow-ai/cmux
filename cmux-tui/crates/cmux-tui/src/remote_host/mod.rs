//! Remote hosting (plans/cmux-next/remote-hosts.md): this machine's cmux
//! sessions served to the owner's other machines over the user's tailnet,
//! and the client verbs that find and dial such hosts.
//!
//! `cmux host enable|disable|status|serve|allow|deny|list|dial`, on macOS,
//! Linux and Windows. `cmux host status` on a cmux Cloud machine (its
//! supervisor status file exists) stays the supervisor's status; pass
//! `--remote` there for remote hosting.

mod admit;
mod client;
mod config;
mod preface;
mod serve;
mod service;
mod tailnet;

use std::path::PathBuf;

use anyhow::{anyhow, bail};
use serde_json::{Value, json};

const USAGE: &str = "usage: cmux host enable [--owner LOGIN] [--session NAME] [--port N] [--no-service] [--no-spawn] [--json]
       cmux host disable [--json]
       cmux host status [--json] [--remote]
       cmux host allow LOGIN | deny LOGIN
       cmux host list [--json] [--all] [--port N]
       cmux host dial HOST [--port N]
       cmux host serve";

const VERBS: &[&str] =
    &["enable", "disable", "serve", "serve-detached", "allow", "deny", "list", "dial"];

/// Whether `cmux host <rest>` is a remote hosting verb (the other `host`
/// verbs belong to the machine supervisor, crate `cmux-host`).
pub(crate) fn handles(raw_args: &[String]) -> bool {
    if raw_args.first().map(String::as_str) != Some("host") {
        return false;
    }
    let rest = &raw_args[1..];
    match rest.first().map(String::as_str) {
        Some(verb) if VERBS.contains(&verb) => true,
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
    !(cfg!(target_os = "linux") && std::path::Path::new("/run/cmux-host/status.json").exists())
}

/// Runs `cmux host <rest>`; returns the exit code.
pub(crate) fn run(rest: &[String]) -> i32 {
    let verb = rest.first().map(String::as_str).unwrap_or_default();
    let args = &rest[1.min(rest.len())..];
    let result = match verb {
        "enable" => enable(args),
        "disable" => disable(args),
        "status" => status(args),
        "serve" => no_args(args).and_then(|()| serve::run(self_exe()?)),
        "serve-detached" => no_args(args).and_then(|()| {
            service::spawn_detached(&self_exe()?)?;
            Ok(())
        }),
        "allow" => edit_allow(args, true),
        "deny" => edit_allow(args, false),
        "list" => list(args),
        "dial" => return dial(args),
        _ => Err(anyhow!("unknown verb")),
    };
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

fn no_args(args: &[String]) -> anyhow::Result<()> {
    if args.is_empty() { Ok(()) } else { Err(usage("takes no arguments")) }
}

/// The program the service runs: an absolute argv[0] named `cmux` (the
/// `host` verb exists only on the `cmux` surface), else this executable.
fn self_exe() -> anyhow::Result<PathBuf> {
    let argv0 = std::env::args_os().next().map(PathBuf::from);
    if let Some(path) = argv0.filter(|p| p.is_absolute()) {
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default();
        if stem == "cmux" {
            return Ok(path);
        }
    }
    Ok(std::env::current_exe()?)
}

fn enable(args: &[String]) -> anyhow::Result<()> {
    let flags =
        Flags::parse(args, &["owner", "session", "port"], &["no-service", "no-spawn", "json"])?;
    if !flags.positional.is_empty() {
        return Err(usage("takes no positional arguments"));
    }
    let tailnet = tailnet::Tailnet::locate()?;
    let status = tailnet.status()?;
    if status.backend_state != "Running" {
        bail!(
            "Tailscale is {} on this machine. Sign in to Tailscale first, then run this again.",
            status.backend_state
        );
    }
    let owner = match flags.value("owner") {
        Some(owner) if !owner.trim().is_empty() => owner.trim().to_owned(),
        _ => match status.this.login.clone() {
            Some(login) => login,
            None => bail!(
                "this machine is a tagged tailnet node ({}), so it has no owner. Pass --owner <tailnet login> to name who may use it.",
                status.this.tags.join(", ")
            ),
        },
    };
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
    config::save(&config)?;
    // A running `serve` keeps its old port and session; replace it.
    service::stop_running();
    let exe = self_exe()?;
    let mut notes = Vec::new();
    let started = if flags.has("no-service") {
        false
    } else {
        match service::install(&exe) {
            Ok(installed) => {
                notes.push(format!("service: {}", installed.what));
                installed.started
            }
            Err(e) => {
                notes.push(format!(
                    "service not installed ({e:#}); started for this login session only"
                ));
                false
            }
        }
    };
    if !started {
        let pid = service::spawn_detached(&exe)?;
        notes.push(format!("started cmux host serve (pid {pid})"));
    }
    if cfg!(target_os = "linux") && !flags.has("no-service") {
        notes.push(
            "headless machine: run `loginctl enable-linger $USER` once so hosting survives logout"
                .to_owned(),
        );
    }
    print_status(&config, Some(&status), flags.has("json"), &notes)
}

fn disable(args: &[String]) -> anyhow::Result<()> {
    let flags = Flags::parse(args, &[], &["json"])?;
    let mut config = config::load()?;
    config.enabled = false;
    config::save(&config)?;
    service::uninstall()?;
    service::stop_running();
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
    let pid = service::running_pid();
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
    let value = json!({
        "enabled": config.enabled,
        "serving": pid.is_some(),
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
        "service": service::describe(),
        "config": config::path().ok().map(|p| p.display().to_string()),
        "log": service::log_path().ok().map(|p| p.display().to_string()),
        "notes": notes,
    });
    if json_out {
        println!("{value}");
        return Ok(());
    }
    print_human(&value);
    Ok(())
}

fn print_human(value: &Value) {
    let text = |key: &str| value[key].as_str().unwrap_or("-").to_owned();
    let state = match (value["enabled"].as_bool(), value["serving"].as_bool()) {
        (Some(true), Some(true)) => "on, serving",
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
    let mut config = config::load()?;
    config.allow.retain(|l| !config::same_login(l, login));
    if add {
        config.allow.push(login.to_owned());
        eprintln!(
            "{login} can now use this machine's cmux sessions with full access (run commands as you)."
        );
    }
    config::save(&config)?;
    let status = tailnet::Tailnet::locate().and_then(|t| t.status()).ok();
    print_status(&config, status.as_ref(), flags.has("json"), &[])
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

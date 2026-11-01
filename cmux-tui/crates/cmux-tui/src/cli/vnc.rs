//! `cmux vnc`: a VNC (RFB) viewer in this terminal pane. It shows and
//! drives a Cloud VM's screen or any VNC server (macOS Screen Sharing,
//! Windows TightVNC/UltraVNC/RealVNC, Linux TigerVNC/x11vnc) through the
//! Kitty graphics protocol, which cmux's terminals speak. The RFB client is
//! the `cmux-vnc` crate; this module parses the command, resolves the
//! address, asks for credentials and runs the viewer.

mod keys;
mod kitty;
mod layout;
#[cfg(test)]
mod tests;
mod viewer;

use std::io::{self, BufRead, IsTerminal, Write};
use std::time::Duration;

use cmux_vnc::{Credentials, Endpoint, Session, SessionOptions, Transport, VncError};

use super::UsageError;

/// The RFB port of a Cloud VM's desktop (TigerVNC on loopback; the app's
/// port forward reaches it).
const CLOUD_DESKTOP_PORT: u16 = 5901;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// Password and user name sources when no flag names one.
const PASSWORD_ENV: &str = "CMUX_VNC_PASSWORD";
const USERNAME_ENV: &str = "CMUX_VNC_USERNAME";
/// Times to ask again after the server refuses typed credentials.
const PROMPT_ATTEMPTS: usize = 3;

pub(super) const HELP: &str = "\
USAGE
  cmux vnc <ADDRESS> [OPTIONS]
  cmux vnc machine:<MACHINE_ID> [--port <n>] [OPTIONS]

Shows a VNC (RFB) server's screen in this terminal pane and sends it your
keyboard and mouse. Works with macOS Screen Sharing, Windows (TightVNC,
UltraVNC, RealVNC with a VNC password) and Linux (TigerVNC, x11vnc).

ADDRESS
  host               display 0 (port 5900)
  host:N             display N (port 5900+N) when N < 100, else port N
  host::PORT         a port
  [v6addr]:PORT      an IPv6 address
  machine:ID         a cmux Cloud machine's desktop, through `cmux cloud
                     port-forward` (port 5901 unless --port)

OPTIONS
  --username <name>          the macOS user name (Screen Sharing) or a
                             VeNCrypt user (default: $CMUX_VNC_USERNAME)
  --password-env <VAR>       read the password from VAR (default: CMUX_VNC_PASSWORD)
  --password-file <path>     read the password from the file's first line
  --proxy-command <cmd>      speak RFB over the command's stdin and stdout
                             (for example `ssh -W localhost:5901 box`)
  --port <n>                 the machine port for machine:ID (default 5901)
  --view-only                show the screen; send no input
  --resize auto|remote|scale auto (default): resize the remote desktop to the
                             pane when the server allows it, else scale;
                             remote: the same; scale: never resize the server
  --fps <n>                  most frames drawn per second (default 30)
  --mouse cells|pixels       how the terminal reports the pointer (default:
                             pixels in Ghostty, kitty and WezTerm)
  --no-reconnect             end instead of reconnecting when the connection drops
  --remote-clipboard         copy the remote clipboard to this computer's
                             clipboard (off by default: the server could
                             otherwise set your clipboard at any time)

When the server needs a password and none is given, the viewer asks for one.
In the viewer, Ctrl-] then q quits, r reconnects, v toggles view only,
f redraws, and Ctrl-] sends Ctrl-] to the server.
";

/// Where the RFB stream comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Target {
    Tcp(Endpoint),
    Proxy(String),
    /// A Cloud machine port, forwarded by the app at each connect.
    Machine {
        id: String,
        port: u16,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResizeMode {
    Auto,
    Remote,
    Scale,
}

#[derive(Debug, Clone)]
pub(super) struct Config {
    pub target: Target,
    /// The address as typed, for the status line.
    pub label: String,
    pub credentials: Credentials,
    pub view_only: bool,
    pub resize: ResizeMode,
    pub fps: u32,
    pub reconnect: bool,
    /// `None`: decide from the terminal.
    pub pixel_mouse: Option<bool>,
    /// Copy ServerCutText to the local clipboard (OSC 52).
    pub remote_clipboard: bool,
}

/// `Some(args after "vnc")` when `command_args` start with `vnc`.
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    (first == "vnc").then_some(rest)
}

/// Parses `cmux vnc` arguments. `Ok(None)` asks for the help text.
/// `env` reads environment variables (injected for tests).
pub(super) fn parse(
    rest: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Option<Config>, UsageError> {
    let mut address = None;
    let mut username = env(USERNAME_ENV).filter(|value| !value.is_empty());
    let mut password_env = PASSWORD_ENV.to_owned();
    let mut password_file = None;
    let mut proxy = None;
    let mut port = None;
    let mut remote_clipboard = false;
    let mut config_flags = (false, ResizeMode::Auto, 30u32, true, None);
    let mut args = rest.iter();
    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = |name: &str| -> Result<String, UsageError> {
            inline
                .clone()
                .or_else(|| args.next().cloned())
                .ok_or_else(|| UsageError::new(format!("{name} needs a value")))
        };
        match flag {
            "-h" | "--help" | "help" => return Ok(None),
            "--username" => username = Some(value("--username")?),
            "--password-env" => password_env = value("--password-env")?,
            "--password-file" => password_file = Some(value("--password-file")?),
            "--proxy-command" => proxy = Some(value("--proxy-command")?),
            "--port" => {
                let raw = value("--port")?;
                port = Some(raw.parse::<u16>().ok().filter(|&p| p > 0).ok_or_else(|| {
                    UsageError::new(format!("--port must be 1-65535, not \"{raw}\""))
                })?);
            }
            "--view-only" => config_flags.0 = true,
            "--resize" => {
                config_flags.1 = match value("--resize")?.as_str() {
                    "auto" => ResizeMode::Auto,
                    "remote" => ResizeMode::Remote,
                    "scale" => ResizeMode::Scale,
                    other => {
                        return Err(UsageError::new(format!(
                            "--resize must be auto|remote|scale, not \"{other}\""
                        )));
                    }
                }
            }
            "--fps" => {
                let raw = value("--fps")?;
                config_flags.2 =
                    raw.parse::<u32>().ok().filter(|fps| (1..=240).contains(fps)).ok_or_else(
                        || UsageError::new(format!("--fps must be 1-240, not \"{raw}\"")),
                    )?;
            }
            "--no-reconnect" => config_flags.3 = false,
            "--remote-clipboard" => remote_clipboard = true,
            "--mouse" => {
                config_flags.4 = Some(match value("--mouse")?.as_str() {
                    "cells" => false,
                    "pixels" => true,
                    other => {
                        return Err(UsageError::new(format!(
                            "--mouse must be cells|pixels, not \"{other}\""
                        )));
                    }
                });
            }
            other if other.starts_with('-') && other.len() > 1 => {
                return Err(UsageError::new(format!(
                    "unknown vnc option \"{other}\" (see `cmux vnc --help`)"
                )));
            }
            _ if address.is_some() => {
                return Err(UsageError::new(format!(
                    "cmux vnc takes one address, got another: \"{arg}\""
                )));
            }
            _ => address = Some(arg.clone()),
        }
    }
    let password = match &password_file {
        Some(path) => Some(read_password_file(path)?),
        None => env(&password_env).filter(|value| !value.is_empty()),
    };
    let (target, label) = match (address, proxy) {
        (Some(address), None) => match address.strip_prefix("machine:") {
            Some(id) if !id.is_empty() => (
                Target::Machine { id: id.to_owned(), port: port.unwrap_or(CLOUD_DESKTOP_PORT) },
                address.clone(),
            ),
            Some(_) => {
                return Err(UsageError::new("machine: needs a machine id (machine:<MACHINE_ID>)"));
            }
            None => {
                if port.is_some() {
                    return Err(UsageError::new(
                        "--port is for machine:<ID>; put the port in the address (host::port)",
                    ));
                }
                let endpoint = Endpoint::parse(&address).map_err(UsageError::new)?;
                let label = endpoint.to_string();
                (Target::Tcp(endpoint), label)
            }
        },
        (None, Some(command)) => (Target::Proxy(command.clone()), command),
        (Some(_), Some(_)) => {
            return Err(UsageError::new("give an address or --proxy-command, not both"));
        }
        (None, None) => {
            return Err(UsageError::new(
                "cmux vnc needs an address: host[:display], host::port or machine:<ID>",
            ));
        }
    };
    let (view_only, resize, fps, reconnect, pixel_mouse) = config_flags;
    Ok(Some(Config {
        target,
        label,
        credentials: Credentials { username, password },
        view_only,
        resize,
        fps,
        reconnect,
        pixel_mouse,
        remote_clipboard,
    }))
}

fn read_password_file(path: &str) -> Result<String, UsageError> {
    let text = std::fs::read_to_string(path)
        .map_err(|error| UsageError::new(format!("cannot read --password-file {path}: {error}")))?;
    Ok(text.lines().next().unwrap_or("").to_owned())
}

/// Opens a session to `target` (the viewer's every connect and reconnect).
pub(super) fn open(target: &Target, options: &SessionOptions) -> Result<Session, VncError> {
    match target {
        Target::Tcp(endpoint) => {
            let transport = Transport::tcp(&endpoint.host, endpoint.port, CONNECT_TIMEOUT)?;
            Session::start(transport, options)
        }
        Target::Proxy(command) => {
            let (transport, stderr) = Transport::command(command)?;
            Session::start(transport, options).map_err(|error| with_stderr(error, &stderr.text()))
        }
        Target::Machine { id, port } => {
            let endpoint = forward_machine_port(id, *port)?;
            let transport = Transport::tcp(&endpoint.host, endpoint.port, CONNECT_TIMEOUT)?;
            Session::start(transport, options)
        }
    }
}

fn with_stderr(error: VncError, stderr: &str) -> VncError {
    match error {
        VncError::Io(io_error) if !stderr.is_empty() => {
            VncError::Io(io::Error::new(io_error.kind(), format!("{io_error} (proxy: {stderr})")))
        }
        other => other,
    }
}

/// Asks the app to forward the machine's port (`cmux cloud port-forward`)
/// and returns the local address it answers.
fn forward_machine_port(id: &str, port: u16) -> Result<Endpoint, VncError> {
    let exe = std::env::current_exe()?;
    let output = cmux_process::Command::new(exe)
        .args([
            "--json",
            "cloud",
            "port-forward",
            "--target",
            &format!("machine:{id}"),
            "--port",
            &port.to_string(),
        ])
        .output()?; // stdin null, stdout and stderr captured
    let stdout = String::from_utf8_lossy(&output.stdout);
    let failure = || {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        let detail = if detail.is_empty() { stdout.trim().to_owned() } else { detail };
        VncError::Io(io::Error::other(format!(
            "cannot forward port {port} of machine {id}: {detail}"
        )))
    };
    if !output.status.success() {
        return Err(failure());
    }
    forwarded_endpoint(&stdout).ok_or_else(failure)
}

/// The local address in a `cloud port-forward --json` answer: its `url`
/// (`http://127.0.0.1:PORT`), wherever the answer nests it.
pub(super) fn forwarded_endpoint(json: &str) -> Option<Endpoint> {
    fn find_url(value: &serde_json::Value) -> Option<&str> {
        match value {
            serde_json::Value::Object(map) => map
                .get("url")
                .and_then(serde_json::Value::as_str)
                .or_else(|| map.values().find_map(find_url)),
            serde_json::Value::Array(items) => items.iter().find_map(find_url),
            _ => None,
        }
    }
    let value: serde_json::Value = serde_json::from_str(json.trim()).ok()?;
    let url = url::Url::parse(find_url(&value)?).ok()?;
    let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']').to_owned();
    Some(Endpoint { host, port: url.port_or_known_default()? })
}

/// The first connection, before the viewer takes the terminal: a missing
/// or refused credential is asked for here, in plain line mode.
fn first_session(config: &mut Config) -> Result<Session, VncError> {
    let mut asked = 0;
    loop {
        let options =
            SessionOptions { credentials: config.credentials.clone(), ..SessionOptions::default() };
        match open(&config.target, &options) {
            Ok(session) => return Ok(session),
            Err(error @ (VncError::CredentialsRequired { .. } | VncError::AuthFailed(_)))
                if asked < PROMPT_ATTEMPTS && io::stdin().is_terminal() =>
            {
                let username = match &error {
                    VncError::CredentialsRequired { username } => *username,
                    _ => {
                        eprintln!("cmux: {}", printable(&error.to_string()));
                        config.credentials.username.is_some()
                    }
                };
                asked += 1;
                if username {
                    let default = config.credentials.username.clone().unwrap_or_default();
                    let typed =
                        prompt_line(&format!("User name for {} [{default}]: ", config.label))?;
                    config.credentials.username =
                        Some(if typed.is_empty() { default } else { typed });
                }
                config.credentials.password =
                    Some(prompt_password(&format!("Password for {}: ", config.label))?);
            }
            Err(error) => return Err(error),
        }
    }
}

fn prompt_line(prompt: &str) -> io::Result<String> {
    eprint!("{prompt}");
    io::stderr().flush()?;
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    Ok(line.trim_end_matches(['\r', '\n']).to_owned())
}

/// Reads a line with echo off.
fn prompt_password(prompt: &str) -> io::Result<String> {
    use std::os::fd::AsRawFd;
    let fd = io::stdin().as_raw_fd();
    let mut saved = std::mem::MaybeUninit::<libc::termios>::uninit();
    // SAFETY: fd is stdin; tcgetattr fills `saved` on success.
    let have_termios = unsafe { libc::tcgetattr(fd, saved.as_mut_ptr()) } == 0;
    if have_termios {
        // SAFETY: tcgetattr succeeded, so `saved` is initialized.
        let mut quiet = unsafe { saved.assume_init() };
        quiet.c_lflag &= !libc::ECHO;
        // SAFETY: a valid termios for this fd.
        unsafe { libc::tcsetattr(fd, libc::TCSANOW, &quiet) };
    }
    let line = prompt_line(prompt);
    if have_termios {
        // SAFETY: restores the attributes read above.
        unsafe { libc::tcsetattr(fd, libc::TCSANOW, saved.as_ptr()) };
        eprintln!();
    }
    line
}

/// `cmux vnc …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
    let env = |name: &str| std::env::var(name).ok();
    let mut config = match parse(rest, &env) {
        Ok(Some(config)) => config,
        Ok(None) => {
            print!("{HELP}");
            return Some(0);
        }
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    if !io::stdout().is_terminal() || !io::stdin().is_terminal() {
        return Some(super::app::failure(
            "vnc.not_a_terminal",
            "cmux: cmux vnc draws in a terminal pane; run it in one",
            global.output,
            2,
        ));
    }
    eprintln!("cmux: connecting to {}…", config.label);
    let session = match first_session(&mut config) {
        Ok(session) => session,
        Err(error) => {
            let code = if error.is_auth() { "vnc.auth" } else { "vnc.connect" };
            return Some(super::app::failure(
                code,
                &format!("cmux: {}: {}", config.label, printable(&error.to_string())),
                global.output,
                1,
            ));
        }
    };
    match viewer::run(config, session) {
        Ok(()) => Some(0),
        Err(error) => {
            Some(super::app::failure("vnc.terminal", &format!("cmux: {error}"), global.output, 1))
        }
    }
}

/// Server-supplied text (a desktop name, a refusal reason) made safe to
/// print: control characters (C0, DEL, C1) become `?`, so a server cannot
/// send terminal escape sequences (titles, OSC 52, links) through it.
pub(super) fn printable(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { '?' } else { c }).collect()
}

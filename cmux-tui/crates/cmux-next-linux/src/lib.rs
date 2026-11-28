//! cmux NEXT on Linux, developer preview (cmux#330).
//!
//! The launch plan, kept apart from the window so it is tested without GTK: which folder holds
//! the private daemon's state, which ports and token it gets, which commands start the daemon
//! and the pane's dev server, and the one URL the window opens. `main.rs` runs the plan.
//!
//! What this is: the same agent pane the macOS app shows (webviews `src/agent-session/acpmux`),
//! served by its Vite dev server and connected to a private `acpmux daemon run` through the
//! dev host (`webviews/src/dev-host/host.ts`), the pairing `webviews/scripts/agent-pane/dev-slot.sh`
//! makes for a browser tab. What it is not: the production bridge. The page holds the loopback
//! token in its URL fragment and its trust prompts are the dev host's stubs, so the daemon runs
//! as a development launch (`--dev --allow-dev-origin`). The production host (the socket held
//! by the host, as `AgentPaneTransport.swift` does on macOS) is the next step (README.md).

use std::ffi::OsString;
use std::fmt::Write as _;
use std::net::TcpListener;
use std::path::{Path, PathBuf};

/// What the person passed, after defaults.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    /// The cmux checkout's `webviews/` folder (it has `package.json` and the pane's sources).
    pub webviews: PathBuf,
    /// The acpmux binary.
    pub acpmux: PathBuf,
    /// The folder new chats start in.
    pub cwd: PathBuf,
    /// The daemon's state folder (`ACPMUX_HOME`), private to this preview.
    pub home: PathBuf,
    /// Print the plan and exit, opening nothing.
    pub dry_run: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    Help,
    Message(String),
}

pub const USAGE: &str = "\
usage: cmux-next-linux [--webviews DIR] [--acpmux BIN] [--cwd DIR] [--home DIR] [--dry-run]

Opens cmux NEXT's agent chat in a Linux desktop window (developer preview).

  --webviews DIR  the cmux checkout's webviews/ folder (default: $CMUX_WEBVIEWS, else ./webviews)
  --acpmux BIN    the acpmux binary (default: $ACPMUX_BIN, else acpmux on PATH)
  --cwd DIR       the folder new chats start in (default: the current folder)
  --home DIR      the private daemon's state (default: $XDG_STATE_HOME/cmux-next-linux)
  --dry-run       print the commands and the URL, start nothing
";

/// The environment the defaults read, passed in so tests set it.
#[derive(Debug, Default, Clone)]
pub struct Env {
    pub cmux_webviews: Option<OsString>,
    pub acpmux_bin: Option<OsString>,
    pub xdg_state_home: Option<OsString>,
    pub home: Option<OsString>,
    pub path: Option<OsString>,
    pub current_dir: PathBuf,
}

impl Env {
    pub fn from_process() -> Self {
        Self {
            cmux_webviews: std::env::var_os("CMUX_WEBVIEWS"),
            acpmux_bin: std::env::var_os("ACPMUX_BIN"),
            xdg_state_home: std::env::var_os("XDG_STATE_HOME"),
            home: std::env::var_os("HOME"),
            path: std::env::var_os("PATH"),
            current_dir: std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        }
    }
}

pub fn parse_args(args: &[OsString], env: &Env) -> Result<Options, ParseError> {
    let mut webviews = None;
    let mut acpmux = None;
    let mut cwd = None;
    let mut home = None;
    let mut dry_run = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let arg = arg.to_string_lossy();
        let mut value = |name: &str| {
            it.next()
                .map(PathBuf::from)
                .ok_or_else(|| ParseError::Message(format!("{name} needs a value")))
        };
        match arg.as_ref() {
            "-h" | "--help" => return Err(ParseError::Help),
            "--webviews" => webviews = Some(value("--webviews")?),
            "--acpmux" => acpmux = Some(value("--acpmux")?),
            "--cwd" => cwd = Some(value("--cwd")?),
            "--home" => home = Some(value("--home")?),
            "--dry-run" => dry_run = true,
            other => return Err(ParseError::Message(format!("unknown argument: {other}"))),
        }
    }
    let webviews = webviews
        .or_else(|| env.cmux_webviews.clone().map(PathBuf::from))
        .unwrap_or_else(|| env.current_dir.join("webviews"));
    if !webviews.join("package.json").is_file() {
        return Err(ParseError::Message(format!(
            "{} is not a webviews/ folder (no package.json): pass --webviews or set CMUX_WEBVIEWS",
            webviews.display()
        )));
    }
    let acpmux = match acpmux.or_else(|| env.acpmux_bin.clone().map(PathBuf::from)) {
        Some(bin) => bin,
        None => find_on_path("acpmux", env.path.as_deref()).ok_or_else(|| {
            ParseError::Message("no acpmux on PATH: pass --acpmux or set ACPMUX_BIN".into())
        })?,
    };
    let home = match home {
        Some(home) => home,
        None => state_home(env)
            .ok_or_else(|| ParseError::Message("no HOME or XDG_STATE_HOME: pass --home".into()))?
            .join("cmux-next-linux"),
    };
    Ok(Options {
        webviews,
        acpmux,
        cwd: cwd.unwrap_or_else(|| env.current_dir.clone()),
        home,
        dry_run,
    })
}

fn state_home(env: &Env) -> Option<PathBuf> {
    if let Some(dir) = env.xdg_state_home.as_ref().filter(|d| !d.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    env.home.as_ref().map(|h| Path::new(h).join(".local/state"))
}

fn find_on_path(name: &str, path: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    std::env::split_paths(path?).map(|dir| dir.join(name)).find(|p| p.is_file())
}

/// One child process the window owns: started with the plan, stopped when the window closes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub cwd: PathBuf,
    /// Set on top of the inherited environment.
    pub env: Vec<(String, OsString)>,
    /// Removed from the inherited environment.
    pub env_remove: Vec<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub daemon_port: u16,
    pub pane_port: u16,
    pub token: String,
    pub daemon: Command,
    pub pane: Command,
    pub url: String,
}

/// A running session's acpmux variables: a daemon started from inside a chat must not
/// join that chat's daemon (dev-slot.sh unsets the same ones).
const SESSION_ENV: [&str; 6] = [
    "ACPMUX_ENV",
    "ACPMUX_SESSION_ID",
    "ACPMUX_SESSION_NAME",
    "ACPMUX_SESSION_TMPDIR",
    "ACPMUX_SESSION_TOKEN",
    "ACPMUX_SESSION_TOKEN_SOCKET",
];

pub fn plan(options: &Options, daemon_port: u16, pane_port: u16, token: String) -> Plan {
    let pane_origin = format!("http://127.0.0.1:{pane_port}");
    let daemon = Command {
        program: options.acpmux.clone(),
        args: [
            "daemon",
            "run",
            "--listen",
            &format!("127.0.0.1:{daemon_port}"),
            "--token",
            &token,
            "--allow-dev-origin",
            &pane_origin,
            "--dev",
        ]
        .into_iter()
        .map(OsString::from)
        .collect(),
        cwd: options.cwd.clone(),
        env: vec![
            ("ACPMUX_HOME".into(), options.home.clone().into_os_string()),
            ("ACPMUX_SOCKET".into(), options.home.join("acpmux.sock").into_os_string()),
        ],
        env_remove: SESSION_ENV.to_vec(),
    };
    let pane = Command {
        program: PathBuf::from("bun"),
        args: vec!["run".into(), "dev".into()],
        cwd: options.webviews.clone(),
        env: vec![
            ("CMUX_WEBVIEWS_DEV_PORT".into(), pane_port.to_string().into()),
            ("CMUX_WEBVIEWS_DEV_STATE_DIR".into(), options.home.clone().into_os_string()),
        ],
        env_remove: vec![],
    };
    let url = pane_url(pane_port, daemon_port, &token, &options.cwd);
    Plan { daemon_port, pane_port, token, daemon, pane, url }
}

/// The agent pane's URL: the dev host reads the daemon's endpoint, token and folder from the
/// fragment (`devHostParams`), which the page never sends to a server.
pub fn pane_url(pane_port: u16, daemon_port: u16, token: &str, cwd: &Path) -> String {
    let origin = format!("http://127.0.0.1:{pane_port}");
    format!(
        "{origin}/agent-pane/#endpoint={}&token={}&cwd={}&editor={}",
        form_encode(&format!("ws://127.0.0.1:{daemon_port}/")),
        form_encode(token),
        form_encode(&cwd.to_string_lossy()),
        form_encode(&origin),
    )
}

/// `application/x-www-form-urlencoded`, which `URLSearchParams` decodes.
fn form_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                out.push(byte as char)
            }
            b' ' => out.push('+'),
            _ => {
                let _ = write!(out, "%{byte:02X}");
            }
        }
    }
    out
}

/// 24 random bytes as hex, as dev-slot.sh's `openssl rand -hex 24`.
pub fn fresh_token() -> std::io::Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).map_err(|e| std::io::Error::other(e.to_string()))?;
    Ok(bytes.iter().fold(String::with_capacity(48), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    }))
}

/// A loopback port free now. Port 4190 is on the WHATWG fetch bad-ports list (WebKit refuses
/// it), so a pick that lands there is skipped.
pub fn free_port() -> std::io::Result<u16> {
    loop {
        let port = TcpListener::bind("127.0.0.1:0")?.local_addr()?.port();
        if !BAD_PORTS.contains(&port) {
            return Ok(port);
        }
    }
}

/// The fetch spec's bad ports above 1024 (an ephemeral pick is never below).
const BAD_PORTS: [u16; 11] = [1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566];

#[cfg(test)]
mod tests {
    use super::*;

    fn env_with(dir: &Path) -> Env {
        Env {
            home: Some("/home/p".into()),
            path: Some(dir.join("bin").into_os_string()),
            current_dir: dir.to_path_buf(),
            ..Env::default()
        }
    }

    fn fixture() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-next-linux-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("webviews")).unwrap();
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        std::fs::write(dir.join("webviews/package.json"), "{}").unwrap();
        std::fs::write(dir.join("bin/acpmux"), "").unwrap();
        dir
    }

    #[test]
    fn defaults_find_the_checkout_acpmux_and_state_home() {
        let dir = fixture();
        let o = parse_args(&[], &env_with(&dir)).unwrap();
        assert_eq!(o.webviews, dir.join("webviews"));
        assert_eq!(o.acpmux, dir.join("bin/acpmux"));
        assert_eq!(o.cwd, dir);
        assert_eq!(o.home, PathBuf::from("/home/p/.local/state/cmux-next-linux"));
        assert!(!o.dry_run);
    }

    #[test]
    fn flags_and_env_override_defaults() {
        let dir = fixture();
        let mut env = env_with(&dir);
        env.xdg_state_home = Some("/state".into());
        env.acpmux_bin = Some("/opt/acpmux".into());
        let o = parse_args(&[], &env).unwrap();
        assert_eq!(o.acpmux, PathBuf::from("/opt/acpmux"));
        assert_eq!(o.home, PathBuf::from("/state/cmux-next-linux"));
        let args: Vec<OsString> =
            ["--acpmux", "/x/acpmux", "--cwd", "/work", "--home", "/h", "--dry-run"]
                .map(OsString::from)
                .to_vec();
        let o = parse_args(&args, &env).unwrap();
        assert_eq!(o.acpmux, PathBuf::from("/x/acpmux"));
        assert_eq!(o.cwd, PathBuf::from("/work"));
        assert_eq!(o.home, PathBuf::from("/h"));
        assert!(o.dry_run);
    }

    #[test]
    fn refuses_what_it_cannot_run() {
        let dir = fixture();
        let env = Env { path: None, ..env_with(&dir) };
        assert!(
            matches!(parse_args(&[], &env), Err(ParseError::Message(m)) if m.contains("no acpmux"))
        );
        let args = [OsString::from("--webviews"), dir.join("bin").into_os_string()];
        assert!(
            matches!(parse_args(&args, &env_with(&dir)), Err(ParseError::Message(m)) if m.contains("not a webviews"))
        );
        assert!(matches!(
            parse_args(&["--cwd".into()], &env_with(&dir)),
            Err(ParseError::Message(_))
        ));
        assert!(matches!(
            parse_args(&["--bogus".into()], &env_with(&dir)),
            Err(ParseError::Message(_))
        ));
        assert_eq!(parse_args(&["--help".into()], &env_with(&dir)), Err(ParseError::Help));
    }

    #[test]
    fn the_daemon_is_a_private_development_launch_for_the_pane_origin_only() {
        let o = Options {
            webviews: "/c/webviews".into(),
            acpmux: "/b/acpmux".into(),
            cwd: "/work".into(),
            home: "/h".into(),
            dry_run: false,
        };
        let p = plan(&o, 5001, 5002, "t0k".into());
        let args: Vec<String> = p.daemon.args.iter().map(|a| a.to_string_lossy().into()).collect();
        assert_eq!(
            args,
            [
                "daemon",
                "run",
                "--listen",
                "127.0.0.1:5001",
                "--token",
                "t0k",
                "--allow-dev-origin",
                "http://127.0.0.1:5002",
                "--dev"
            ]
        );
        assert!(p.daemon.env.contains(&("ACPMUX_HOME".into(), "/h".into())));
        assert!(p.daemon.env.contains(&("ACPMUX_SOCKET".into(), "/h/acpmux.sock".into())));
        assert!(p.daemon.env_remove.contains(&"ACPMUX_SESSION_TOKEN"));
        assert_eq!(p.daemon.cwd, PathBuf::from("/work"));
        assert_eq!(p.pane.cwd, PathBuf::from("/c/webviews"));
        assert!(p.pane.env.contains(&("CMUX_WEBVIEWS_DEV_PORT".into(), "5002".into())));
    }

    #[test]
    fn the_url_carries_what_dev_host_params_reads_encoded() {
        let url = pane_url(5002, 5001, "ab12", Path::new("/w/my repo&x"));
        assert_eq!(
            url,
            "http://127.0.0.1:5002/agent-pane/#endpoint=ws%3A%2F%2F127.0.0.1%3A5001%2F&token=ab12&cwd=%2Fw%2Fmy+repo%26x&editor=http%3A%2F%2F127.0.0.1%3A5002"
        );
    }

    #[test]
    fn tokens_are_fresh_hex_and_ports_avoid_bad_ports() {
        let a = fresh_token().unwrap();
        assert_eq!(a.len(), 48);
        assert!(a.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_ne!(a, fresh_token().unwrap());
        let port = free_port().unwrap();
        assert!(port > 1024 && !BAD_PORTS.contains(&port));
    }
}

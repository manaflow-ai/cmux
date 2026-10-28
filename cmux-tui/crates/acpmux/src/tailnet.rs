//! The user's tailnet, through the installed `tailscale` CLI (phase 1 of
//! plans/cmux-next/remote-hosts.md 4.1: system tailscaled). Shared by
//! cmux-tui's remote hosting (`remote_host`) and `acpmux host candidates`
//! and `host enroll` (`cli/host_peering.rs`). The CLI owns
//! each platform's LocalAPI transport (Linux Unix socket, macOS app or
//! standalone port with its same-user proof, Windows named pipe), so cmux
//! carries no copy of it. Every call has a bound; a CLI that does not
//! answer is an error, never a guess.

use std::collections::HashMap;
use std::io::Read;
use std::net::IpAddr;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use serde_json::Value;
use wait_timeout::ChildExt;

#[cfg(all(unix, feature = "tailnet"))]
pub mod embedded;
#[cfg(all(unix, feature = "tailnet"))]
pub(crate) mod embedded_service;

/// How long one CLI call may take (status on a large tailnet is the
/// slowest, about 100 ms measured on a 150-peer tailnet).
const CLI_BOUND: Duration = Duration::from_secs(8);
/// How long `tailscale version` may take while choosing a CLI.
const PROBE_BOUND: Duration = Duration::from_secs(3);
/// Largest CLI output read (a 2,000-peer status is about 4 MiB).
const MAX_OUTPUT: u64 = 32 * 1024 * 1024;

/// One node of the tailnet as `tailscale status --json` reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    /// The OS host name (`HostName`).
    pub host_name: String,
    /// The MagicDNS name without the trailing dot, or empty.
    pub dns_name: String,
    pub os: String,
    /// The owner's login; `None` for a tagged node (it has no owner).
    pub login: Option<String>,
    pub tags: Vec<String>,
    pub ips: Vec<IpAddr>,
    pub online: bool,
    /// Shared into this tailnet from another one (`ShareeNode`).
    pub shared: bool,
}

impl Node {
    /// The MagicDNS short name (first label), else the host name.
    pub fn short_name(&self) -> String {
        self.dns_name
            .split('.')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or(&self.host_name)
            .to_owned()
    }

    pub fn tagged(&self) -> bool {
        !self.tags.is_empty()
    }

    /// The address a client dials: IPv4 first.
    pub fn dial_ip(&self) -> Option<IpAddr> {
        self.ips.iter().find(|ip| ip.is_ipv4()).or_else(|| self.ips.first()).copied()
    }
}

#[derive(Clone, Debug)]
pub struct Status {
    pub backend_state: String,
    pub this: Node,
    pub peers: Vec<Node>,
}

/// Who is at a peer address (`tailscale whois`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    /// `None` when the node is tagged (its profile is `tagged-devices`).
    pub login: Option<String>,
    /// The node's MagicDNS name without the trailing dot.
    pub node: String,
    pub tags: Vec<String>,
    /// The node was shared into this tailnet by another user (`Node.Sharer`
    /// is set); its login is the sharer's, not proof of who runs it.
    pub shared: bool,
}

/// The profile login of every tagged node; never a person.
pub const TAGGED_LOGIN: &str = "tagged-devices";

fn person(login: &str) -> Option<String> {
    let login = login.trim();
    (!login.is_empty() && !login.eq_ignore_ascii_case(TAGGED_LOGIN)).then(|| login.to_owned())
}

pub struct Tailnet {
    bin: PathBuf,
}

impl Tailnet {
    /// Finds the CLI: `CMUX_TAILSCALE_BIN` (taken as is), then the first
    /// working CLI on `PATH`, then in each platform's install locations.
    pub fn locate() -> anyhow::Result<Self> {
        if let Some(bin) = std::env::var_os("CMUX_TAILSCALE_BIN").filter(|v| !v.is_empty()) {
            return Ok(Self { bin: PathBuf::from(bin) });
        }
        let name = if cfg!(windows) { "tailscale.exe" } else { "tailscale" };
        let mut candidates = Vec::new();
        if let Some(paths) = std::env::var_os("PATH") {
            candidates.extend(std::env::split_paths(&paths).map(|dir| dir.join(name)));
        }
        candidates.extend(platform_candidates());
        Self::locate_among(&candidates).ok_or_else(|| {
            anyhow!(
                "Tailscale is not installed on this machine (no `tailscale` command found). Install it and sign in, then run this again."
            )
        })
    }

    /// The first of `candidates` that is a working CLI: a file that answers
    /// `tailscale version` with a version. A file that prints nothing (the
    /// macOS app binary where it does not act as a CLI, a stale shim) or fails
    /// is skipped, so cmux never settles on a binary that answers nothing.
    fn locate_among(candidates: &[PathBuf]) -> Option<Self> {
        candidates.iter().filter(|c| c.is_file()).find_map(|bin| {
            let found = Self { bin: bin.clone() };
            let out = found.run_bounded(&["version"], PROBE_BOUND).ok()?;
            (!String::from_utf8_lossy(&out).trim().is_empty()).then_some(found)
        })
    }

    fn run(&self, args: &[&str]) -> anyhow::Result<Vec<u8>> {
        self.run_bounded(args, CLI_BOUND)
    }

    fn run_bounded(&self, args: &[&str], bound: Duration) -> anyhow::Result<Vec<u8>> {
        let mut child = Command::new(&self.bin)
            .args(args)
            // The macOS app binary (`Tailscale.app/Contents/MacOS/Tailscale`,
            // or a shim to it) acts as the CLI only when started from a
            // terminal or with this set; under launchd it starts the GUI and
            // prints nothing. Other builds ignore it.
            .env("TAILSCALE_BE_CLI", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("cannot run {}", self.bin.display()))?;
        let (Some(mut stdout), Some(mut stderr)) = (child.stdout.take(), child.stderr.take())
        else {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{} started without its output pipes", self.bin.display());
        };
        // Read both pipes while the CLI runs: a large status fills a pipe
        // buffer, and the CLI would block on it forever.
        let out = std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = (&mut stdout).take(MAX_OUTPUT).read_to_end(&mut buf);
            buf
        });
        let err = std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = (&mut stderr).take(64 * 1024).read_to_end(&mut buf);
            buf
        });
        let status = match child.wait_timeout(bound)? {
            Some(status) => status,
            None => {
                let _ = child.kill();
                let _ = child.wait();
                bail!("`tailscale {}` did not answer within {}s", args.join(" "), bound.as_secs());
            }
        };
        let stdout = out.join().unwrap_or_default();
        let stderr = err.join().unwrap_or_default();
        if !status.success() {
            let text = String::from_utf8_lossy(&stderr);
            let line = text
                .lines()
                .filter(|l| !l.starts_with("Warning: client version"))
                .collect::<Vec<_>>()
                .join(" ");
            bail!("`tailscale {}` failed: {}", args.join(" "), line.trim());
        }
        Ok(stdout)
    }

    pub fn status(&self) -> anyhow::Result<Status> {
        let raw = self.run(&["status", "--json"])?;
        parse_status(&raw)
    }

    pub fn whois(&self, ip: IpAddr) -> anyhow::Result<Identity> {
        let raw = self.run(&["whois", "--json", &ip.to_string()])?;
        parse_whois(&raw)
    }
}

fn platform_candidates() -> Vec<PathBuf> {
    if cfg!(target_os = "macos") {
        vec![
            // Standalone CLIs first: the app binary is a CLI only with
            // TAILSCALE_BE_CLI=1, and only while the app is the node.
            PathBuf::from("/usr/local/bin/tailscale"),
            PathBuf::from("/opt/homebrew/bin/tailscale"),
            PathBuf::from("/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
        ]
    } else if cfg!(windows) {
        let mut out = Vec::new();
        for var in ["ProgramFiles", "ProgramW6432"] {
            if let Some(dir) = std::env::var_os(var) {
                out.push(PathBuf::from(dir).join("Tailscale").join("tailscale.exe"));
            }
        }
        out.push(PathBuf::from(r"C:\Program Files\Tailscale\tailscale.exe"));
        out
    } else {
        vec![PathBuf::from("/usr/bin/tailscale"), PathBuf::from("/usr/sbin/tailscale")]
    }
}

fn json(raw: &[u8]) -> anyhow::Result<Value> {
    // The CLI may print a version-skew warning on stderr only; stdout is JSON.
    serde_json::from_slice(raw).context("tailscale printed something that is not JSON")
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| items.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
        .unwrap_or_default()
}

fn ips(value: &Value) -> Vec<IpAddr> {
    strings(value)
        .iter()
        .filter_map(|s| s.split('/').next().and_then(|ip| ip.parse().ok()))
        .collect()
}

fn trim_dot(name: &str) -> String {
    name.trim_end_matches('.').to_owned()
}

fn node(value: &Value, users: &HashMap<u64, String>) -> Node {
    let tags = strings(&value["Tags"]);
    let login = if tags.is_empty() {
        value["UserID"].as_u64().and_then(|id| users.get(&id)).and_then(|l| person(l.as_str()))
    } else {
        None
    };
    Node {
        host_name: value["HostName"].as_str().unwrap_or_default().to_owned(),
        dns_name: trim_dot(value["DNSName"].as_str().unwrap_or_default()),
        os: value["OS"].as_str().unwrap_or_default().to_owned(),
        login,
        tags,
        ips: ips(&value["TailscaleIPs"]),
        online: value["Online"].as_bool().unwrap_or(false),
        shared: value["ShareeNode"].as_bool().unwrap_or(false),
    }
}

pub fn parse_status(raw: &[u8]) -> anyhow::Result<Status> {
    let doc = json(raw)?;
    let mut users = HashMap::new();
    if let Some(map) = doc["User"].as_object() {
        for profile in map.values() {
            if let (Some(id), Some(login)) = (profile["ID"].as_u64(), profile["LoginName"].as_str())
            {
                users.insert(id, login.to_owned());
            }
        }
    }
    let this = node(&doc["Self"], &users);
    let mut peers: Vec<Node> = doc["Peer"]
        .as_object()
        .map(|map| map.values().map(|v| node(v, &users)).collect())
        .unwrap_or_default();
    peers.sort_by(|a, b| a.dns_name.cmp(&b.dns_name));
    Ok(Status {
        backend_state: doc["BackendState"].as_str().unwrap_or_default().to_owned(),
        this,
        peers,
    })
}

pub fn parse_whois(raw: &[u8]) -> anyhow::Result<Identity> {
    let doc = json(raw)?;
    let node = &doc["Node"];
    if node.is_null() {
        return Err(anyhow!("tailscale did not identify the peer"));
    }
    let tags = strings(&node["Tags"]);
    let login = if tags.is_empty() {
        doc["UserProfile"]["LoginName"].as_str().and_then(person)
    } else {
        None
    };
    let shared = node["Sharer"].as_u64().is_some_and(|id| id != 0);
    Ok(Identity { login, node: trim_dot(node["Name"].as_str().unwrap_or_default()), tags, shared })
}

/// A tailnet address: 100.64.0.0/10 or fd7a:115c:a1e0::/48.
pub fn is_tailnet_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            o[0] == 100 && (o[1] & 0xC0) == 64
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

#[cfg(all(test, unix))]
mod cli_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A fake `tailscale` in a fresh folder: `body` is the shell after `#!/bin/sh`.
    fn fake(name: &str, body: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cmux-tailnet-{}-{}-{name}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let bin = dir.join("tailscale");
        std::fs::write(&bin, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        bin
    }

    /// The macOS app binary starts its GUI (and prints nothing) unless
    /// `TAILSCALE_BE_CLI=1`; under launchd nothing else sets it.
    #[test]
    fn every_cli_call_sets_tailscale_be_cli() {
        let bin = fake("becli", r#"[ "$TAILSCALE_BE_CLI" = 1 ] && echo 1.90.0"#);
        let out = Tailnet { bin }.run(&["version"]).unwrap();
        assert_eq!(String::from_utf8_lossy(&out).trim(), "1.90.0");
    }

    /// A candidate that answers `version` with nothing (an app binary that
    /// is not a CLI there) is skipped for the next one.
    #[test]
    fn locate_skips_a_candidate_that_prints_no_version() {
        let silent = fake("silent", "exit 0");
        let good = fake("good", "echo 1.90.0");
        let found = Tailnet::locate_among(&[silent, good.clone()]).unwrap();
        assert_eq!(found.bin, good);
    }

    #[test]
    fn locate_skips_a_candidate_that_fails_or_is_missing() {
        let failing = fake("failing", "exit 1");
        let good = fake("good2", "echo 1.90.0");
        let missing = PathBuf::from("/nonexistent/cmux/tailscale");
        let found = Tailnet::locate_among(&[missing, failing, good.clone()]).unwrap();
        assert_eq!(found.bin, good);
        assert!(Tailnet::locate_among(&[PathBuf::from("/nonexistent/x")]).is_none());
    }
}

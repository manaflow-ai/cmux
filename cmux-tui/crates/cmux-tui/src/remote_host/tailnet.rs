//! The user's tailnet, through the installed `tailscale` CLI (phase 1 of
//! plans/cmux-next/remote-hosts.md 4.1: system tailscaled). The CLI owns
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

/// How long one CLI call may take (status on a large tailnet is the
/// slowest, about 100 ms measured on a 150-peer tailnet).
const CLI_BOUND: Duration = Duration::from_secs(8);
/// Largest CLI output read (a 2,000-peer status is about 4 MiB).
const MAX_OUTPUT: u64 = 32 * 1024 * 1024;

/// One node of the tailnet as `tailscale status --json` reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Node {
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
    pub(crate) fn short_name(&self) -> String {
        self.dns_name
            .split('.')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or(&self.host_name)
            .to_owned()
    }

    pub(crate) fn tagged(&self) -> bool {
        !self.tags.is_empty()
    }

    /// The address a client dials: IPv4 first.
    pub(crate) fn dial_ip(&self) -> Option<IpAddr> {
        self.ips.iter().find(|ip| ip.is_ipv4()).or_else(|| self.ips.first()).copied()
    }
}

#[derive(Clone, Debug)]
pub(crate) struct Status {
    pub backend_state: String,
    pub this: Node,
    pub peers: Vec<Node>,
}

/// Who is at a peer address (`tailscale whois`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Identity {
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
pub(crate) const TAGGED_LOGIN: &str = "tagged-devices";

fn person(login: &str) -> Option<String> {
    let login = login.trim();
    (!login.is_empty() && !login.eq_ignore_ascii_case(TAGGED_LOGIN)).then(|| login.to_owned())
}

pub(crate) struct Tailnet {
    bin: PathBuf,
}

impl Tailnet {
    /// Finds the CLI: `CMUX_TAILSCALE_BIN`, then `PATH`, then each
    /// platform's install location.
    pub(crate) fn locate() -> anyhow::Result<Self> {
        if let Some(bin) = std::env::var_os("CMUX_TAILSCALE_BIN").filter(|v| !v.is_empty()) {
            return Ok(Self { bin: PathBuf::from(bin) });
        }
        let name = if cfg!(windows) { "tailscale.exe" } else { "tailscale" };
        if let Some(paths) = std::env::var_os("PATH") {
            for dir in std::env::split_paths(&paths) {
                let candidate = dir.join(name);
                if candidate.is_file() {
                    return Ok(Self { bin: candidate });
                }
            }
        }
        for candidate in platform_candidates() {
            if candidate.is_file() {
                return Ok(Self { bin: candidate });
            }
        }
        bail!(
            "Tailscale is not installed on this machine (no `tailscale` command found). Install it and sign in, then run this again."
        )
    }

    fn run(&self, args: &[&str]) -> anyhow::Result<Vec<u8>> {
        let mut child = Command::new(&self.bin)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("cannot run {}", self.bin.display()))?;
        let mut stdout = child.stdout.take().expect("piped stdout");
        let mut stderr = child.stderr.take().expect("piped stderr");
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
        let status = match child.wait_timeout(CLI_BOUND)? {
            Some(status) => status,
            None => {
                let _ = child.kill();
                let _ = child.wait();
                bail!(
                    "`tailscale {}` did not answer within {}s",
                    args.join(" "),
                    CLI_BOUND.as_secs()
                );
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

    pub(crate) fn status(&self) -> anyhow::Result<Status> {
        let raw = self.run(&["status", "--json"])?;
        parse_status(&raw)
    }

    pub(crate) fn whois(&self, ip: IpAddr) -> anyhow::Result<Identity> {
        let raw = self.run(&["whois", "--json", &ip.to_string()])?;
        parse_whois(&raw)
    }
}

fn platform_candidates() -> Vec<PathBuf> {
    if cfg!(target_os = "macos") {
        vec![
            PathBuf::from("/Applications/Tailscale.app/Contents/MacOS/Tailscale"),
            PathBuf::from("/opt/homebrew/bin/tailscale"),
            PathBuf::from("/usr/local/bin/tailscale"),
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

pub(crate) fn parse_status(raw: &[u8]) -> anyhow::Result<Status> {
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

pub(crate) fn parse_whois(raw: &[u8]) -> anyhow::Result<Identity> {
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
pub(crate) fn is_tailnet_ip(ip: IpAddr) -> bool {
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

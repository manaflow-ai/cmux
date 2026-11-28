//! One network slot per VM, deny by default.
//!
//! Each VM runs inside its own network namespace `vmd-<slot>` holding an identical `tap0`
//! (172.16.0.1/30, fd00:cafe::1/64) and guest address (172.16.0.2, fd00:cafe::2). A snapshot
//! therefore restores into any slot without re-addressing the guest, so forks need no guest-side
//! work. The namespace reaches the host over a veth pair with a slot-unique /30 (10.201.0.0/16)
//! and /64 (fd01:cafe:<slot>::/64); the namespace source-NATs the guest to its veth address and
//! the host masquerades 10.201.0.0/16 and fd01:cafe::/32 out of its uplink.
//!
//! Policy lives in the host's nftables table `cmux_vmd`: a forward-chain verdict map sends each
//! slot's veth to its own chain; a slot with no chain, and every new connection from a guest to the
//! host itself, is dropped. Inbound connections to guests are dropped (only replies pass).

use std::net::IpAddr;

use anyhow::{Context, Result, bail};
use cmux_process::Command;
use serde::{Deserialize, Serialize};

use crate::cmd;

/// Highest slot number; 10.201.0.0/16 holds 16384 /30s.
pub const MAX_SLOT: u16 = 16383;
pub const GUEST_IP: &str = "172.16.0.2";
pub const GATEWAY_IP: &str = "172.16.0.1";
pub const GUEST_IP6: &str = "fd00:cafe::2";
pub const GATEWAY_IP6: &str = "fd00:cafe::1";
const TABLE: &str = "cmux_vmd";

/// What a guest may reach. The default reaches nothing.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum Egress {
    #[default]
    None,
    /// The public internet: private, link-local, CGNAT/tailnet, loopback, multicast and metadata
    /// ranges stay blocked.
    Internet,
    /// Only these CIDRs (v4 or v6).
    Allow { cidrs: Vec<String> },
}

impl Egress {
    pub fn validate(&self) -> Result<()> {
        if let Egress::Allow { cidrs } = self {
            for c in cidrs {
                parse_cidr(c)?;
            }
        }
        Ok(())
    }
}

fn parse_cidr(c: &str) -> Result<(IpAddr, u8)> {
    let (addr, len) = c.split_once('/').unwrap_or((c, ""));
    let addr: IpAddr = addr.parse().with_context(|| format!("bad CIDR address {c:?}"))?;
    let max = if addr.is_ipv4() { 32 } else { 128 };
    let len: u8 = if len.is_empty() {
        max
    } else {
        len.parse().with_context(|| format!("bad CIDR length {c:?}"))?
    };
    if len > max {
        bail!("CIDR length over {max} in {c:?}");
    }
    Ok((addr, len))
}

/// Names and addresses of one slot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Slot {
    pub n: u16,
}

impl Slot {
    pub fn netns(&self) -> String {
        format!("vmd-{}", self.n)
    }
    pub fn host_if(&self) -> String {
        format!("vmdh{}", self.n)
    }
    pub fn ns_if(&self) -> String {
        format!("vmdg{}", self.n)
    }
    fn v4(&self, host_side: bool) -> String {
        let base = u32::from(self.n) * 4 + if host_side { 1 } else { 2 };
        format!("10.201.{}.{}", base >> 8, base & 0xff)
    }
    pub fn host_ip(&self) -> String {
        self.v4(true)
    }
    pub fn ns_ip(&self) -> String {
        self.v4(false)
    }
    fn v6(&self, host_side: bool) -> String {
        format!("fd01:cafe:{:x}::{}", self.n, if host_side { 1 } else { 2 })
    }
    pub fn host_ip6(&self) -> String {
        self.v6(true)
    }
    pub fn ns_ip6(&self) -> String {
        self.v6(false)
    }
    fn chain(&self) -> String {
        format!("m{}", self.n)
    }
}

/// Kernel command line fragment that addresses the guest (the agent reads the `cmux.*` keys).
pub fn guest_boot_args(dns: &str) -> String {
    format!(
        "ip={GUEST_IP}::{GATEWAY_IP}:255.255.255.252::eth0:off cmux.ip6={GUEST_IP6}/64,{GATEWAY_IP6} cmux.dns={dns}"
    )
}

async fn run(args: &[&str]) -> Result<()> {
    let (program, rest) = args.split_first().context("an empty command")?;
    let mut c = Command::new(program);
    c.args(rest);
    let out = cmd::output(c, None).await.with_context(|| format!("spawn {program}"))?;
    if !out.status.success() {
        bail!("`{}` failed: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

async fn nft(script: &str, netns: Option<&str>) -> Result<()> {
    let mut c = match netns {
        Some(ns) => {
            let mut c = Command::new("ip");
            c.args(["netns", "exec", ns, "nft", "-f", "-"]);
            c
        }
        None => {
            let mut c = Command::new("nft");
            c.args(["-f", "-"]);
            c
        }
    };
    c.stdout(cmux_process::Stdio::null());
    let out = cmd::output(c, Some(script.as_bytes().to_vec())).await.context("spawn nft")?;
    if !out.status.success() {
        bail!("nft failed: {}\n{script}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

/// (Re)create the host table and turn on forwarding. Drops every slot chain; call
/// [`apply_egress`] again for slots that survive a daemon restart.
pub async fn init_host(ipv6: bool) -> Result<()> {
    run(&["sysctl", "-qw", "net.ipv4.ip_forward=1"]).await?;
    if ipv6 {
        // Forwarding turns off router-advertisement intake unless accept_ra is 2.
        run(&[
            "sysctl",
            "-qw",
            "net.ipv6.conf.all.accept_ra=2",
            "net.ipv6.conf.default.accept_ra=2",
        ])
        .await?;
        run(&["sysctl", "-qw", "net.ipv6.conf.all.forwarding=1"]).await?;
    }
    nft(&host_table(), None).await?;
    open_foreign_forward(ipv6).await;
    Ok(())
}

/// A drop in any table is final, so a co-resident firewall whose FORWARD policy is DROP
/// (Docker, ufw, firewalld) silently cuts every guest off even when our egress chain accepts.
/// Accept slot traffic in iptables' FORWARD too; our own `forward` chain still applies each
/// slot's egress verdict, so this widens nothing. Hosts without iptables are skipped.
async fn open_foreign_forward(ipv6: bool) {
    let tools: &[&str] = if ipv6 { &["iptables", "ip6tables"] } else { &["iptables"] };
    for tool in tools {
        for rule in [
            &["-i", "vmdh+", "-j", "ACCEPT"][..],
            &["-o", "vmdh+", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"]
                [..],
        ] {
            let check: Vec<&str> = [*tool, "-w", "-C", "FORWARD"]
                .iter()
                .copied()
                .chain(rule.iter().copied())
                .collect();
            if run(&check).await.is_ok() {
                continue;
            }
            let insert: Vec<&str> = [*tool, "-w", "-I", "FORWARD", "1"]
                .iter()
                .copied()
                .chain(rule.iter().copied())
                .collect();
            if let Err(e) = run(&insert).await {
                eprintln!("cmux-vmd: {tool} FORWARD accept for slots not added: {e:#}");
            }
        }
    }
}

fn host_table() -> String {
    format!(
        r#"add table inet {TABLE}
delete table inet {TABLE}
table inet {TABLE} {{
  map egress {{ type ifname : verdict; }}
  chain forward {{
    type filter hook forward priority 0; policy accept;
    ct state established,related accept
    iifname "vmdh*" iifname vmap @egress
    iifname "vmdh*" drop
    oifname "vmdh*" drop
  }}
  chain input {{
    type filter hook input priority 0; policy accept;
    iifname "vmdh*" ct state established,related accept
    iifname "vmdh*" drop
  }}
  chain postrouting {{
    type nat hook postrouting priority 100; policy accept;
    ip saddr 10.201.0.0/16 oifname != "vmdh*" masquerade
    ip6 saddr fd01:cafe::/32 oifname != "vmdh*" masquerade
  }}
}}
"#
    )
}

const BLOCKED_V4: &str = "0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, \
                          172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4";
/// Besides the private v6 ranges: the prefixes that embed a v4 address (IPv4-compatible `::/96`,
/// NAT64 `64:ff9b::/96` and `64:ff9b:1::/48`, Teredo `2001::/32`, 6to4 `2002::/16`), so a guest
/// cannot reach a blocked v4 range such as metadata (169.254.169.254) through a translator or relay.
const BLOCKED_V6: &str = "::/96, ::ffff:0:0/96, 64:ff9b::/96, 64:ff9b:1::/48, 2001::/32, 2002::/16, \
                          fc00::/7, fe80::/10, ff00::/8";

fn egress_rules(egress: &Egress) -> Result<String> {
    Ok(match egress {
        Egress::None => "drop".to_owned(),
        Egress::Internet => format!(
            "ip daddr {{ {BLOCKED_V4} }} drop\n    ip6 daddr {{ {BLOCKED_V6} }} drop\n    accept"
        ),
        Egress::Allow { cidrs } => {
            let mut v4 = Vec::new();
            let mut v6 = Vec::new();
            for c in cidrs {
                let (addr, len) = parse_cidr(c)?;
                if addr.is_ipv4() { &mut v4 } else { &mut v6 }.push(format!("{addr}/{len}"));
            }
            let mut rules = String::new();
            if !v4.is_empty() {
                rules += &format!("ip daddr {{ {} }} accept\n    ", v4.join(", "));
            }
            if !v6.is_empty() {
                rules += &format!("ip6 daddr {{ {} }} accept\n    ", v6.join(", "));
            }
            rules + "drop"
        }
    })
}

/// Point `slot`'s veth at a chain holding `egress`'s rules (replacing any earlier policy).
pub async fn apply_egress(slot: &Slot, egress: &Egress) -> Result<()> {
    let (chain, ifname) = (slot.chain(), slot.host_if());
    let rules = egress_rules(egress)?;
    nft(
        &format!(
            "add chain inet {TABLE} {chain}\nflush chain inet {TABLE} {chain}\n\
             add rule inet {TABLE} {chain} {rules}\n\
             add element inet {TABLE} egress {{ \"{ifname}\" : jump {chain} }}\n"
        )
        .replace("\n    ", &format!("\nadd rule inet {TABLE} {chain} ")),
        None,
    )
    .await
}

/// Run `script` (one `ip` command per line) in a single `ip -batch` process, inside `netns`
/// when given: two processes build a slot instead of one per command. `force` runs every line
/// past a failing one (cleanup of what may not exist).
async fn ip_batch(script: &str, netns: Option<&str>, force: bool) -> Result<()> {
    let mut c = Command::new("ip");
    if let Some(ns) = netns {
        c.args(["-n", ns]);
    }
    if force {
        c.arg("-force");
    }
    c.args(["-batch", "-"]).stdout(cmux_process::Stdio::null());
    let out = cmd::output(c, Some(script.as_bytes().to_vec())).await.context("spawn ip -batch")?;
    if !out.status.success() {
        bail!("ip -batch failed: {}\n{script}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

/// Build `slot`'s namespace, veth pair, tap0 and NAT, then its egress policy.
pub async fn setup(slot: &Slot, egress: &Egress) -> Result<()> {
    let (ns, hif, nif) = (slot.netns(), slot.host_if(), slot.ns_if());
    let (hip, nip, hip6, nip6) = (slot.host_ip(), slot.ns_ip(), slot.host_ip6(), slot.ns_ip6());
    // A slot left behind by a crash is ours: clear it first.
    let _ = ip_batch(&format!("netns del {ns}\nlink del {hif}\n"), None, true).await;
    let host_side = format!(
        "netns add {ns}\n\
         link add {hif} type veth peer name {nif}\n\
         link set {nif} netns {ns}\n\
         addr add {hip}/30 dev {hif}\n\
         addr add {hip6}/64 dev {hif} nodad\n\
         link set {hif} up\n"
    );
    let ns_side = format!(
        "link set lo up\n\
         addr add {nip}/30 dev {nif}\n\
         addr add {nip6}/64 dev {nif} nodad\n\
         link set {nif} up\n\
         route add default via {hip}\n\
         route add default via {hip6}\n\
         tuntap add dev tap0 mode tap\n\
         addr add {GATEWAY_IP}/30 dev tap0\n\
         addr add {GATEWAY_IP6}/64 dev tap0 nodad\n\
         link set tap0 up\n"
    );
    let ns_nat = format!(
        "table inet vmdns {{\n  chain post {{\n    type nat hook postrouting priority 100; policy accept;\n    \
         oifname \"{nif}\" ip saddr {GUEST_IP} snat ip to {nip}\n    \
         oifname \"{nif}\" ip6 saddr {GUEST_IP6} snat ip6 to {nip6}\n  }}\n}}\n"
    );
    let result = async {
        ip_batch(&host_side, None, false).await?;
        ip_batch(&ns_side, Some(&ns), false).await?;
        // Forwarding inside the namespace, then its NAT, in the one process `ip netns exec` costs.
        let mut c = Command::new("ip");
        c.args(["netns", "exec", &ns, "sh", "-c"])
            .arg("sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 && nft -f -")
            .stdout(cmux_process::Stdio::null());
        let out = cmd::output(c, Some(ns_nat.into_bytes())).await.context("spawn ns setup")?;
        if !out.status.success() {
            bail!(
                "namespace forwarding/NAT failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        apply_egress(slot, egress).await
    }
    .await;
    if let Err(e) = result {
        let _ = teardown(slot).await;
        return Err(e);
    }
    Ok(())
}

/// Remove `slot`'s namespace (which takes the veth pair and tap with it) and its policy.
pub async fn teardown(slot: &Slot) -> Result<()> {
    let (chain, ifname) = (slot.chain(), slot.host_if());
    // Two scripts: nft rolls a whole script back on its first error.
    let _ = nft(&format!("delete element inet {TABLE} egress {{ \"{ifname}\" }}\n"), None).await;
    let _ = nft(&format!("delete chain inet {TABLE} {chain}\n"), None).await;
    let _ = ip_batch(&format!("netns del {}\nlink del {ifname}\n", slot.netns()), None, true).await;
    Ok(())
}

#[cfg(test)]
#[path = "net_tests.rs"]
mod tests;

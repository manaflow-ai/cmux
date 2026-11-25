//! Reads this machine's link with the system's own tools. Every command has
//! a deadline; one that fails or is missing leaves its observation empty and
//! names itself in [`Observations::skipped`].

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::Duration;

use cmux_process::{Command, Stdio};

use crate::{Finding, Medium, Observations, Report, RttSample, parse};

/// What to read, and whether to act.
#[derive(Debug, Clone)]
pub struct ProbeOptions {
    /// Pings to the gateway per run.
    pub pings: u32,
    /// Measure RTT under load: a bulk download and upload while pinging.
    /// Moves tens of MB, so it is opt-in.
    pub load: bool,
    /// The URLs the load step downloads from and uploads to.
    pub load_download_url: String,
    pub load_upload_url: String,
    /// `tailscale ping` these peers (by name). Empty: every online peer that
    /// is not direct.
    pub peers: Vec<String>,
    /// Apply the fixes software can make (today: drive Tailscale to a direct
    /// path by pinging until it upgrades).
    pub fix: bool,
}

impl Default for ProbeOptions {
    fn default() -> Self {
        Self {
            pings: 20,
            load: false,
            load_download_url: "https://speed.cloudflare.com/__down?bytes=100000000".to_owned(),
            load_upload_url: "https://speed.cloudflare.com/__up".to_owned(),
            peers: Vec::new(),
            fix: false,
        }
    }
}

/// Runs `program args` and returns its stdout when it exits 0 before
/// `deadline`. A command past its deadline is killed (it is ours).
pub fn run(program: &str, args: &[&str], deadline: Duration) -> Option<String> {
    run_inner(program, args, deadline, false)
}

/// Like [`run`] but keeps the output of a failed exit too (ping exits 2 on
/// loss and still prints every reply).
fn run_lenient(program: &str, args: &[&str], deadline: Duration) -> Option<String> {
    run_inner(program, args, deadline, true)
}

/// stdout goes to an unlinked scratch file, not a pipe: a child that prints
/// more than a pipe holds (system_profiler's JSON) never blocks on it, and
/// no reader thread is needed. The `Child` is ours: dropped, it is killed.
fn run_inner(program: &str, args: &[&str], deadline: Duration, lenient: bool) -> Option<String> {
    let mut out = scratch_file()?;
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(out.try_clone().ok()?)
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let status = match child.wait_timeout(deadline) {
        Ok(Some(status)) => Some(status),
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    };
    let mut text = String::new();
    out.seek(SeekFrom::Start(0)).ok()?;
    out.read_to_string(&mut text).ok()?;
    match status {
        Some(s) if s.success() || lenient => Some(text),
        None if lenient => Some(text),
        _ => None,
    }
}

/// A read-write file whose name is already gone: it vanishes when closed.
fn scratch_file() -> Option<File> {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("cmux-path-doctor-{}-{n}", std::process::id()));
    let file = OpenOptions::new().read(true).write(true).create_new(true).open(&path).ok()?;
    let _ = std::fs::remove_file(&path);
    Some(file)
}

/// The tailscale CLI: on PATH, or inside the Mac app.
fn tailscale_bin() -> Option<String> {
    let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    if run("tailscale", &["version"], Duration::from_secs(3)).is_some() {
        Some("tailscale".to_owned())
    } else if Path::new(app).exists() {
        Some(app.to_owned())
    } else {
        None
    }
}

/// Reads every observation this OS supports.
pub fn observe(opts: &ProbeOptions) -> Observations {
    let mut obs = Observations {
        host: run("hostname", &[], Duration::from_secs(2))
            .map(|h| h.trim().to_owned())
            .unwrap_or_default(),
        ..Observations::default()
    };
    if cfg!(target_os = "macos") {
        observe_macos(&mut obs);
    } else if cfg!(target_os = "linux") {
        observe_linux(&mut obs);
    } else {
        obs.skipped.push("link: no probe for this OS".to_owned());
    }
    observe_tailscale(&mut obs, opts);
    observe_gateway(&mut obs, opts);
    obs
}

fn observe_macos(obs: &mut Observations) {
    let short = Duration::from_secs(5);
    let (iface, gateway) = run("/sbin/route", &["-n", "get", "default"], short)
        .map(|t| parse::macos_route_default(&t))
        .unwrap_or_default();
    obs.route.interface = iface.clone();
    obs.route.gateway = gateway;
    let ports = run("/usr/sbin/networksetup", &["-listallhardwareports"], short)
        .map(|t| parse::macos_hardware_ports(&t))
        .unwrap_or_default();
    let is_wifi = |name: &str| name == "Wi-Fi" || name == "AirPort";
    let is_wired = |name: &str| {
        name.contains("Ethernet") || name.contains("LAN") || name.contains("Thunderbolt Bridge")
    };
    if let Some(i) = &iface {
        obs.route.medium = Some(match ports.iter().find(|(_, d)| d == i) {
            Some((p, _)) if is_wifi(p) => Medium::Wifi,
            Some((p, _)) if is_wired(p) && !p.contains("Bridge") => Medium::Wired,
            _ if run("/sbin/ifconfig", &[i], short)
                .is_some_and(|t| parse::ifconfig_is_ethernet(&t)) =>
            {
                Medium::Wired
            }
            _ => Medium::Other,
        });
    }
    for (port, dev) in &ports {
        if !is_wired(port) || port.contains("Bridge") || Some(dev) == iface.as_ref() {
            continue;
        }
        if run("/sbin/ifconfig", &[dev], short).and_then(|t| parse::ifconfig_active(&t))
            == Some(true)
        {
            obs.route.idle_wired_with_link.push(format!("{dev} ({port})"));
        }
    }
    match run("/usr/sbin/system_profiler", &["SPAirPortDataType", "-json"], Duration::from_secs(60))
    {
        Some(json) => obs.wifi = parse::macos_system_profiler_wifi(&json),
        None => obs.skipped.push("wifi: system_profiler did not answer".to_owned()),
    }
    obs.awdl_active =
        run("/sbin/ifconfig", &["awdl0"], short).and_then(|t| parse::ifconfig_active(&t));
}

fn observe_linux(obs: &mut Observations) {
    let short = Duration::from_secs(5);
    let (iface, gateway) = run("ip", &["route", "show", "default"], short)
        .map(|t| parse::linux_route_default(&t))
        .unwrap_or_default();
    obs.route.gateway = gateway;
    if let Some(i) = &iface {
        let wireless = Path::new(&format!("/sys/class/net/{i}/wireless")).exists();
        obs.route.medium = Some(if wireless { Medium::Wifi } else { Medium::Wired });
        if wireless {
            match run("iw", &["dev", i, "link"], short) {
                Some(t) => obs.wifi = parse::linux_iw_link(i, &t),
                None => obs.skipped.push("wifi: iw did not answer".to_owned()),
            }
        }
    }
    obs.route.interface = iface;
}

fn observe_tailscale(obs: &mut Observations, opts: &ProbeOptions) {
    let Some(bin) = tailscale_bin() else {
        obs.skipped.push("tailscale: no CLI".to_owned());
        return;
    };
    let Some(json) = run(&bin, &["status", "--json"], Duration::from_secs(8)) else {
        obs.skipped.push("tailscale: status did not answer".to_owned());
        return;
    };
    obs.tailscale_peers = parse::tailscale_status(&json);
    for peer in obs.tailscale_peers.iter_mut() {
        let wanted = if opts.peers.is_empty() {
            peer.online && !peer.is_direct()
        } else {
            opts.peers.iter().any(|p| p == &peer.name)
        };
        if !wanted {
            continue;
        }
        // One ping reads the path; with --fix, up to 10 drive the upgrade:
        // `tailscale ping` stops at the first direct pong.
        let count = if opts.fix { "10" } else { "1" };
        let target = peer.address.clone().unwrap_or_else(|| peer.name.clone());
        let args = ["ping", "--c", count, "--timeout", "3s", target.as_str()];
        if let Some((direct, derp, ms)) = run_lenient(&bin, &args, Duration::from_secs(40))
            .and_then(|t| parse::tailscale_ping(&t))
        {
            peer.direct_addr = direct;
            peer.derp_region =
                derp.or(peer.derp_region.take().filter(|_| peer.direct_addr.is_none()));
            peer.ping_ms = Some(ms);
        }
    }
}

fn ping(target: &str, count: u32) -> Option<RttSample> {
    let count = count.to_string();
    let deadline = Duration::from_secs(5 + u64::from(count.parse::<u32>().unwrap_or(20)) / 4);
    let text = run_lenient("ping", &["-c", &count, "-i", "0.2", target], deadline)?;
    let sample = parse::ping_output(&text);
    (sample.sent > 0).then_some(sample)
}

fn observe_gateway(obs: &mut Observations, opts: &ProbeOptions) {
    let Some(gw) = obs.route.gateway.clone() else {
        obs.skipped.push("gateway: no default route".to_owned());
        return;
    };
    obs.gateway_idle = ping(&gw, opts.pings);
    if obs.gateway_idle.is_none() {
        obs.skipped.push(format!("gateway: ping {gw} did not answer"));
        return;
    }
    if !opts.load {
        return;
    }
    // Saturate both directions, give the queues a second to fill, then ping.
    let spawn = |args: &[&str]| {
        Command::new("curl")
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok()
    };
    let down = spawn(&["-s", "-m", "20", "-o", "/dev/null", &opts.load_download_url]);
    let up = spawn(&[
        "-s",
        "-m",
        "20",
        "-o",
        "/dev/null",
        "--data-binary",
        "@/dev/zero",
        &opts.load_upload_url,
    ]);
    thread::sleep(Duration::from_millis(1500));
    obs.gateway_loaded = ping(&gw, opts.pings);
    // Dropping our `Child` handles ends the load.
    drop((down, up));
    if obs.gateway_loaded.is_none() {
        obs.skipped.push("gateway: no answer under load".to_owned());
    }
}

/// Reads the link and diagnoses it; with `fix`, marks what the probe fixed.
pub fn examine(opts: &ProbeOptions) -> Report {
    let mut report = Report::new(observe(opts));
    if opts.fix {
        mark_fixed(&mut report);
    }
    report
}

const RELAYED_NAMED: usize = 3;

/// After a `--fix` run every peer the probe moved to direct reads as direct,
/// so it has no finding left; say so on the ok line instead of silently.
fn mark_fixed(report: &mut Report) {
    let fixed: Vec<String> = report
        .observations
        .tailscale_peers
        .iter()
        .filter(|p| p.is_direct() && p.ping_ms.is_some())
        .map(|p| p.name.clone())
        .collect();
    if !fixed.is_empty() {
        report.findings.push(Finding {
            severity: crate::Severity::Info,
            code: "tailscale_direct_now".to_owned(),
            line: if fixed.len() > RELAYED_NAMED {
                format!(
                    "Tailscale is direct to {} peers, e.g. {}",
                    fixed.len(),
                    fixed[..RELAYED_NAMED].join(", ")
                )
            } else {
                format!("Tailscale is direct to {}", fixed.join(", "))
            },
            fixed: Some("drove the path to direct with tailscale ping".to_owned()),
        });
    }
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;

    #[test]
    fn run_returns_output_and_kills_past_the_deadline() {
        assert_eq!(run("echo", &["hi"], Duration::from_secs(5)).as_deref(), Some("hi\n"));
        let start = Instant::now();
        assert_eq!(run("sleep", &["30"], Duration::from_millis(200)), None);
        assert!(start.elapsed() < Duration::from_secs(5));
        assert_eq!(run("false", &[], Duration::from_secs(5)), None);
        assert_eq!(
            run_lenient("sh", &["-c", "echo x; exit 2"], Duration::from_secs(5)).as_deref(),
            Some("x\n")
        );
        assert_eq!(run("/nonexistent/tool", &[], Duration::from_secs(1)), None);
    }
}

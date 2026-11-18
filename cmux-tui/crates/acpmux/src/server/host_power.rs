//! This machine's power and network for `_acpmux/host_health` (`peer_status.rs`): `power`
//! `{batteryPercent, onAc, lidClosed}` and `network` `{up}`, which Auto chat placement reads
//! (`design/auto-chat-placement.md`: a closed lid takes this Mac out, a low battery counts as
//! over load, a network that is down keeps the chat here).
//!
//! Leo, 2026-11-18: "esp with our auto routing logic. say like... an auto mode as an umbrella
//! over remote/local/cloud itself. so it just goes."
//!
//! - macOS: `pmset -g batt` (AC or battery, the internal battery's percent) and
//!   `ioreg -r -k AppleClamshellState -d 1` (the lid; a Mac without one has no such key). Each
//!   runs with a [`COMMAND_LIMIT`] and the reading is kept [`CACHE_FOR`], so a health ask spawns
//!   at most two short processes every 5 s and a hung one costs its limit once per 5 s.
//! - Linux: `/sys/class/power_supply` (a `Battery` that is not a peripheral's, `Mains`/`USB`
//!   online) and `/proc/acpi/button/lid/*/state`. A machine with no battery has no `power`.
//! - `network.up`: whether the kernel has a route off this machine (a UDP `connect`, which sends
//!   no packet), IPv4 or IPv6. `cmux-netwatch` says when the network changed, not whether it is up.
//!
//! **Debug override** for tests and demos (simulate a closed lid with no hardware): the
//! `ACPMUX_POWER_ASSUME` environment variable (inline JSON), else the file
//! `<acpmux home>/power-assume.json` (`~/.acpmux/power-assume.json`), for example
//! `{"lidClosed": true, "until": 1795000000000}`. Its keys `batteryPercent`, `onAc`, `lidClosed`
//! and `networkUp` replace the reading; `until` (ms since the epoch) ends it, and without it the
//! override holds until the file is removed. An overridden object says `"assumed": true`, so no
//! reader mistakes it for the hardware. It is read on every ask, so a demo's change shows at once.

use serde_json::{Value, json};
#[cfg(any(target_os = "linux", test))]
use std::path::Path;
use std::time::{Duration, Instant};

/// How long one reading is kept before the next ask reads again.
const CACHE_FOR: Duration = Duration::from_secs(5);

/// How long each macOS command may run before it is killed and its part reads null.
// timeout: pmset and ioreg answer in milliseconds; one stuck on a busy IOKit must not hold a
// health ask, which peers make with a 5 s deadline.
#[cfg(target_os = "macos")]
const COMMAND_LIMIT: Duration = Duration::from_millis(750);

/// The environment variable that holds an override inline (module docs).
pub(crate) const ASSUME_ENV: &str = "ACPMUX_POWER_ASSUME";

/// The override file's name in acpmux's home (module docs).
pub(crate) const ASSUME_FILE: &str = "power-assume.json";

/// One power reading; each part is `None` when this machine cannot say.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Power {
    pub battery_percent: Option<u8>,
    pub on_ac: Option<bool>,
    pub lid_closed: Option<bool>,
}

/// A debug override (module docs); each present key replaces the reading's.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Assume {
    pub battery_percent: Option<u8>,
    pub on_ac: Option<bool>,
    pub lid_closed: Option<bool>,
    pub network_up: Option<bool>,
}

impl Assume {
    fn touches_power(&self) -> bool {
        self.battery_percent.is_some() || self.on_ac.is_some() || self.lid_closed.is_some()
    }
}

/// The override in `text` as of `now_ms`: `None` when it is not a JSON object, names none of the
/// keys, or its `until` has passed.
pub(crate) fn parse_assume(text: &str, now_ms: u64) -> Option<Assume> {
    let v: Value = serde_json::from_str(text).ok()?;
    let o = v.as_object()?;
    if let Some(until) = o.get("until").and_then(Value::as_u64)
        && until <= now_ms
    {
        return None;
    }
    let percent =
        o.get("batteryPercent").and_then(Value::as_f64).map(|p| p.round().clamp(0.0, 100.0) as u8);
    let a = Assume {
        battery_percent: percent,
        on_ac: o.get("onAc").and_then(Value::as_bool),
        lid_closed: o.get("lidClosed").and_then(Value::as_bool),
        network_up: o.get("networkUp").and_then(Value::as_bool),
    };
    (a != Assume::default()).then_some(a)
}

/// The override in force now: [`ASSUME_ENV`], else [`ASSUME_FILE`] in acpmux's home.
pub(crate) fn assumed(now_ms: u64) -> Option<Assume> {
    if let Ok(text) = std::env::var(ASSUME_ENV) {
        return parse_assume(&text, now_ms);
    }
    let text = std::fs::read_to_string(crate::config::home().join(ASSUME_FILE)).ok()?;
    parse_assume(&text, now_ms)
}

/// `power` of `host_health`: the reading with `assume` over it, or `None` (omitted) when this
/// machine reads nothing and nothing is assumed.
pub(crate) fn power_json(reading: Option<Power>, assume: Option<&Assume>) -> Option<Value> {
    let assume = assume.filter(|a| a.touches_power());
    if reading.is_none() && assume.is_none() {
        return None;
    }
    let mut p = reading.unwrap_or_default();
    if let Some(a) = assume {
        p.battery_percent = a.battery_percent.or(p.battery_percent);
        p.on_ac = a.on_ac.or(p.on_ac);
        p.lid_closed = a.lid_closed.or(p.lid_closed);
    }
    let mut v = serde_json::Map::new();
    v.insert("batteryPercent".into(), json!(p.battery_percent));
    v.insert("onAc".into(), json!(p.on_ac));
    v.insert("lidClosed".into(), json!(p.lid_closed));
    if assume.is_some() {
        v.insert("assumed".into(), json!(true));
    }
    Some(Value::Object(v))
}

/// `network` of `host_health`: `{up}`, with `assume`'s `networkUp` over the reading.
pub(crate) fn network_json(up: bool, assume: Option<&Assume>) -> Value {
    match assume.and_then(|a| a.network_up) {
        Some(up) => json!({"up": up, "assumed": true}),
        None => json!({"up": up}),
    }
}

/// Whether the kernel has a route off this machine. A UDP `connect` picks the route and sends
/// nothing; with no route it fails (`ENETUNREACH`). The targets are documentation addresses
/// (RFC 5737, RFC 3849), which no network serves, so they ride the default route.
pub(crate) fn network_up() -> bool {
    fn routes(bind: &str, to: &str) -> bool {
        let Ok(s) = std::net::UdpSocket::bind(bind) else { return false };
        s.connect(to).is_ok()
            && s.local_addr().is_ok_and(|a| !a.ip().is_loopback() && !a.ip().is_unspecified())
    }
    routes("0.0.0.0:0", "192.0.2.1:9") || routes("[::]:0", "[2001:db8::1]:9")
}

/// `pmset -g batt`: whether the Mac draws from AC (`Now drawing from 'AC Power'`), and its
/// internal battery's percent (none on a Mac without one; a UPS line is not the battery).
#[cfg(any(target_os = "macos", test))]
pub(crate) fn parse_pmset_batt(text: &str) -> (Option<u8>, Option<bool>) {
    let on_ac = text.lines().find_map(|l| {
        let source = l.split_once("drawing from '")?.1.split('\'').next()?;
        Some(source == "AC Power")
    });
    let percent = text.lines().filter(|l| l.contains("InternalBattery")).find_map(|l| {
        let before = l.split('%').next()?;
        let digits: String = before
            .chars()
            .rev()
            .take_while(char::is_ascii_digit)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        digits.parse::<u8>().ok().filter(|p| *p <= 100)
    });
    (percent, on_ac)
}

/// `ioreg -r -k AppleClamshellState -d 1`: the lid's state (`"AppleClamshellState" = Yes` is
/// closed); none when the key is absent (a Mac with no lid prints nothing).
#[cfg(any(target_os = "macos", test))]
pub(crate) fn parse_clamshell(text: &str) -> Option<bool> {
    text.lines().find_map(|l| {
        let rest = l.trim().strip_prefix("\"AppleClamshellState\"")?;
        match rest.trim().strip_prefix('=')?.trim() {
            "Yes" => Some(true),
            "No" => Some(false),
            _ => None,
        }
    })
}

/// `/proc/acpi/button/lid/*/state`: `state:      closed` or `open`.
#[cfg(any(target_os = "linux", test))]
pub(crate) fn parse_lid_state(text: &str) -> Option<bool> {
    match text.trim().strip_prefix("state:")?.trim() {
        "closed" => Some(true),
        "open" => Some(false),
        _ => None,
    }
}

/// The Linux reading from a `power_supply` folder (`/sys/class/power_supply`) and an ACPI lid
/// folder (`/proc/acpi/button/lid`): `None` when no system battery is present.
#[cfg(any(target_os = "linux", test))]
pub(crate) fn read_linux(supply: &Path, lid: &Path) -> Option<Power> {
    let read = |p: &Path| std::fs::read_to_string(p).ok().map(|s| s.trim().to_owned());
    let mut percents = Vec::new();
    let mut mains_online: Option<bool> = None;
    let mut charging: Option<bool> = None;
    for entry in std::fs::read_dir(supply).ok()?.flatten() {
        let dir = entry.path();
        match read(&dir.join("type")).as_deref() {
            Some("Battery") => {
                // A mouse's or a keyboard's battery says scope Device; not this machine's.
                if read(&dir.join("scope")).as_deref() == Some("Device")
                    || read(&dir.join("present")).as_deref() == Some("0")
                {
                    continue;
                }
                if let Some(p) = read(&dir.join("capacity")).and_then(|c| c.parse::<u8>().ok()) {
                    percents.push(p.min(100));
                }
                if let Some(status) = read(&dir.join("status")) {
                    charging = Some(charging.unwrap_or(false) || status != "Discharging");
                }
            }
            Some("Mains" | "USB") => {
                if let Some(online) = read(&dir.join("online")) {
                    mains_online = Some(mains_online.unwrap_or(false) || online == "1");
                }
            }
            _ => {}
        }
    }
    if percents.is_empty() && charging.is_none() {
        return None;
    }
    let battery_percent = (!percents.is_empty()).then(|| {
        (percents.iter().map(|p| u32::from(*p)).sum::<u32>() / percents.len() as u32) as u8
    });
    let lid_closed = std::fs::read_dir(lid)
        .ok()
        .and_then(|d| d.flatten().find_map(|e| parse_lid_state(&read(&e.path().join("state"))?)));
    Some(Power { battery_percent, on_ac: mains_online.or(charging), lid_closed })
}

/// `program args` with its stdout, or `None` when it fails to start, exits unsuccessfully, or
/// runs past `limit` (it is then killed and reaped).
#[cfg(any(target_os = "macos", test))]
pub(crate) fn run_bounded(program: &str, args: &[&str], limit: Duration) -> Option<String> {
    use std::io::{Read as _, Seek as _};
    // Its stdout goes to an unnamed file, not a pipe: a pipe that fills up (ioreg prints the
    // root domain's every property) would hold the child until the wait below gave up.
    let mut out = tempfile::tempfile().ok()?;
    let mut child = cmux_process::Command::new(program)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(out.try_clone().ok()?)
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()?;
    match child.wait_timeout(limit) {
        Ok(Some(status)) if status.success() => {}
        Ok(Some(_)) => return None,
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
    }
    out.rewind().ok()?;
    let mut text = String::new();
    out.read_to_string(&mut text).ok()?;
    Some(text)
}

/// One reading now, on a blocking thread (spawned commands, sysfs reads that ask the ACPI
/// controller).
#[cfg(target_os = "macos")]
fn read_now() -> Option<Power> {
    let (battery_percent, on_ac) = run_bounded("/usr/bin/pmset", &["-g", "batt"], COMMAND_LIMIT)
        .map(|t| parse_pmset_batt(&t))
        .unwrap_or_default();
    let lid_closed = run_bounded(
        "/usr/sbin/ioreg",
        &["-r", "-k", "AppleClamshellState", "-d", "1"],
        COMMAND_LIMIT,
    )
    .and_then(|t| parse_clamshell(&t));
    let p = Power { battery_percent, on_ac, lid_closed };
    (p != Power::default()).then_some(p)
}

#[cfg(target_os = "linux")]
fn read_now() -> Option<Power> {
    read_linux(Path::new("/sys/class/power_supply"), Path::new("/proc/acpi/button/lid"))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn read_now() -> Option<Power> {
    None
}

static CACHE: tokio::sync::Mutex<Option<(Instant, Option<Power>)>> =
    tokio::sync::Mutex::const_new(None);

/// This machine's power, read at most once per [`CACHE_FOR`]; concurrent asks share one read.
pub(crate) async fn power() -> Option<Power> {
    let mut cached = CACHE.lock().await;
    if let Some((at, p)) = *cached
        && at.elapsed() < CACHE_FOR
    {
        return p;
    }
    let p = tokio::task::spawn_blocking(read_now).await.ok().flatten();
    *cached = Some((Instant::now(), p));
    p
}

#[cfg(test)]
#[path = "host_power_tests.rs"]
mod tests;

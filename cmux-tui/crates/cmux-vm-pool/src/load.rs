//! Measured load per pool machine: placement by load, not by fixed slots (Leo via the coordinator: keep placing
//! work on a VM while its CPU and RAM are under 90%, grow when work waits and every VM is at 90% or more,
//! pause a VM under about 20% for a while; never delete).
//!
//! Two sources, by machine name:
//! - the build controller's pool telemetry (`GET {load_url}` -> `{"vms": {NAME: {cpu_percent, mem_total_bytes,
//!   mem_used_bytes, sampled_at}}}`, the fields of hq `build-fleet/internal/telemetry`), which every pool VM posts;
//! - GCE Cloud Monitoring's `compute.googleapis.com/instance/cpu/utilization` for GCE pool VMs (CPU only), which
//!   needs nothing on the guest.

use std::collections::HashMap;

use reqwest::Method;
use serde_json::{Value, json};

use crate::http::{self, Result};

/// One machine's load, in percent.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Load {
    pub cpu_pct: f64,
    /// `None` when the source has no memory (Cloud Monitoring without the ops agent).
    pub mem_pct: Option<f64>,
}

impl Load {
    /// At or over the admission line on CPU or RAM: no more work fits.
    pub fn full(&self, line_pct: f64) -> bool {
        self.cpu_pct >= line_pct || self.mem_pct.is_some_and(|m| m >= line_pct)
    }

    /// Under the quiet line on CPU (and RAM, when known).
    pub fn quiet(&self, line_pct: f64) -> bool {
        self.cpu_pct < line_pct && self.mem_pct.is_none_or(|m| m < line_pct)
    }
}

/// Loads from the controller's pool telemetry body, leaving out samples older than `max_age_s` at `now_s` (a
/// VM that stopped posting must not stay "full" or "quiet" on its last word). A sample with no `sampled_at`
/// counts as fresh.
pub fn parse_controller(body: &Value, now_s: i64, max_age_s: i64) -> HashMap<String, Load> {
    let Some(vms) = body.get("vms").and_then(Value::as_object) else {
        return HashMap::new();
    };
    vms.iter()
        .filter_map(|(name, t)| {
            if t.get("ok").and_then(Value::as_bool) == Some(false) {
                return None;
            }
            if let Some(at) = t.get("sampled_at").and_then(Value::as_str).and_then(parse_rfc3339)
                && now_s.saturating_sub(at) > max_age_s
            {
                return None;
            }
            let cpu_pct = t.get("cpu_percent")?.as_f64()?;
            let total = t.get("mem_total_bytes").and_then(Value::as_f64).filter(|&v| v > 0.0);
            let used = t.get("mem_used_bytes").and_then(Value::as_f64);
            let mem_pct = total.zip(used).map(|(total, used)| used / total * 100.0);
            Some((name.clone(), Load { cpu_pct, mem_pct }))
        })
        .collect()
}

/// Loads from a Cloud Monitoring `timeSeries` list (`ALIGN_MEAN`, newest point first; utilization is 0..1).
pub fn parse_monitoring(body: &Value) -> HashMap<String, Load> {
    let Some(series) = body.get("timeSeries").and_then(Value::as_array) else {
        return HashMap::new();
    };
    series
        .iter()
        .filter_map(|s| {
            let name = s.get("metric")?.get("labels")?.get("instance_name")?.as_str()?;
            let value =
                s.get("points")?.as_array()?.first()?.get("value")?.get("doubleValue")?.as_f64()?;
            Some((name.to_owned(), Load { cpu_pct: value * 100.0, mem_pct: None }))
        })
        .collect()
}

/// GCE CPU utilization of the pool's instances over the last `window_s`, one mean per instance.
pub async fn gce_cpu(
    client: &reqwest::Client,
    token: &str,
    project: &str,
    label: &str,
    window_s: u64,
) -> Result<HashMap<String, Load>> {
    let now = std::time::SystemTime::now();
    let start = now.checked_sub(std::time::Duration::from_secs(window_s)).unwrap_or(now);
    let filter = format!(
        "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND metadata.user_labels.purpose=\"{label}\""
    );
    let enc = |s: &str| url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>();
    let url = format!(
        "https://monitoring.googleapis.com/v3/projects/{project}/timeSeries?filter={}&interval.startTime={}&interval.endTime={}&aggregation.alignmentPeriod={window_s}s&aggregation.perSeriesAligner=ALIGN_MEAN",
        enc(&filter),
        enc(&rfc3339(start)),
        enc(&rfc3339(now)),
    );
    let mut loads = HashMap::new();
    let mut page: Option<String> = None;
    loop {
        let paged = match &page {
            Some(token) => format!("{url}&pageToken={}", enc(token)),
            None => url.clone(),
        };
        let body = http::call(client, Method::GET, &paged, token, &[], None).await?;
        loads.extend(parse_monitoring(&body));
        page = body
            .get("nextPageToken")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
            .map(str::to_owned);
        if page.is_none() {
            return Ok(loads);
        }
    }
}

/// A controller sample older than this is left out (the guest posts every 15 s).
pub const CONTROLLER_MAX_AGE_S: i64 = 90;

/// Loads from the controller (`GET load_url`).
pub async fn controller(
    client: &reqwest::Client,
    load_url: &str,
) -> std::result::Result<HashMap<String, Load>, String> {
    let body: Value = client
        .get(load_url)
        .send()
        .await
        .map_err(|e| format!("{load_url}: {e}"))?
        .json()
        .await
        .map_err(|e| format!("{load_url}: {e}"))?;
    let now_s = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
    Ok(parse_controller(&body, now_s, CONTROLLER_MAX_AGE_S))
}

/// p50 and p90 of the machines' CPU, and how many were measured.
pub fn summary(loads: &HashMap<String, Load>) -> Value {
    let mut cpu: Vec<f64> = loads.values().map(|l| l.cpu_pct).collect();
    cpu.sort_by(f64::total_cmp);
    let pct = |p: f64| -> Option<f64> {
        if cpu.is_empty() {
            return None;
        }
        let i = ((cpu.len() - 1) as f64 * p).round() as usize;
        cpu.get(i).map(|v| (v * 10.0).round() / 10.0)
    };
    let full = loads.values().filter(|l| l.full(90.0)).count();
    let quiet = loads.values().filter(|l| l.quiet(20.0)).count();
    json!({"measured": cpu.len(), "cpu_p50": pct(0.5), "cpu_p90": pct(0.9), "at_or_over_90": full, "under_20": quiet})
}

/// Seconds since the Unix epoch of an RFC 3339 time (`2026-11-20T11:26:40.5Z`, `...+01:00`), as Go's
/// `time.Time` writes `sampled_at`. `None` when it does not parse.
pub fn parse_rfc3339(text: &str) -> Option<i64> {
    let num = |s: &str| -> Option<i64> {
        (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok()).flatten()
    };
    let (date, rest) = text.split_once(['T', 't', ' '])?;
    let mut ymd = date.split('-');
    let (y, mo, d) = (num(ymd.next()?)?, num(ymd.next()?)?, num(ymd.next()?)?);
    if ymd.next().is_some() || !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    let (clock, offset_s) = if let Some(clock) = rest.strip_suffix(['Z', 'z']) {
        (clock, 0)
    } else {
        let at = rest.rfind(['+', '-'])?;
        let (clock, zone) = rest.split_at(at);
        let sign = if zone.starts_with('-') { -1 } else { 1 };
        let (zh, zm) = zone.get(1..)?.split_once(':')?;
        (clock, sign * (num(zh)? * 3600 + num(zm)? * 60))
    };
    let clock = clock.split_once('.').map_or(clock, |(whole, _)| whole);
    let mut hms = clock.split(':');
    let (h, mi, s) = (num(hms.next()?)?, num(hms.next()?)?, num(hms.next()?)?);
    if hms.next().is_some() {
        return None;
    }
    // Days from civil (Howard Hinnant's algorithm).
    let y = if mo <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + h * 3600 + mi * 60 + s - offset_s)
}
/// RFC 3339 UTC with seconds (`2026-11-20T11:40:00Z`), from the Unix clock.
fn rfc3339(at: std::time::SystemTime) -> String {
    let secs = at.duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, rem % 3600 / 60, rem % 60);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(mo <= 2);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339_formats_known_instants() {
        let at = |s: u64| std::time::UNIX_EPOCH + std::time::Duration::from_secs(s);
        assert_eq!(rfc3339(at(0)), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(at(1_795_174_000)), "2026-11-20T11:26:40Z");
        assert_eq!(rfc3339(at(951_782_400)), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn rfc3339_parses_back_what_it_writes_and_go_offsets() {
        for secs in [0_u64, 951_782_400, 1_795_174_000, 4_102_444_800] {
            let at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs);
            assert_eq!(parse_rfc3339(&rfc3339(at)), Some(secs as i64));
        }
        assert_eq!(parse_rfc3339("2026-11-20T12:26:40.5+01:00"), Some(1_795_174_000));
        assert_eq!(parse_rfc3339("2026-11-20T03:26:40-08:00"), Some(1_795_174_000));
        assert_eq!(parse_rfc3339("2026-13-20T03:26:40Z"), None);
        assert_eq!(parse_rfc3339("yesterday"), None);
    }
    #[test]
    fn controller_and_monitoring_bodies_parse() {
        let body = json!({"vms": {
            "fsp-a": {"ok": true, "cpu_percent": 95.0, "mem_total_bytes": 100.0, "mem_used_bytes": 40.0},
            "fsp-b": {"ok": false, "cpu_percent": 1.0},
            "fsp-c": {"cpu_percent": 10.0, "sampled_at": "2026-11-20T11:26:30.123456789Z"},
            "fsp-d": {"cpu_percent": 99.0, "sampled_at": "2026-11-20T11:20:00Z"}
        }});
        // At 11:26:40Z with a 90 s limit: fsp-d (6 min 40 s old) is left out, fsp-c (10 s) stays.
        let loads = parse_controller(&body, 1_795_174_000, 90);
        assert_eq!(loads.len(), 2);
        assert_eq!(loads["fsp-a"], Load { cpu_pct: 95.0, mem_pct: Some(40.0) });
        assert!(loads["fsp-a"].full(90.0) && !loads["fsp-a"].quiet(20.0));
        assert!(loads["fsp-c"].quiet(20.0));
        let series = json!({"timeSeries": [
            {"metric": {"labels": {"instance_name": "cmux-runner-pool-w1a-0001"}}, "points": [{"value": {"doubleValue": 0.42}}]}
        ]});
        let loads = parse_monitoring(&series);
        assert!((loads["cmux-runner-pool-w1a-0001"].cpu_pct - 42.0).abs() < 1e-9);
    }

    #[test]
    fn summary_gives_p50_and_the_lines() {
        let loads: HashMap<String, Load> = [10.0, 20.0, 50.0, 95.0]
            .iter()
            .enumerate()
            .map(|(i, &c)| (format!("m{i}"), Load { cpu_pct: c, mem_pct: None }))
            .collect();
        let s = summary(&loads);
        assert_eq!(s["measured"], 4);
        assert_eq!(s["cpu_p50"], 50.0);
        assert_eq!(s["at_or_over_90"], 1);
        assert_eq!(s["under_20"], 1);
    }
}

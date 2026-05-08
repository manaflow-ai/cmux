use std::collections::{HashMap, HashSet};
use std::time::Duration;

use anyhow::{Result, bail};

use crate::remote_ssh_relay::{RemoteSshRelayConfig, run_remote_shell_script};

pub(crate) fn normalize_tty_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let candidate = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if candidate.is_empty() {
        return None;
    }
    candidate
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        .then(|| candidate.to_string())
}

pub(crate) async fn scan_ports_by_tty(
    config: &RemoteSshRelayConfig,
    tty_names: Vec<String>,
    excluded_ports: HashSet<u16>,
) -> Result<HashMap<String, Vec<u16>>> {
    let tty_names = tty_names
        .into_iter()
        .filter_map(|tty| normalize_tty_name(&tty))
        .collect::<HashSet<_>>();
    if tty_names.is_empty() {
        return Ok(HashMap::new());
    }
    let mut tty_names = tty_names.into_iter().collect::<Vec<_>>();
    tty_names.sort();
    let script = remote_port_scan_script(&tty_names, &excluded_ports);
    let output = run_remote_shell_script(config, &script, Duration::from_secs(8)).await?;
    if !output.status.success() {
        let detail = best_error_line(&output.stderr, &output.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", output.status));
        bail!("remote port scan failed: {detail}");
    }
    Ok(parse_remote_tty_port_pairs(
        &String::from_utf8_lossy(&output.stdout),
        &tty_names,
    ))
}

pub(crate) async fn scan_host_ports(
    config: &RemoteSshRelayConfig,
    excluded_ports: HashSet<u16>,
) -> Result<Vec<u16>> {
    let script = remote_all_ports_scan_script(&excluded_ports);
    let output = run_remote_shell_script(config, &script, Duration::from_secs(8)).await?;
    if !output.status.success() {
        let detail = best_error_line(&output.stderr, &output.stdout)
            .unwrap_or_else(|| format!("ssh exited {}", output.status));
        bail!("remote host port scan failed: {detail}");
    }
    Ok(parse_remote_ports(&String::from_utf8_lossy(&output.stdout)))
}

fn parse_remote_tty_port_pairs(
    output: &str,
    tracked_tty_names: &[String],
) -> HashMap<String, Vec<u16>> {
    let tracked = tracked_tty_names.iter().cloned().collect::<HashSet<_>>();
    let mut ports_by_tty = tracked_tty_names
        .iter()
        .map(|tty| (tty.clone(), HashSet::<u16>::new()))
        .collect::<HashMap<_, _>>();
    for line in output.lines() {
        let mut parts = line.split('\t');
        let Some(tty_name) = parts.next().map(str::trim) else {
            continue;
        };
        let Some(port) = parts.next().map(str::trim) else {
            continue;
        };
        if parts.next().is_some() || !tracked.contains(tty_name) {
            continue;
        }
        let Some(port) = port
            .parse::<u16>()
            .ok()
            .filter(|port| (1024..=65535).contains(port))
        else {
            continue;
        };
        ports_by_tty
            .entry(tty_name.to_string())
            .or_default()
            .insert(port);
    }
    ports_by_tty
        .into_iter()
        .map(|(tty, ports)| {
            let mut ports = ports.into_iter().collect::<Vec<_>>();
            ports.sort_unstable();
            (tty, ports)
        })
        .collect()
}

fn remote_port_scan_script(tty_names: &[String], excluded_ports: &HashSet<u16>) -> String {
    let tty_set = tty_names.join(" ");
    let tty_csv = tty_names.join(",");
    let mut excluded_ports = excluded_ports.iter().copied().collect::<Vec<_>>();
    excluded_ports.sort_unstable();
    let excluded_ports = excluded_ports
        .into_iter()
        .map(|port| port.to_string())
        .collect::<Vec<_>>()
        .join(" ");

    format!(
        r#"set -eu
cmux_tracked_ttys=" {tty_set} "
cmux_tty_csv='{tty_csv}'
cmux_excluded_ports=" {excluded_ports} "

cmux_emit_port() {{
  cmux_tty="$1"
  cmux_port="$2"
  case "$cmux_tracked_ttys" in
    *" $cmux_tty "*) ;;
    *) return 0 ;;
  esac
  case "$cmux_excluded_ports" in
    *" $cmux_port "*) return 0 ;;
  esac
  [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
  printf '%s\t%s\n' "$cmux_tty" "$cmux_port"
}}

cmux_used_ss=0
if [ -d /proc ] && command -v ss >/dev/null 2>&1; then
  cmux_ss_output="$(ss -ltnpH 2>/dev/null || true)"
  case "$cmux_ss_output" in
    *pid=*)
      cmux_used_ss=1
      printf '%s\n' "$cmux_ss_output" | while IFS= read -r cmux_line; do
        [ -n "$cmux_line" ] || continue
        cmux_port="$(printf '%s\n' "$cmux_line" | awk '{{print $4}}' | sed -E 's/.*:([0-9]+)$/\1/' | awk '/^[0-9]+$/ {{ print $1; exit }}')"
        [ -n "$cmux_port" ] || continue
        printf '%s\n' "$cmux_line" | awk '
          {{
            line = $0
            while (match(line, /pid=[0-9]+/)) {{
              print substr(line, RSTART + 4, RLENGTH - 4)
              line = substr(line, RSTART + RLENGTH)
            }}
          }}
        ' | while IFS= read -r cmux_pid; do
          [ -n "$cmux_pid" ] || continue
          cmux_tty_path="$(readlink "/proc/$cmux_pid/fd/0" 2>/dev/null || true)"
          [ -n "$cmux_tty_path" ] || continue
          cmux_tty="${{cmux_tty_path##*/}}"
          [ -n "$cmux_tty" ] || continue
          cmux_emit_port "$cmux_tty" "$cmux_port"
        done
      done
      ;;
  esac
fi

if [ "$cmux_used_ss" -eq 0 ] && command -v lsof >/dev/null 2>&1 && [ -n "$cmux_tty_csv" ]; then
  cmux_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cmux-ports)"
  trap 'rm -rf "$cmux_tmpdir"' EXIT INT TERM
  cmux_pid_tty_map="$cmux_tmpdir/pid_tty"
  ps -t "$cmux_tty_csv" -o pid=,tty= 2>/dev/null | awk '
    NF >= 2 {{
      tty = $2
      sub(/^.*\//, "", tty)
      print $1 "\t" tty
    }}
  ' > "$cmux_pid_tty_map"
  [ -s "$cmux_pid_tty_map" ] || exit 0
  cmux_pid_csv="$(awk '{{print $1}}' "$cmux_pid_tty_map" | paste -sd, -)"
  [ -n "$cmux_pid_csv" ] || exit 0
  lsof -nP -a -p "$cmux_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | awk -v map="$cmux_pid_tty_map" '
    BEGIN {{
      while ((getline < map) > 0) {{
        pid_to_tty[$1] = $2
      }}
      close(map)
    }}
    $0 ~ /^p/ {{
      pid = substr($0, 2)
      tty = pid_to_tty[pid]
      next
    }}
    $0 ~ /^n/ && tty != "" {{
      name = substr($0, 2)
      sub(/->.*/, "", name)
      sub(/^.*:/, "", name)
      sub(/[^0-9].*/, "", name)
      if (name != "") {{
        print tty "\t" name
      }}
    }}
  ' | while IFS="$(printf '\t')" read -r cmux_tty cmux_port; do
    [ -n "$cmux_tty" ] || continue
    [ -n "$cmux_port" ] || continue
    cmux_emit_port "$cmux_tty" "$cmux_port"
  done
fi"#
    )
}

fn remote_all_ports_scan_script(excluded_ports: &HashSet<u16>) -> String {
    let mut excluded_ports = excluded_ports.iter().copied().collect::<Vec<_>>();
    excluded_ports.sort_unstable();
    let excluded_ports = excluded_ports
        .into_iter()
        .map(|port| port.to_string())
        .collect::<Vec<_>>()
        .join(" ");

    format!(
        r#"set -eu
cmux_excluded_ports=" {excluded_ports} "

cmux_emit_port() {{
  cmux_port="$1"
  case "$cmux_excluded_ports" in
    *" $cmux_port "*) return 0 ;;
  esac
  [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
  printf '%s\n' "$cmux_port"
}}

if command -v ss >/dev/null 2>&1; then
  ss -ltnH 2>/dev/null | awk '{{print $4}}' | sed -E 's/.*:([0-9]+)$/\1/' | awk '/^[0-9]+$/ {{print $1}}' | while IFS= read -r cmux_port; do
    [ -n "$cmux_port" ] || continue
    cmux_emit_port "$cmux_port"
  done
elif command -v netstat >/dev/null 2>&1; then
  netstat -lnt 2>/dev/null | awk 'NR > 2 {{print $4}}' | sed -E 's/.*:([0-9]+)$/\1/' | awk '/^[0-9]+$/ {{print $1}}' | while IFS= read -r cmux_port; do
    [ -n "$cmux_port" ] || continue
    cmux_emit_port "$cmux_port"
  done
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {{print $9}}' | sed -E 's/.*:([0-9]+)$/\1/' | awk '/^[0-9]+$/ {{print $1}}' | while IFS= read -r cmux_port; do
    [ -n "$cmux_port" ] || continue
    cmux_emit_port "$cmux_port"
  done
fi"#
    )
}

fn parse_remote_ports(output: &str) -> Vec<u16> {
    let mut ports = output
        .split_whitespace()
        .filter_map(|value| value.parse::<u16>().ok())
        .filter(|port| (1024..=65535).contains(port))
        .collect::<Vec<_>>();
    ports.sort_unstable();
    ports.dedup();
    ports
}

fn best_error_line(stderr: &[u8], stdout: &[u8]) -> Option<String> {
    meaningful_error_line(stderr).or_else(|| meaningful_error_line(stdout))
}

fn meaningful_error_line(data: &[u8]) -> Option<String> {
    String::from_utf8_lossy(data)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .rev()
        .find(|line| {
            let lower = line.to_ascii_lowercase();
            !lower.contains("warning:") && !lower.contains("debug:")
        })
        .map(str::to_string)
}

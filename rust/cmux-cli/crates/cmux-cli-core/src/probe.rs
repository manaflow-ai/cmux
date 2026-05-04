//! Opt-in runtime probes for debugging cmx live sessions.
//!
//! Probes are intentionally file-backed and disabled by default. The server is
//! usually spawned with stderr redirected to `/dev/null`, and the client runs
//! in an alternate screen, so regular stderr logging is not useful here.

use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

static START: OnceLock<Instant> = OnceLock::new();
static TRACE_PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
static SEQ: AtomicU64 = AtomicU64::new(1);

#[must_use]
pub fn enabled() -> bool {
    trace_path().is_some()
}

#[must_use]
pub fn color_enabled() -> bool {
    enabled()
        && (flag_enabled("CMX_TRACE_COLOR")
            || matches!(
                std::env::var("CMX_TRACE").ok().as_deref(),
                Some("color" | "colors" | "all")
            ))
}

#[must_use]
pub fn verbose_enabled() -> bool {
    enabled()
        && (flag_enabled("CMX_TRACE_VERBOSE")
            || matches!(std::env::var("CMX_TRACE").ok().as_deref(), Some("all")))
}

#[must_use]
pub fn mono_ms() -> u64 {
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

pub fn log_event(component: &str, name: &str, fields: &[(&str, String)]) {
    let Some(path) = trace_path() else {
        return;
    };
    let mut line = String::new();
    line.push('{');
    push_num(&mut line, "seq", SEQ.fetch_add(1, Ordering::Relaxed));
    push_num(&mut line, "pid", std::process::id() as u64);
    push_num(&mut line, "ts_ms", unix_ms());
    push_num(&mut line, "mono_ms", mono_ms());
    push_str(&mut line, "component", component);
    push_str(&mut line, "event", name);
    for (key, value) in fields {
        push_str(&mut line, key, value);
    }
    line.push_str("}\n");

    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(line.as_bytes());
    }
}

#[must_use]
pub fn terminal_bytes_summary(data: &[u8]) -> String {
    let sgr = extract_sgr_sequences(data, 16).join(" ");
    let sgr_palette = extract_sgr_palette_summary(data);
    let osc = extract_osc_prefixes(data, 8).join(" ");
    format!(
        "len={} alt_screen={} sgr={} sgr_palette={} osc={} preview={}",
        data.len(),
        contains_alt_screen(data),
        if sgr.is_empty() { "-" } else { sgr.as_str() },
        sgr_palette,
        if osc.is_empty() { "-" } else { osc.as_str() },
        preview_bytes(data, 160),
    )
}

#[must_use]
pub fn has_terminal_color_sequences(data: &[u8]) -> bool {
    contains_sgr(data) || contains_osc_palette(data)
}

#[must_use]
pub fn contains_ascii_case_insensitive(data: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || data.len() < needle.len() {
        return false;
    }
    data.windows(needle.len()).any(|window| {
        window
            .iter()
            .zip(needle)
            .all(|(a, b)| a.eq_ignore_ascii_case(b))
    })
}

#[must_use]
pub fn preview_bytes(data: &[u8], limit: usize) -> String {
    let mut out = String::new();
    for &b in data.iter().take(limit) {
        match b {
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            0x1b => out.push_str("\\x1b"),
            0x20..=0x7e => out.push(b as char),
            _ => out.push_str(&format!("\\x{b:02x}")),
        }
    }
    if data.len() > limit {
        out.push_str("...");
    }
    out
}

#[must_use]
pub fn contains_alt_screen(data: &[u8]) -> bool {
    data.windows(b"\x1b[?1049h".len())
        .any(|w| w == b"\x1b[?1049h")
        || data.windows(b"\x1b[?47h".len()).any(|w| w == b"\x1b[?47h")
        || data
            .windows(b"\x1b[?1047h".len())
            .any(|w| w == b"\x1b[?1047h")
}

fn trace_path() -> Option<&'static Path> {
    TRACE_PATH.get_or_init(resolve_trace_path).as_deref()
}

fn resolve_trace_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("CMX_TRACE_PATH")
        && !path.trim().is_empty()
    {
        return Some(PathBuf::from(path));
    }
    if trace_value_enables_path(std::env::var("CMX_TRACE").ok().as_deref()) {
        return Some(std::env::temp_dir().join("cmx-trace.jsonl"));
    }
    None
}

fn trace_value_enables_path(value: Option<&str>) -> bool {
    matches!(
        value,
        Some("1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON" | "color" | "colors" | "all")
    )
}

fn flag_enabled(name: &str) -> bool {
    matches!(
        std::env::var(name).ok().as_deref(),
        Some("1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON")
    )
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn push_num(line: &mut String, key: &str, value: u64) {
    if line.len() > 1 {
        line.push(',');
    }
    line.push('"');
    line.push_str(&escape_json(key));
    line.push_str("\":");
    line.push_str(&value.to_string());
}

fn push_str(line: &mut String, key: &str, value: &str) {
    if line.len() > 1 {
        line.push(',');
    }
    line.push('"');
    line.push_str(&escape_json(key));
    line.push_str("\":\"");
    line.push_str(&escape_json(value));
    line.push('"');
}

fn escape_json(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

fn contains_sgr(data: &[u8]) -> bool {
    !extract_sgr_sequences(data, 1).is_empty()
}

fn contains_osc_palette(data: &[u8]) -> bool {
    data.windows(3).any(|w| w == b"\x1b]4" || w == b"\x1b]1")
}

fn extract_sgr_sequences(data: &[u8], limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 2 < data.len() && out.len() < limit {
        if data[i] != 0x1b || data[i + 1] != b'[' {
            i += 1;
            continue;
        }
        let start = i;
        i += 2;
        while i < data.len() && i.saturating_sub(start) < 64 {
            if data[i] == b'm' {
                out.push(preview_bytes(&data[start..=i], 80));
                break;
            }
            if (0x40..=0x7e).contains(&data[i]) && data[i] != b'm' {
                break;
            }
            i += 1;
        }
        i = i.saturating_add(1);
    }
    out
}

fn extract_sgr_palette_summary(data: &[u8]) -> String {
    let mut fg = BTreeMap::<u16, usize>::new();
    let mut bg = BTreeMap::<u16, usize>::new();
    let mut i = 0;
    while i + 2 < data.len() {
        if data[i] != 0x1b || data[i + 1] != b'[' {
            i += 1;
            continue;
        }
        let params_start = i + 2;
        i += 2;
        while i < data.len() && i.saturating_sub(params_start) < 64 {
            if data[i] == b'm' {
                record_sgr_palette_params(&data[params_start..i], &mut fg, &mut bg);
                break;
            }
            if (0x40..=0x7e).contains(&data[i]) && data[i] != b'm' {
                break;
            }
            i += 1;
        }
        i = i.saturating_add(1);
    }
    format!("fg={} bg={}", palette_counts(&fg), palette_counts(&bg))
}

fn record_sgr_palette_params(
    params: &[u8],
    fg: &mut BTreeMap<u16, usize>,
    bg: &mut BTreeMap<u16, usize>,
) {
    let Ok(params) = std::str::from_utf8(params) else {
        return;
    };
    let values = params
        .split(';')
        .map(|part| {
            if part.is_empty() {
                Some(0)
            } else {
                part.parse::<u16>().ok()
            }
        })
        .collect::<Option<Vec<_>>>();
    let Some(values) = values else {
        return;
    };
    let mut i = 0;
    while i + 2 < values.len() {
        match values[i..=i + 2] {
            [38, 5, index] => {
                *fg.entry(index).or_default() += 1;
                i += 3;
            }
            [48, 5, index] => {
                *bg.entry(index).or_default() += 1;
                i += 3;
            }
            _ => i += 1,
        }
    }
}

fn palette_counts(counts: &BTreeMap<u16, usize>) -> String {
    if counts.is_empty() {
        return "-".into();
    }
    counts
        .iter()
        .map(|(index, count)| format!("{index}:{count}"))
        .collect::<Vec<_>>()
        .join(",")
}

fn extract_osc_prefixes(data: &[u8], limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 2 < data.len() && out.len() < limit {
        if data[i] != 0x1b || data[i + 1] != b']' {
            i += 1;
            continue;
        }
        let start = i;
        i += 2;
        while i < data.len() && i.saturating_sub(start) < 96 {
            if data[i] == 0x07 {
                out.push(preview_bytes(&data[start..=i], 96));
                break;
            }
            if i + 1 < data.len() && data[i] == 0x1b && data[i + 1] == b'\\' {
                out.push(preview_bytes(&data[start..=i + 1], 96));
                break;
            }
            i += 1;
        }
        i = i.saturating_add(1);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{
        contains_alt_screen, extract_sgr_palette_summary, extract_sgr_sequences, preview_bytes,
        terminal_bytes_summary, trace_value_enables_path,
    };

    #[test]
    fn extracts_sgr_sequences() {
        let seqs = extract_sgr_sequences(b"a\x1b[38;5;135mp\x1b[0m", 8);
        assert_eq!(seqs, vec!["\\x1b[38;5;135m", "\\x1b[0m"]);
    }

    #[test]
    fn summarizes_sgr_palette_indices() {
        let bytes = b"\x1b[38;5;135mlawrence\x1b[48;5;236m \x1b[38;5;118m~";

        assert_eq!(
            extract_sgr_palette_summary(bytes),
            "fg=118:1,135:1 bg=236:1"
        );
        assert!(terminal_bytes_summary(bytes).contains("sgr_palette=fg=118:1,135:1 bg=236:1"));
    }

    #[test]
    fn preview_escapes_control_bytes() {
        assert_eq!(preview_bytes(b"\x1b[31m\r\n", 32), "\\x1b[31m\\r\\n");
    }

    #[test]
    fn detects_alt_screen_entry() {
        assert!(contains_alt_screen(b"\x1b[?1049h"));
    }

    #[test]
    fn trace_modes_enable_default_trace_path() {
        assert!(trace_value_enables_path(Some("color")));
        assert!(trace_value_enables_path(Some("colors")));
        assert!(trace_value_enables_path(Some("all")));
        assert!(trace_value_enables_path(Some("1")));
        assert!(!trace_value_enables_path(Some("0")));
        assert!(!trace_value_enables_path(None));
    }
}

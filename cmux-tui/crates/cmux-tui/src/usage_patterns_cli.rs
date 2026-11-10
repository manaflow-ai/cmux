//! `cmux usage-patterns [show|reset] [--json] [--top N]`: the person's own opt-in usage
//! patterns (cmux-usage-patterns), read from this machine's files. No daemon is asked and
//! nothing leaves the machine. Counting is off until `diagnostics.usagePatterns` is on.

use cmux_usage_patterns::{Readout, Rollup};
use std::fmt::Write as _;

/// The scope word.
pub(crate) const SCOPE: &str = "usage-patterns";

const HELP: &str = "\
cmux usage-patterns - your own usage patterns on this machine (opt-in)

USAGE
  cmux usage-patterns [show] [--json] [--top N]   What was counted, merged over every daemon
  cmux usage-patterns reset                      Delete what was counted so far
  cmux usage-patterns on|off                     Print the command that turns counting on or off

Counting is off until you turn it on (Settings > Privacy and Security > Usage Patterns, or
`cmux settings set diagnostics.usagePatterns true`). It records counts and times of day:
which commands and operations ran, which way panes were split, connections and client kinds,
agent chats started per harness, prompts, tokens and distinct paired machines. Never prompts,
terminal text, addresses, file paths or names. Nothing is sent anywhere.
";

/// Whether `raw_args` asks for this scope.
pub(crate) fn requested(raw_args: &[String]) -> bool {
    raw_args.first().map(String::as_str) == Some(SCOPE)
}

/// Runs the scope with the words after it; returns the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    let mut json = false;
    let mut top = 10usize;
    let mut verb: Option<&str> = None;
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--json" => json = true,
            "--top" => match words.next().and_then(|n| n.parse().ok()) {
                Some(n) => top = n,
                None => return usage_error("--top takes a number"),
            },
            "-h" | "--help" | "help" => {
                print!("{HELP}");
                return 0;
            }
            word if verb.is_none() && matches!(word, "show" | "reset" | "on" | "off") => {
                verb = Some(word)
            }
            other => return usage_error(&format!("unknown argument {other:?}")),
        }
    }
    match verb.unwrap_or("show") {
        "reset" => reset(json),
        "on" => toggle(true),
        "off" => toggle(false),
        _ => show(json, top),
    }
}

fn usage_error(message: &str) -> i32 {
    eprintln!("cmux usage-patterns: {message}\n\n{HELP}");
    2
}

fn show(json: bool, top: usize) -> i32 {
    let readout = cmux_usage_patterns::read();
    if json {
        match serde_json::to_string_pretty(&readout) {
            Ok(text) => println!("{text}"),
            Err(error) => {
                eprintln!("cmux usage-patterns: {error}");
                return 1;
            }
        }
        return 0;
    }
    print!("{}", render(&readout, top));
    0
}

fn reset(json: bool) -> i32 {
    let Some(dir) = cmux_usage_patterns::default_dir() else {
        eprintln!("cmux usage-patterns: no state directory on this machine");
        return 1;
    };
    match cmux_usage_patterns::reset_dir(&dir) {
        Ok(removed) => {
            if json {
                println!("{}", serde_json::json!({"ok": true, "removed": removed}));
            } else {
                println!(
                    "Deleted {removed} usage pattern file(s). Running daemons start again from zero."
                );
            }
            0
        }
        Err(error) => {
            eprintln!("cmux usage-patterns: {error}");
            1
        }
    }
}

/// `on` / `off`: the setting lives in the app's settings owner, so this names the one command
/// that writes it (`cmux settings set`), the same path the Settings page and palette take.
fn toggle(on: bool) -> i32 {
    let value = if on { "true" } else { "false" };
    println!("cmux settings set {} {value}", cmux_usage_patterns::SETTING_KEY);
    eprintln!("Run the line above (or use Settings > Privacy and Security > Usage Patterns).");
    0
}

/// The plain-text readout.
pub(crate) fn render(readout: &Readout, top: usize) -> String {
    let mut out = String::new();
    let state = if readout.enabled { "on" } else { "off" };
    let _ = writeln!(
        out,
        "Usage patterns: counting is {state} ({}).",
        cmux_usage_patterns::SETTING_KEY
    );
    let rollup = &readout.rollup;
    if rollup.is_empty() {
        let _ = writeln!(
            out,
            "Nothing counted yet.{}",
            if readout.enabled {
                ""
            } else {
                " Turn it on with `cmux settings set diagnostics.usagePatterns true`."
            }
        );
        return out;
    }
    let days = rollup.days.len();
    let total: u64 = rollup.hours.iter().sum();
    let _ = writeln!(
        out,
        "{total} events over {days} active day(s), from {} writer(s).\n",
        readout.writers.len()
    );
    for (title, family) in SECTIONS {
        section(&mut out, title, rollup, family, top);
    }
    for (family, _) in &rollup.counts {
        if !SECTIONS.iter().any(|(_, known)| known == family) {
            section(&mut out, family, rollup, family, top);
        }
    }
    if !rollup.peaks.is_empty() {
        let _ = writeln!(out, "Peaks");
        for (name, value) in &rollup.peaks {
            let _ = writeln!(out, "  {value:>10}  {name}");
        }
        out.push('\n');
    }
    if let Some((hour, _)) = rollup.hours.iter().enumerate().max_by_key(|(_, n)| **n) {
        let _ = writeln!(out, "Busiest hour (UTC): {hour:02}:00");
    }
    out
}

/// Families in the order the readout shows them.
const SECTIONS: &[(&str, &str)] = &[
    ("Agent chats started, by harness", "agent-chat"),
    ("Agent prompts, by harness", "agent-prompt"),
    ("Tokens", "tokens"),
    ("Distinct paired machines", "machine"),
    ("Agent service connections", "acpmux-connection"),
    ("Agent service methods", "acpmux-method"),
    ("Layouts", "layout"),
    ("Commands", "command"),
    ("Operations", "operation"),
    ("Connections", "connection"),
    ("Clients", "client"),
];

fn section(out: &mut String, title: &str, rollup: &Rollup, family: &str, top: usize) {
    let Some(keys) = rollup.counts.get(family) else {
        return;
    };
    let mut rows: Vec<(&String, &u64)> = keys.iter().collect();
    rows.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
    let total: u64 = keys.values().sum();
    let _ = writeln!(out, "{title} ({} distinct, {total} total)", keys.len());
    for (key, n) in rows.into_iter().take(top) {
        let _ = writeln!(out, "  {n:>10}  {key}");
    }
    out.push('\n');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_readout_names_counts_never_more() {
        let mut rollup = Rollup::default();
        rollup.add("command", "new-tab", 3, 1_000);
        rollup.add("layout", "split-right", 2, 1_000);
        rollup.add("agent-chat", "claude", 1, 1_000);
        rollup.peak("connections.open", 4, 1_000);
        let readout = Readout { enabled: true, rollup, ..Readout::default() };
        let text = render(&readout, 10);
        assert!(text.contains("counting is on"));
        assert!(text.contains("Commands (1 distinct, 3 total)"));
        assert!(text.contains("split-right"));
        assert!(text.contains("Agent chats started, by harness"));
        assert!(text.contains("connections.open"));
    }

    #[test]
    fn an_empty_readout_says_how_to_turn_it_on() {
        let text = render(&Readout::default(), 10);
        assert!(text.contains("counting is off"));
        assert!(text.contains("cmux settings set diagnostics.usagePatterns true"));
    }
}

//! `cmux usage insights`: efficiency insights computed on this machine from the person's own
//! agent records; nothing is uploaded (acpmux `usage_insights.rs`). The first insight is cache
//! waste by cause: why each cache-write token was paid and what would have avoided it.
//!
//! Leo, 2026-11-25: "there are likely actually good tools for analysis and tracking we can have
//! as opt-in for stuff to have people like... have apis to analyze their own stuff,
//! potentially...?" The same report is the MCP tool `usage_insights` (mcp/usage_insights_tool.rs).

use serde_json::json;

use super::{GlobalArgs, OutputMode};

pub(super) const USAGE: &str = "\
cmux usage insights [--hours N] [--json]

Efficiency insights from this machine's own agent records (Claude Code transcripts),
computed here; nothing leaves the machine.

  cache waste   each cache-write token by cause (append, session or helper start,
                idle wake, compaction, model switch, shape change, lost under ttl,
                prefix edit), the share a warm cache would have avoided, its cost
                at list price, and the fix for each cause

Options:
  --hours N     the window, in hours back from now (default 24, at most 720)
  --json        the report as JSON (also the MCP tool usage_insights)
";

pub(super) const DEFAULT_HOURS: u64 = 24;

/// `insights`' words after `insights`: the window in hours.
pub(super) fn parse_hours(args: &[String]) -> Result<u64, String> {
    let mut hours = DEFAULT_HOURS;
    let mut words = args.iter();
    while let Some(word) = words.next() {
        let value = match word.as_str() {
            "--hours" => words.next().ok_or("--hours needs a number of hours")?.as_str(),
            other => match other.strip_prefix("--hours=") {
                Some(value) => value,
                None => return Err(format!("unknown argument `{other}`")),
            },
        };
        hours = value
            .parse::<u64>()
            .ok()
            .filter(|hours| (1..=acpmux::usage_insights::MAX_HOURS).contains(hours))
            .ok_or_else(|| {
                format!(
                    "--hours must be a whole number from 1 to {}",
                    acpmux::usage_insights::MAX_HOURS
                )
            })?;
    }
    Ok(hours)
}

/// The cache-waste report for this machine, `hours` back from now.
pub(super) fn cache_waste(hours: u64) -> acpmux::usage_insights::CacheWaste {
    let homes = acpmux::usage_insights::claude_homes();
    acpmux::usage_insights::cache_waste(&homes, hours, acpmux::store::now_ms())
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let (scope, rest) = words.split_first()?;
    if scope != "usage" {
        return None;
    }
    let asks_help = rest.iter().any(|word| matches!(word.as_str(), "-h" | "--help"));
    let Some((verb, after)) = rest.split_first().filter(|(verb, _)| *verb != "help" && !asks_help)
    else {
        print!("{USAGE}");
        return Some(0);
    };
    if verb != "insights" {
        let message = format!("unknown usage verb `{verb}`; run `cmux usage --help`");
        return Some(failure(&global, &message));
    }
    if global.machine.is_some() {
        return Some(failure(&global, "--machine: insights read this machine's own records"));
    }
    let hours = match parse_hours(after) {
        Ok(hours) => hours,
        Err(message) => return Some(failure(&global, &message)),
    };
    let report = cache_waste(hours);
    Some(match global.output {
        OutputMode::Json | OutputMode::JsonLines => {
            let value = json!({"insights": [report]});
            super::wire::print_local_success(&value, global.output)
        }
        OutputMode::Quiet => 0,
        OutputMode::Human => {
            print!("{}", acpmux::usage_insights::render(&report));
            0
        }
    })
}

fn failure(global: &GlobalArgs, message: &str) -> i32 {
    let message = match global.output {
        OutputMode::Quiet | OutputMode::Human => format!("cmux usage: {message}"),
        _ => message.to_owned(),
    };
    super::wire::print_local_error(
        &json!({"code": "usage.invalid", "message": message, "details": {}, "retryable": false}),
        global.output,
        2,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|word| (*word).to_owned()).collect()
    }

    #[test]
    fn hours_default_parse_and_refuse_out_of_range() {
        assert_eq!(parse_hours(&[]), Ok(DEFAULT_HOURS));
        assert_eq!(parse_hours(&words(&["--hours", "6"])), Ok(6));
        assert_eq!(parse_hours(&words(&["--hours=48"])), Ok(48));
        assert!(parse_hours(&words(&["--hours", "0"])).is_err());
        assert!(parse_hours(&words(&["--hours", "721"])).is_err());
        assert!(parse_hours(&words(&["--hours"])).is_err());
        assert!(parse_hours(&words(&["--days", "2"])).is_err());
    }

    #[test]
    fn other_scopes_pass_through() {
        assert_eq!(run_if_requested(&words(&["video", "open", "x.mp4"])), None);
        assert_eq!(run_if_requested(&words(&[])), None);
    }
}

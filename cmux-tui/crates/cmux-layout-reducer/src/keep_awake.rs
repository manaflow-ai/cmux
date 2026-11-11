//! Which terminal commands on this Mac keep it awake (`sessions.keepAwakeForCommands`), and when
//! the app must look again.
//!
//! Pure: the app sends one [`Command`] per local tab whose shell runs a command (the daemon's
//! OSC 133 `busy` fact), with times on its own clock, and holds off idle system sleep while
//! [`Plan::running`] is above zero. It reaches this through `cmux_layout_reducer_json`
//! (`keep_awake_plan`) when the setting is on; taking and dropping the hold stays in the app.
//!
//! A command counts once it has run [`COMMAND_AFTER_MS`] and while it printed within
//! [`QUIET_MS`]: a build or a test run keeps the Mac up, an editor or an ssh session left open
//! with nothing printing stops holding it ten minutes after its last output. An agent's terminal
//! never counts here: the agent CLI is one long command, and its turns hold the Mac on their own.

use serde::{Deserialize, Serialize};

/// A command counts only after it has run this long (ms). Idle sleep waits at least a minute
/// after the person's last input, so a command they typed cannot be cut off sooner, and the hold
/// is not taken and dropped for every short command.
pub const COMMAND_AFTER_MS: u64 = 60_000;

/// A running command stops counting this long after it last printed (ms).
pub const QUIET_MS: u64 = 10 * 60_000;

/// One local tab whose shell runs a command. Times are ms since 1970 on the app's clock.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Command {
    /// When the command started.
    pub since_ms: u64,
    /// When the terminal last printed; absent when it has not since it opened.
    pub output_ms: Option<u64>,
    /// An agent runs in the tab (its hooks report, or it is an agent chat).
    pub agent: bool,
    /// The tab is a terminal on this Mac (not a browser, not another machine's terminal).
    pub terminal: bool,
}

/// What the app sends.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    pub now_ms: u64,
    pub commands: Vec<Command>,
}

/// What the app performs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    /// Commands that keep the Mac awake now.
    pub running: u32,
    /// Indices of commands that went quiet: the app watches their output, which makes them count
    /// again.
    pub quiet: Vec<usize>,
    /// When to send the tabs again (ms from now): a young command comes of age, or a counting one
    /// goes quiet. Absent when nothing changes with time alone.
    pub recheck_ms: Option<u64>,
}

/// The plan for `request`.
pub fn plan(request: &Request) -> Plan {
    let now = request.now_ms;
    let mut out = Plan::default();
    for (index, command) in request.commands.iter().enumerate() {
        if command.agent || !command.terminal {
            continue;
        }
        let started = command.since_ms.min(now);
        let age = now - started;
        let due = if age < COMMAND_AFTER_MS {
            COMMAND_AFTER_MS - age
        } else {
            // Output from before the command started is the prompt's, not the command's.
            let printed = command.output_ms.map_or(started, |at| at.clamp(started, now));
            let silent = now - printed;
            if silent >= QUIET_MS {
                out.quiet.push(index);
                continue;
            }
            out.running += 1;
            QUIET_MS - silent
        };
        out.recheck_ms = Some(out.recheck_ms.map_or(due, |next| next.min(due)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000_000;

    fn command(age_ms: u64, silent_ms: Option<u64>) -> Command {
        Command {
            since_ms: NOW - age_ms,
            output_ms: silent_ms.map(|s| NOW - s),
            agent: false,
            terminal: true,
        }
    }

    fn plan_of(commands: Vec<Command>) -> Plan {
        plan(&Request { now_ms: NOW, commands })
    }

    #[test]
    fn a_young_command_does_not_count_and_is_looked_at_when_it_comes_of_age() {
        let plan = plan_of(vec![command(20_000, Some(1_000))]);
        assert_eq!(plan, Plan { running: 0, quiet: vec![], recheck_ms: Some(40_000) });
    }

    #[test]
    fn a_printing_command_past_a_minute_counts_until_it_goes_quiet() {
        let plan = plan_of(vec![command(5 * 60_000, Some(2_000))]);
        assert_eq!(plan, Plan { running: 1, quiet: vec![], recheck_ms: Some(QUIET_MS - 2_000) });
    }

    #[test]
    fn a_command_quiet_for_ten_minutes_stops_counting_and_is_watched() {
        let plan =
            plan_of(vec![command(60 * 60_000, Some(QUIET_MS)), command(2 * 60_000, Some(0))]);
        assert_eq!(plan, Plan { running: 1, quiet: vec![0], recheck_ms: Some(QUIET_MS) });
    }

    #[test]
    fn output_from_before_the_command_counts_from_its_start() {
        // The prompt printed an hour ago; the command started two minutes ago and has not printed.
        let plan = plan_of(vec![command(2 * 60_000, Some(60 * 60_000))]);
        assert_eq!(plan.running, 1);
        assert_eq!(plan.recheck_ms, Some(QUIET_MS - 2 * 60_000));
        let silent = plan_of(vec![command(2 * 60_000, None)]);
        assert_eq!(silent.running, 1);
    }

    #[test]
    fn agent_tabs_and_other_tabs_never_count() {
        let agent = Command { agent: true, ..command(5 * 60_000, Some(0)) };
        let remote = Command { terminal: false, ..command(5 * 60_000, Some(0)) };
        assert_eq!(plan_of(vec![agent, remote]), Plan::default());
    }

    #[test]
    fn a_start_ahead_of_the_clock_is_young() {
        let ahead =
            Command { since_ms: NOW + 5_000, output_ms: None, agent: false, terminal: true };
        assert_eq!(plan_of(vec![ahead]).recheck_ms, Some(COMMAND_AFTER_MS));
    }

    #[test]
    fn no_command_needs_no_recheck() {
        assert_eq!(plan_of(vec![]), Plan::default());
    }

    #[test]
    fn the_earliest_deadline_wins() {
        let plan = plan_of(vec![command(5 * 60_000, Some(0)), command(59_000, None)]);
        assert_eq!(plan, Plan { running: 1, quiet: vec![], recheck_ms: Some(1_000) });
    }
}

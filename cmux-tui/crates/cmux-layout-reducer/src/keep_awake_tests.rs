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
    let plan = plan_of(vec![command(60 * 60_000, Some(QUIET_MS)), command(2 * 60_000, Some(0))]);
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
    let ahead = Command { since_ms: NOW + 5_000, output_ms: None, agent: false, terminal: true };
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

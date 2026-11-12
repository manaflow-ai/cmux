//! A spare-ready event (Leo, Cloud V0 item 1: "harness login attached in advance"). The platform tells the
//! person's App on its Cloud wire when their spare became ready (`cloud.spare.ready`, refill done or warm held);
//! the App asks here with `ready: M`, and the copy onto M is answered once, before any claim. A repeat event, a
//! claim's copy, a warm's copy or an installed receipt all coalesce: no second copy onto the same machine.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{COPY_BUDGET_MS, Copying, Record, State};

/// `ready: M` (under the lock) for `account` in `team`. No copy when one is already covered: a receipt for M (an
/// installed login within its life, kept trimmed by the caller), a copy onto M in flight (or a warm still waiting
/// on the platform, whose machine is not known yet), or a record of M whose copy was given (a warm's, a claim's,
/// an earlier event's; it lives [`COPY_BUDGET_MS`] for an event's own). Otherwise the copy is registered in flight
/// and answered, and M's record marks it given, without marking M claimed.
pub(super) fn ready(
    file: &mut State,
    account: &str,
    team: &str,
    machine: &str,
    now_ms: u64,
    copy: Value,
) -> Value {
    let ours = |other_account: &str, other_team: Option<&str>| {
        other_account == account && other_team == Some(team)
    };
    let receipt = file
        .installed
        .iter()
        .any(|receipt| receipt.account == account && receipt.machine == machine);
    let in_flight = file.copies.iter().any(|copy| {
        ours(&copy.account, Some(copy.team.as_str()))
            && copy.machine.as_deref().is_none_or(|other| other == machine)
    });
    let given = file.warms.iter().any(|record| {
        ours(&record.account, record.team.as_deref())
            && record.machine == machine
            && record.copy_given
    });
    let mut answer = json!({"ok": true, "machine": machine, "team": team, "fresh": false});
    if receipt || in_flight || given {
        return answer;
    }
    let until = now_ms.saturating_add(COPY_BUDGET_MS);
    if let Some(record) = file
        .warms
        .iter_mut()
        .find(|record| ours(&record.account, record.team.as_deref()) && record.machine == machine)
    {
        record.copy_given = true;
        record.ready = true;
        record.warm_until = record.warm_until.max(until);
    } else {
        file.warms.push(Record {
            account: account.to_string(),
            team: Some(team.to_string()),
            machine: machine.to_string(),
            warm_until: until,
            at: now_ms,
            owner: true,
            copy_given: true,
            claimed: false,
            ready: true,
        });
    }
    file.copies.push(Copying {
        account: account.to_string(),
        team: team.to_string(),
        machine: Some(machine.to_string()),
        at: now_ms,
    });
    answer.set("fresh", json!(true));
    answer.set("copy", copy);
    answer
}

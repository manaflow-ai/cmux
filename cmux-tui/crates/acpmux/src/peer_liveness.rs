//! One table of every timer that decides when a peer link is dead and how soon it is redialed,
//! read from the constants themselves, with the worst-case time to notice a dead link and to
//! start its redial as a sum of named timers. `docs/peer-liveness.md` holds the rendered table;
//! a test fails when a constant changes and that doc does not.
//!
//! The idea is WireGuard's (its paper states "dead" as Keepalive-Timeout 10 s plus
//! Rekey-Timeout 5 s): when a slow reconnect needs explaining, the person reading it starts from
//! one sum, not from four files.

use super::{
    SSH_ALIVE_COUNT_MAX, SSH_ALIVE_INTERVAL_SECS, SSH_CONNECT_SECS, SSH_CONNECT_SLOW_SECS,
};
use crate::peer_link::{Backoff, LinkTimings, SilenceBudget, SleepWatch, WAKE_PROBE};
use std::time::Duration;

/// One timer: its name, value, the constant it comes from, and what it decides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timer {
    pub name: &'static str,
    pub value: Duration,
    pub source: &'static str,
    pub decides: &'static str,
}

/// One worst case: what happened, the bound, and how the bound adds up from the timers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorstCase {
    pub case: &'static str,
    pub bound: Duration,
    pub sum: String,
}

/// Every liveness timer of a peer link at its defaults (no `ACPMUX_PEER_*` set).
pub fn timers() -> Vec<Timer> {
    let t = LinkTimings::default();
    vec![
        Timer {
            name: "ping interval",
            value: t.ping_every,
            source: "peer_link::LinkTimings::ping_every",
            decides: "a ping goes out this often; any byte from the peer answers it",
        },
        Timer {
            name: "silence budget (start)",
            value: t.silence_budget(),
            source: "LinkTimings::ping_every x ping_misses",
            decides: "the link is dropped after this long with no byte from the peer",
        },
        Timer {
            name: "silence budget (cap)",
            value: SilenceBudget::CAP,
            source: "peer_link::SilenceBudget::CAP",
            decides: "the most the budget grows to for a peer that answers late",
        },
        Timer {
            name: "ssh keepalive",
            value: Duration::from_secs(SSH_ALIVE_INTERVAL_SECS * SSH_ALIVE_COUNT_MAX),
            source: "peer::SSH_ALIVE_INTERVAL_SECS x SSH_ALIVE_COUNT_MAX",
            decides: "ssh ends the tunnel itself; a backstop under the ping",
        },
        Timer {
            name: "ssh connect",
            value: Duration::from_secs(SSH_CONNECT_SECS),
            source: "peer::SSH_CONNECT_SECS",
            decides: "one ssh attempt gives up (ConnectTimeout)",
        },
        Timer {
            name: "ssh connect (slow)",
            value: Duration::from_secs(SSH_CONNECT_SLOW_SECS),
            source: "peer::SSH_CONNECT_SLOW_SECS",
            decides: "the same while waking a machine or after a banner timeout",
        },
        Timer {
            name: "first redial wait",
            value: Backoff::BASE,
            source: "peer_link::Backoff::BASE",
            decides: "the first backoff step (drawn from its upper half)",
        },
        Timer {
            name: "redial wait cap (wanted)",
            value: Backoff::WANTED_CAP,
            source: "peer_link::Backoff::WANTED_CAP",
            decides: "the longest step while a client waits on the peer",
        },
        Timer {
            name: "redial wait cap",
            value: Backoff::CAP,
            source: "peer_link::Backoff::CAP",
            decides: "the longest step when nobody waits",
        },
        Timer {
            name: "sleep check",
            value: SleepWatch::EVERY,
            source: "peer_link::SleepWatch::EVERY",
            decides: "how often the clocks are compared to notice a sleep",
        },
        Timer {
            name: "wake probe",
            value: WAKE_PROBE,
            source: "peer_link::WAKE_PROBE",
            decides: "after a wake, an open link must answer within this",
        },
        Timer {
            name: "link connect",
            value: t.connect,
            source: "LinkTimings::connect",
            decides: "ssh, the tunnel and the WebSocket upgrade together",
        },
        Timer {
            name: "handshake",
            value: t.handshake,
            source: "LinkTimings::handshake",
            decides: "initialize and watch once the WebSocket is open",
        },
    ]
}

/// The worst cases a slow reconnect is checked against.
pub fn worst_cases() -> Vec<WorstCase> {
    let t = LinkTimings::default();
    let budget = t.silence_budget();
    let ping = t.ping_every;
    let connect = Duration::from_secs(SSH_CONNECT_SECS);
    let slow = Duration::from_secs(SSH_CONNECT_SLOW_SECS);
    let wait = Backoff::BASE;
    let wanted = Backoff::WANTED_CAP;
    let cap = SilenceBudget::CAP;
    let wake = SleepWatch::EVERY + WAKE_PROBE;
    vec![
        WorstCase {
            case: "dead link noticed",
            bound: budget + ping,
            sum: format!("silence budget {} + one ping interval {}", s(budget), s(ping)),
        },
        WorstCase {
            case: "dead link noticed, budget grown",
            bound: cap + ping,
            sum: format!("silence cap {} + one ping interval {}", s(cap), s(ping)),
        },
        WorstCase {
            case: "first redial attempt gives up",
            bound: budget + ping + wait + connect,
            sum: format!(
                "noticed {} + first wait {} + ssh connect {}",
                s(budget + ping),
                s(wait),
                s(connect)
            ),
        },
        WorstCase {
            case: "first redial gives up, slow banner",
            bound: budget + ping + wait + slow,
            sum: format!(
                "noticed {} + first wait {} + slow ssh connect {}",
                s(budget + ping),
                s(wait),
                s(slow)
            ),
        },
        WorstCase {
            case: "second redial begins, client waiting",
            bound: budget + ping + wait + connect + wanted,
            sum: format!(
                "first attempt gave up {} + wanted cap {}",
                s(budget + ping + wait + connect),
                s(wanted)
            ),
        },
        WorstCase {
            case: "dead after a sleep noticed",
            bound: wake,
            sum: format!("sleep check {} + wake probe {}", s(SleepWatch::EVERY), s(WAKE_PROBE)),
        },
    ]
}

/// A duration as `6 s` or `0.5 s`.
fn s(d: Duration) -> String {
    let ms = d.as_millis();
    if ms % 1000 == 0 { format!("{} s", ms / 1000) } else { format!("{} s", ms as f64 / 1000.0) }
}

/// The two tables as Markdown, as `docs/peer-liveness.md` holds them between its markers.
pub fn markdown() -> String {
    let mut out = String::from("| Timer | Value | Source | Decides |\n|---|---|---|---|\n");
    for t in timers() {
        out.push_str(&format!(
            "| {} | {} | `{}` | {} |\n",
            t.name,
            s(t.value),
            t.source,
            t.decides
        ));
    }
    out.push_str("\n| Worst case | Bound | Sum |\n|---|---|---|\n");
    for w in worst_cases() {
        out.push_str(&format!("| {} | {} | {} |\n", w.case, s(w.bound), w.sum));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const BEGIN: &str = "<!-- liveness-table:begin (generated: peer::liveness::markdown) -->\n";
    const END: &str = "<!-- liveness-table:end -->";

    #[test]
    fn the_doc_table_matches_the_constants() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/docs/peer-liveness.md");
        let doc = std::fs::read_to_string(path).expect("docs/peer-liveness.md");
        let start = doc.find(BEGIN).expect("begin marker") + BEGIN.len();
        let end = doc.find(END).expect("end marker");
        let want = markdown();
        if doc[start..end] != want {
            if std::env::var_os("ACPMUX_WRITE_LIVENESS_TABLE").is_some() {
                let fixed = format!("{}{}{}", &doc[..start], want, &doc[end..]);
                std::fs::write(path, fixed).expect("write docs/peer-liveness.md");
                return;
            }
            panic!(
                "a liveness timer changed without docs/peer-liveness.md; rerun with \
                 ACPMUX_WRITE_LIVENESS_TABLE=1 to rewrite it, then fix its prose. Want:\n{want}"
            );
        }
    }

    #[test]
    fn a_dead_link_is_noticed_in_seconds_and_redial_starts_under_ten() {
        let cases = worst_cases();
        let bound = |name: &str| cases.iter().find(|c| c.case == name).expect(name).bound;
        assert_eq!(bound("dead link noticed"), Duration::from_secs(8));
        assert!(bound("first redial attempt gives up") < Duration::from_secs(12));
        assert!(
            bound("first redial gives up, slow banner") > Duration::from_secs(20),
            "a slow banner alone puts a reconnect past 20 s"
        );
    }

    #[test]
    fn the_ssh_keepalive_stays_a_backstop_behind_the_ping() {
        let ssh = Duration::from_secs(SSH_ALIVE_INTERVAL_SECS * SSH_ALIVE_COUNT_MAX);
        assert!(ssh > LinkTimings::default().silence_budget() + LinkTimings::default().ping_every);
        let argv = super::super::tunnel_argv("box", 1, SSH_CONNECT_SECS);
        assert!(argv.contains(&format!("ServerAliveInterval={SSH_ALIVE_INTERVAL_SECS}")));
        assert!(argv.contains(&format!("ServerAliveCountMax={SSH_ALIVE_COUNT_MAX}")));
    }
}

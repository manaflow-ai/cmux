//! The `chief_brain` area: when the app starts, watches, restarts, heals and times out
//! its Chief's brain (the `optchat-chief` host), as rules and `step(state, event) ->
//! (state, effects)` machines. Swift keeps the I/O (files, signals, process lookups,
//! sockets, timers) and runs the effects in order.
//!
//! | Swift | op |
//! |---|---|
//! | `HomeBrainHost` | `bundled_chief_allowed`, `agents_disabled`, `host_resolve_plan`, `host_arguments`, `search_path`, `host_environment`, `host_start_step` |
//! | `ChiefHostStop` | `lock_pid`, `handoff_target`, `host_process`, `app_acpmux_end_keep` |
//! | `ChiefBrainWatch` | `watch_step` |
//! | `ChiefBrainKeeper` | `keeper_ensure`, `keeper_ensure_for_chat`, `keeper_is_running`, `keeper_ask`, `keeper_after_start` |
//! | `ChiefAcpmuxHeal` | `heal_plan`, `heal_finish_step` |
//! | `ChiefReplyWatchdog` | `reply_watchdog` |
//! | `ChiefSettleNotice` | `settle_notice` |
//! | `HomeEngineTurn` | `engine_turn_from_line`, `engine_turns_from_report`, `engine_turns_from_traces`, `engine_turn_usage` |
//! | `ChiefProfilePageRelay` | `profile_relay_route`, `profile_relay_retry`, `profile_relay_reuse` |
//! | `PageCallDeadline`, `PageAnswerDeadline` | `page_call_step` |
//!
//! The `cmux-chief` crate is the host's own core (inbox, turns, outbox, its policy): none of
//! it decides these app-side starts, watches or heals, so this area does not depend on it.

pub mod heal;
pub mod host;
pub mod keeper;
pub mod notices;
pub mod relay;
pub mod time;
pub mod turn;
pub mod watch;

use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// This area's op names (without the `chief_brain.` prefix).
pub const OPS: &[&str] = &[
    "bundled_chief_allowed",
    "agents_disabled",
    "host_resolve_plan",
    "host_arguments",
    "search_path",
    "host_environment",
    "host_start_step",
    "lock_pid",
    "handoff_target",
    "host_process",
    "app_acpmux_end_keep",
    "watch_step",
    "keeper_ensure",
    "keeper_ensure_for_chat",
    "keeper_is_running",
    "keeper_ask",
    "keeper_after_start",
    "heal_plan",
    "heal_finish_step",
    "reply_watchdog",
    "settle_notice",
    "engine_turn_from_line",
    "engine_turns_from_report",
    "engine_turns_from_traces",
    "engine_turn_usage",
    "profile_relay_route",
    "profile_relay_retry",
    "profile_relay_reuse",
    "page_call_step",
];

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageRequest {
    cache_read: Option<f64>,
    cache_write: Option<f64>,
    input: Option<f64>,
    output: Option<f64>,
    #[serde(default = "yes")]
    present: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UsageReply {
    hit_rate: Option<f64>,
    tokens: Option<f64>,
}

/// Runs `chief_brain.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "bundled_chief_allowed" => {
            let r: host::BundleRequest = parse(request)?;
            let allowed = host::bundled_chief_allowed(
                r.bundle_id.as_deref(),
                r.stable_bundle_id.as_deref(),
                r.is_debug_build,
            );
            reply(&json!({ "allowed": allowed }))
        }
        "agents_disabled" => reply(&host::agents_disabled(parse(request)?)),
        "host_resolve_plan" => reply(&host::resolve_plan(parse(request)?)),
        "host_arguments" => {
            let r: host::ArgumentsRequest = parse(request)?;
            reply(&json!({ "launchPath": "/bin/sh", "arguments": host::arguments(&r) }))
        }
        "search_path" => {
            let r: host::SearchPathRequest = parse(request)?;
            let path = host::search_path(r.bundled_bin_directory.as_deref(), &r.home);
            reply(&json!({ "path": path }))
        }
        "host_environment" => reply(&json!({ "environment": host::environment(parse(request)?) })),
        "host_start_step" => {
            let r: host::StartStepRequest = parse(request)?;
            let (state, effects) = host::start_step(r.state, r.event);
            reply(&host::StartStepReply { state, effects })
        }
        "lock_pid" => {
            let r: host::LockRequest = parse(request)?;
            reply(&json!({ "pid": r.text.as_deref().and_then(host::lock_pid) }))
        }
        "handoff_target" => {
            let r: host::HandoffRequest = parse(request)?;
            reply(&json!({ "pid": host::handoff_target(&r) }))
        }
        "host_process" => {
            let r: host::ProcessRequest = parse(request)?;
            let (path, name) = (r.path.as_deref(), r.process_name.as_deref());
            reply(&host::ProcessReply {
                is_chief_host: host::is_chief_host(path, name),
                is_files_host_launcher: host::is_files_host_launcher(path, name),
            })
        }
        "app_acpmux_end_keep" => {
            let r: host::EndKeepRequest = parse(request)?;
            reply(&json!({ "keep": host::app_acpmux_end_keep(r.chief_uses_app_acpmux) }))
        }
        "watch_step" => reply(&watch::step_op(parse(request)?)),
        "keeper_ensure" => {
            let r: keeper::EnsureRequest = parse(request)?;
            reply(&keeper::ensure(r.asked, &r.keeper))
        }
        "keeper_ensure_for_chat" => {
            let r: keeper::KeeperRequest = parse(request)?;
            reply(&keeper::ensure_for_chat(&r.keeper))
        }
        "keeper_is_running" => {
            let r: keeper::KeeperRequest = parse(request)?;
            reply(&json!({ "running": keeper::is_running(&r.keeper) }))
        }
        "keeper_ask" => reply(&keeper::ask(&parse(request)?)),
        "keeper_after_start" => reply(&keeper::after_start(&parse(request)?)),
        "heal_plan" => {
            let r: heal::HealRequest = parse(request)?;
            reply(&heal::heal(r.action))
        }
        "heal_finish_step" => {
            let r: heal::FinishRequest = parse(request)?;
            let (phase, effects) = heal::finish_step(r.phase, r.event);
            reply(&heal::FinishReply { phase, effects })
        }
        "reply_watchdog" => reply(&notices::watchdog(&parse(request)?)),
        "settle_notice" => reply(&notices::settle(&parse(request)?)),
        "engine_turn_from_line" => {
            let r: turn::LineRequest = parse(request)?;
            reply(&turn::TurnReply { turn: turn::from_line(&r.line) })
        }
        "engine_turns_from_report" => {
            let r: turn::ReportRequest = parse(request)?;
            reply(&turn::TurnsReply { turns: r.turns.into_iter().map(turn::from_report).collect() })
        }
        "engine_turns_from_traces" => {
            let r: turn::TracesRequest = parse(request)?;
            reply(&turn::TurnsReply { turns: turn::from_traces(&r.texts, r.limit) })
        }
        "engine_turn_usage" => {
            let r: UsageRequest = parse(request)?;
            let (hit_rate, tokens) =
                turn::usage(r.cache_read, r.cache_write, r.input, r.output, r.present);
            reply(&UsageReply { hit_rate, tokens })
        }
        "profile_relay_route" => reply(&relay::route(&parse(request)?)),
        "profile_relay_retry" => reply(&relay::retry(&parse(request)?)),
        "profile_relay_reuse" => {
            let r: relay::ReuseRequest = parse(request)?;
            reply(&relay::ReuseReply { reuse: relay::reuse(&r) })
        }
        "page_call_step" => {
            let r: relay::CallRequest = parse(request)?;
            reply(&relay::call_step(r.state, r.event))
        }
        _ => Err(OpError::Unknown),
    }
}

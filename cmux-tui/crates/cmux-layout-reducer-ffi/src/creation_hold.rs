//! `focus_ui_creation_hold`: the macOS app's creation input hold
//! (cmux_focus_core::ui::creation_hold) over the JSON channel.
//!
//! Request `{hold?, live?, op}`: `hold` is the state the last answer gave (absent:
//! a new hold begun at `live.nowNs`), `live` what the app reads now, `op` one of
//! the hold's calls tagged by `kind`. Answer `{hold, reply?, facts, dropped?}`:
//! `reply` the call's answer, `facts` the hold's reads the app asks between
//! calls, `dropped` the keys the call dropped (for the app's log).

use cmux_focus_core::ui::creation_hold::{
    CreationHold, Dropped, Earlier, HeldLane, Live, Open, TabKey,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Request {
    #[serde(default)]
    hold: Option<CreationHold>,
    #[serde(default)]
    live: Live,
    op: Op,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum Op {
    Read,
    Open(Open),
    #[serde(rename_all = "camelCase")]
    Cancel {
        tab: String,
    },
    #[serde(rename_all = "camelCase")]
    OpenClose {
        closing: Vec<String>,
        machine: Option<String>,
        #[serde(default)]
        takes_every_key: bool,
    },
    #[serde(rename_all = "camelCase")]
    IsClosing {
        tab: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    SettleClose {
        ticket: i64,
        keys_to: Option<String>,
        stays: bool,
        machine: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    ParkClose {
        ticket: i64,
    },
    #[serde(rename_all = "camelCase")]
    IsCreating {
        tab: String,
    },
    #[serde(rename_all = "camelCase")]
    EarlyLane {
        tab: String,
    },
    #[serde(rename_all = "camelCase")]
    Lane {
        focused_tab: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Resolve {
        ticket: i64,
        awaits_focus: bool,
        workspace: Option<String>,
        #[serde(default)]
        made_tab: bool,
        made_surface: Option<u64>,
    },
    #[serde(rename_all = "camelCase")]
    OwnsKeyboard {
        generation: u64,
    },
    #[serde(rename_all = "camelCase")]
    KeepsKeysFromLeftPage {
        awaits_other_tab: bool,
        generation: u64,
        focused_tab: Option<String>,
    },
    PersonMovedOn,
    #[serde(rename_all = "camelCase")]
    PassesOn {
        focused_tab: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    BindNewWorkspaceKeys {
        tab: Option<String>,
        machine: Option<String>,
        pane: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    DropKeys {
        shown: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Awaits {
        generation: u64,
    },
    #[serde(rename_all = "camelCase")]
    Capture {
        event: u64,
        #[serde(default)]
        chord: bool,
        focused_tab: Option<String>,
        #[serde(default)]
        for_new_workspace: bool,
        #[serde(default)]
        for_newest_intent: bool,
        pane: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    CloseKeyActsNow {
        closes: bool,
        tab_key: Option<TabKey>,
        pane: Option<String>,
        shown: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    ReduceTabKeys {
        drops_lone_close: bool,
    },
    #[serde(rename_all = "camelCase")]
    Prepend {
        earlier: Vec<Earlier>,
        issuer: Option<HeldLane>,
    },
    #[serde(rename_all = "camelCase")]
    AwaitSurface {
        lane: HeldLane,
    },
    #[serde(rename_all = "camelCase")]
    AwaitContent {
        tab: String,
        terminal: bool,
        machine: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    WaitedPastReplyBound {
        bound_ns: Option<i64>,
    },
    #[serde(rename_all = "camelCase")]
    EndReplyWait {
        person_moves: Option<u64>,
        #[serde(default)]
        shows: BTreeSet<String>,
    },
    HeldTabs,
    Take,
    #[serde(rename_all = "camelCase")]
    TakeLane {
        lane: i64,
    },
    #[serde(rename_all = "camelCase")]
    TakeFocused {
        focused: Option<String>,
        kept: Option<i64>,
        #[serde(default)]
        shortcuts: BTreeSet<u64>,
    },
    #[serde(rename_all = "camelCase")]
    KeysKeptForLeftWorkspace {
        shown: Option<String>,
        terminal_ready: bool,
    },
    #[serde(rename_all = "camelCase")]
    ReplyBoundPassed {
        opened: i64,
    },
    LimitPassed,
    TakeForClosedWindow,
    #[serde(rename_all = "camelCase")]
    Holds {
        chord: bool,
        limit_ns: i64,
        expiring: bool,
        closes: bool,
        reply_limit_ns: Option<i64>,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Facts {
    is_resolved: bool,
    holds_creation: bool,
    has_pending_creation: bool,
    is_empty: bool,
    held_count: usize,
    newest_generation: Option<u64>,
    newest_creation: i64,
    untyped_terminal_keys: i64,
    awaited_workspace: Option<String>,
    shown_workspace_to_wait_for: Option<String>,
    left_workspace_with_keys: Option<Value>,
    person_left_every_creation: bool,
    awaits_made_terminal: bool,
    awaits_creation_reply: bool,
    awaited_tab: Option<String>,
    awaits_page: bool,
    replied_at_ns: Option<i64>,
}

#[derive(Serialize)]
pub(crate) struct Response {
    hold: CreationHold,
    #[serde(skip_serializing_if = "Value::is_null")]
    reply: Value,
    facts: Facts,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    dropped: Vec<Dropped>,
}

pub(crate) fn respond(Request { hold, live, op }: Request) -> Response {
    let mut hold = hold.unwrap_or_else(|| CreationHold::new(live.now_ns));
    hold.dropped.clear();
    let reply = apply(&mut hold, &live, op);
    let dropped = std::mem::take(&mut hold.dropped);
    let facts = Facts {
        is_resolved: hold.is_resolved(),
        holds_creation: hold.holds_creation(),
        has_pending_creation: hold.has_pending_creation(),
        is_empty: hold.is_empty(),
        held_count: hold.events.len(),
        newest_generation: hold.newest_generation,
        newest_creation: hold.newest_creation,
        untyped_terminal_keys: hold.untyped_terminal_keys,
        awaited_workspace: hold.awaited_workspace().cloned(),
        shown_workspace_to_wait_for: hold.shown_workspace_to_wait_for().cloned(),
        left_workspace_with_keys: hold
            .left_workspace_with_keys()
            .map(|(ticket, workspace)| json!({"ticket": ticket, "workspace": workspace})),
        person_left_every_creation: hold.person_left_every_creation(),
        awaits_made_terminal: hold.awaits_made_terminal(&live),
        awaits_creation_reply: hold.awaits_creation_reply(),
        awaited_tab: hold.awaited_tab.clone(),
        awaits_page: hold.awaits_page,
        replied_at_ns: hold.replied_at_ns,
    };
    Response { hold, reply, facts, dropped }
}

fn apply(hold: &mut CreationHold, live: &Live, op: Op) -> Value {
    match op {
        Op::Read => Value::Null,
        Op::Open(open) => json!(hold.open(open, live)),
        Op::Cancel { tab } => json!(hold.cancel(&tab, live)),
        Op::OpenClose { closing, machine, takes_every_key } => {
            json!(hold.open_close(closing, machine, takes_every_key, live))
        }
        Op::IsClosing { tab } => json!(hold.is_closing(tab.as_deref())),
        Op::SettleClose { ticket, keys_to, stays, machine } => {
            hold.settle_close(ticket, keys_to, stays, machine, live);
            Value::Null
        }
        Op::ParkClose { ticket } => {
            hold.park_close(ticket, live);
            Value::Null
        }
        Op::IsCreating { tab } => json!(hold.is_creating(&tab)),
        Op::EarlyLane { tab } => json!(hold.early_lane(&tab)),
        Op::Lane { focused_tab } => json!(hold.lane(focused_tab.as_deref())),
        Op::Resolve { ticket, awaits_focus, workspace, made_tab, made_surface } => {
            hold.resolve(ticket, awaits_focus, workspace, made_tab, made_surface, live);
            Value::Null
        }
        Op::OwnsKeyboard { generation } => json!(hold.owns_keyboard(generation)),
        Op::KeepsKeysFromLeftPage { awaits_other_tab, generation, focused_tab } => {
            json!(hold.keeps_keys_from_left_page(
                awaits_other_tab,
                generation,
                focused_tab.as_deref()
            ))
        }
        Op::PersonMovedOn => {
            hold.person_moved_on();
            Value::Null
        }
        Op::PassesOn { focused_tab } => json!(hold.passes_on(focused_tab.as_deref())),
        Op::BindNewWorkspaceKeys { tab, machine, pane } => {
            hold.bind_new_workspace_keys(tab, machine, pane);
            Value::Null
        }
        Op::DropKeys { shown } => json!(hold.drop_keys(shown.as_deref())),
        Op::Awaits { generation } => json!(hold.awaits(generation)),
        Op::Capture { event, chord, focused_tab, for_new_workspace, for_newest_intent, pane } => {
            hold.capture(
                event,
                chord,
                focused_tab.as_deref(),
                for_new_workspace,
                for_newest_intent,
                pane,
            );
            Value::Null
        }
        Op::CloseKeyActsNow { closes, tab_key, pane, shown } => {
            json!(hold.close_key_acts_now(closes, tab_key, pane.as_deref(), shown.as_deref(), live))
        }
        Op::ReduceTabKeys { drops_lone_close } => {
            let (pairs, lost) = hold.reduce_tab_keys(drops_lone_close, live);
            json!({"pairs": pairs, "lost": lost})
        }
        Op::Prepend { earlier, issuer } => {
            hold.prepend(earlier, issuer.as_ref());
            Value::Null
        }
        Op::AwaitSurface { lane } => {
            hold.await_surface(&lane);
            Value::Null
        }
        Op::AwaitContent { tab, terminal, machine } => {
            hold.await_content(tab, terminal, machine);
            Value::Null
        }
        Op::WaitedPastReplyBound { bound_ns } => {
            json!(hold.waited_past_reply_bound(bound_ns, live))
        }
        Op::EndReplyWait { person_moves, shows } => {
            hold.end_reply_wait(person_moves, &shows, live);
            Value::Null
        }
        Op::HeldTabs => json!(
            hold.held_tabs(live)
                .into_iter()
                .map(|(event, tab)| json!({"event": event, "tab": tab}))
                .collect::<Vec<_>>()
        ),
        Op::Take => json!(hold.take(live)),
        Op::TakeLane { lane } => json!(hold.take_lane(lane, live)),
        Op::TakeFocused { focused, kept, shortcuts } => {
            json!(hold.take_focused(focused.as_deref(), kept, &shortcuts, live))
        }
        Op::KeysKeptForLeftWorkspace { shown, terminal_ready } => {
            json!(hold.keys_kept_for_left_workspace(shown.as_deref(), terminal_ready))
        }
        Op::ReplyBoundPassed { opened } => json!(hold.reply_bound_passed(opened)),
        Op::LimitPassed => json!(hold.limit_passed()),
        Op::TakeForClosedWindow => {
            let (runs, lost) = hold.take_for_closed_window(live);
            let runs: Vec<Value> = runs
                .into_iter()
                .map(|(events, lane)| json!({"events": events, "lane": lane}))
                .collect();
            json!({"runs": runs, "lost": lost})
        }
        Op::Holds { chord, limit_ns, expiring, closes, reply_limit_ns } => {
            json!(hold.holds(chord, limit_ns, expiring, closes, reply_limit_ns, live))
        }
    }
}

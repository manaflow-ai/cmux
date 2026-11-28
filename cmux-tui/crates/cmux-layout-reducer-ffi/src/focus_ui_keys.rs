//! The focus UI's key rules over the JSON channel (cmux_focus_core::ui):
//!
//! - `focus_ui_typing_park`: `{park?, gone?, op}` → `{park, reply?, counts,
//!   isEmpty}`; `gone` names the pages whose objects are gone.
//! - `focus_ui_given_back`: `{input?, op}` → `{input, deliver?}`.
//! - `focus_ui_held_keys`: `{keys, optionAsAlt?}` → `{inputs, skipped}`.
//! - `focus_ui_page_first_key`: `{offer?, op}` → `{offer, reply?, count,
//!   held}`; `held` lists the action ids still in the queue.
//! - `focus_ui_awaited_content`: an op tagged by `kind` (`awaited`,
//!   `pageHoldKeeps`, `pageReady`).
//! - `focus_ui_browser_chord`: `{key, chords?}` → `{chromeChord,
//!   browserOnly, pageHistoryAction?}`.
//!
//! Each state (`park`, `input`, `offer`) is the value the last answer gave;
//! absent, a new one.

use crate::ERR_INVALID;
use cmux_focus_core::ui::awaited_content::{self, Kind, Pane};
use cmux_focus_core::ui::browser_chords::{self, BrowserOnlyChords, TypedKey};
use cmux_focus_core::ui::given_back::GivenBackInput;
use cmux_focus_core::ui::held_key::{self, KeyFacts};
use cmux_focus_core::ui::page_first_key::{OfferedKey, PageFirstKeyOffer};
use cmux_focus_core::ui::typing_park::TypingPark;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParkRequest {
    #[serde(default)]
    park: Option<TypingPark>,
    #[serde(default)]
    gone: Vec<u64>,
    op: ParkOp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum ParkOp {
    #[serde(rename_all = "camelCase")]
    Park {
        text: String,
        page: u64,
        #[serde(default)]
        returns: i64,
        now_ns: i64,
    },
    #[serde(rename_all = "camelCase")]
    Take { page: u64, now_ns: i64 },
    #[serde(rename_all = "camelCase")]
    Landed { page: u64, typed: bool },
    #[serde(rename_all = "camelCase")]
    Prune { now_ns: i64 },
    #[serde(rename_all = "camelCase")]
    Holds { page: u64 },
    #[serde(rename_all = "camelCase")]
    IsOnItsWay { page: u64 },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GivenBackRequest {
    #[serde(default)]
    input: Option<GivenBackInput>,
    op: GivenBackOp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum GivenBackOp {
    #[serde(rename_all = "camelCase")]
    Deliver {
        #[serde(default)]
        more: Vec<u8>,
        #[serde(default)]
        terminal: Option<String>,
        #[serde(default)]
        window: Option<String>,
        has_target: bool,
        now_ns: i64,
    },
    #[serde(rename_all = "camelCase")]
    CreationClosed { terminal: String },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeldKeysRequest {
    keys: Vec<KeyFacts>,
    #[serde(default)]
    option_as_alt: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OfferRequest {
    #[serde(default)]
    offer: Option<PageFirstKeyOffer>,
    op: OfferOp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum OfferOp {
    #[serde(rename_all = "camelCase")]
    Offer {
        key: OfferedKey,
        held: u64,
        tab: u64,
    },
    #[serde(rename_all = "camelCase")]
    Take {
        key: OfferedKey,
        tab: u64,
    },
    #[serde(rename_all = "camelCase")]
    TakeResent {
        event: u64,
    },
    Clear,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum AwaitedOp {
    #[serde(rename_all = "camelCase")]
    Awaited {
        content: Kind,
        tab: String,
        #[serde(default)]
        pane: Option<Pane>,
        pane_in_topology: bool,
    },
    #[serde(rename_all = "camelCase")]
    PageHoldKeeps {
        is_chord: bool,
        hold_is_empty: bool,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        page_created: bool,
    },
    #[serde(rename_all = "camelCase")]
    PageReady {
        #[serde(default)]
        browser: Option<bool>,
        #[serde(default)]
        page_window: Option<bool>,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChordRequest {
    key: TypedKey,
    #[serde(default)]
    chords: BrowserOnlyChords,
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn reply(value: Value) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(&value).map_err(|_| ERR_INVALID)
}

/// The answer to one of this file's ops, or None when `operation` is not one.
pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Option<Result<Vec<u8>, i32>> {
    Some(match operation {
        b"focus_ui_typing_park" => typing_park(request),
        b"focus_ui_given_back" => given_back(request),
        b"focus_ui_held_keys" => parse::<HeldKeysRequest>(request).and_then(|request| {
            let (inputs, skipped) =
                held_key::inputs(&request.keys, request.option_as_alt.as_deref());
            reply(json!({ "inputs": inputs, "skipped": skipped }))
        }),
        b"focus_ui_page_first_key" => page_first_key(request),
        b"focus_ui_awaited_content" => awaited(request),
        b"focus_ui_browser_chord" => {
            parse::<ChordRequest>(request).and_then(|ChordRequest { key, chords }| {
                let mut answer = json!({
                    "chromeChord": browser_chords::is_chrome_chord(&key),
                    "browserOnly": browser_chords::is_browser_only_chord(&key, &chords),
                });
                if let Some(action) = browser_chords::page_history_action(&key, &chords) {
                    answer["pageHistoryAction"] = json!(action);
                }
                reply(answer)
            })
        }
        _ => return None,
    })
}

fn typing_park(request: &[u8]) -> Result<Vec<u8>, i32> {
    let ParkRequest { park, gone, op } = parse(request)?;
    let mut park = park.unwrap_or_default();
    let answer = match op {
        ParkOp::Park { text, page, returns, now_ns } => {
            park.park(&text, page, returns, now_ns, &gone);
            Value::Null
        }
        ParkOp::Take { page, now_ns } => json!(park.take(page, now_ns, &gone)),
        ParkOp::Landed { page, typed } => {
            park.landed(page, typed);
            Value::Null
        }
        ParkOp::Prune { now_ns } => {
            park.prune(now_ns, &gone);
            Value::Null
        }
        ParkOp::Holds { page } => json!(park.holds(page)),
        ParkOp::IsOnItsWay { page } => json!(park.is_on_its_way(page)),
    };
    let mut out =
        json!({ "park": park, "counts": park.counts().named(), "isEmpty": park.is_empty() });
    if !answer.is_null() {
        out["reply"] = answer;
    }
    reply(out)
}

fn given_back(request: &[u8]) -> Result<Vec<u8>, i32> {
    let GivenBackRequest { input, op } = parse(request)?;
    let mut input = input.unwrap_or_default();
    let delivered = match op {
        GivenBackOp::Deliver { more, terminal, window, has_target, now_ns } => {
            input.deliver(&more, terminal.as_deref(), window.as_deref(), has_target, now_ns)
        }
        GivenBackOp::CreationClosed { terminal } => {
            input.creation_closed(&terminal);
            None
        }
    };
    let mut out = json!({ "input": input });
    if let Some(bytes) = delivered {
        out["deliver"] = json!(bytes);
    }
    reply(out)
}

fn page_first_key(request: &[u8]) -> Result<Vec<u8>, i32> {
    let OfferRequest { offer, op } = parse(request)?;
    let mut offer = offer.unwrap_or_default();
    let answer = match op {
        OfferOp::Offer { key, held, tab } => {
            offer.offer(key, held, tab);
            None
        }
        OfferOp::Take { key, tab } => offer.take(key, tab),
        OfferOp::TakeResent { event } => offer.take_resent(event),
        OfferOp::Clear => {
            offer.clear();
            None
        }
    };
    let mut out = json!({ "offer": offer, "count": offer.count(), "held": offer.held() });
    if let Some(held) = answer {
        out["reply"] = json!(held);
    }
    reply(out)
}

fn awaited(request: &[u8]) -> Result<Vec<u8>, i32> {
    match parse(request)? {
        AwaitedOp::Awaited { content, tab, pane, pane_in_topology } => {
            let reading = awaited_content::reading(content, &tab, pane.as_ref(), pane_in_topology);
            let mut out = json!({ "reading": reading });
            if let Some(awaited) =
                awaited_content::awaited(content, &tab, pane.as_ref(), pane_in_topology)
            {
                out["hasTerminalLane"] = json!(awaited.has_terminal_lane());
                out["awaited"] = json!(awaited);
            }
            reply(out)
        }
        AwaitedOp::PageHoldKeeps { is_chord, hold_is_empty, command, page_created } => {
            reply(json!({
                "keeps": awaited_content::page_hold_keeps(is_chord, hold_is_empty, command.as_deref(), page_created)
            }))
        }
        AwaitedOp::PageReady { browser, page_window } => {
            reply(json!({ "ready": awaited_content::page_ready(browser, page_window) }))
        }
    }
}

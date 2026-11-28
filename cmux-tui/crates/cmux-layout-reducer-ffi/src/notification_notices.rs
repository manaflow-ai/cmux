//! `cmux-window-rules`' notices over the JSON channel (`notification_notices_*`): a Cloud
//! hand-off's and a sandboxed Run's banner, the Needs you banners, Mark Tab Unread's toggle, the
//! tab a pane shows, the entry blink, a finished `cmux status run` and an OSC 7501 program alert.
//! The app reads its models and the platform's answers into facts, asks, and does what the answer
//! says: the banner, the sound, the daemon write, the tab it opens.

use cmux_window_rules::notification_notices::{
    self as notices, AttentionShowFacts, HandoffFacts, HandoffOpenFacts, Level, MarkWrite, Notice,
    Outcome, ProgramReason, ProgramRecord, RunKey, RunOpenFacts, SoundEvent, ToggleFacts, Trigger,
    Visibility, WorkspaceStatus,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::ERR_INVALID;

const PREFIX: &[u8] = b"notification_notices_";

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(PREFIX)
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: Serialize>(answer: &T) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(answer).map_err(|_| ERR_INVALID)
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct SoundAsk {
    notice: Notice,
    outcome: Outcome,
    classified: Option<SoundEvent>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct GoesOnAsk {
    acknowledge: bool,
    posting_enabled: bool,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct DeliveryAsk {
    desktop: bool,
    sound: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct RunTextAsk {
    task: String,
    outcome: Outcome,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct BannerAsk {
    banner: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ChangesAsk {
    previous: Option<Vec<String>>,
    current: Vec<String>,
    eligible: Option<Vec<String>>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct StaleAsk {
    retained: Vec<String>,
    current_launch: Vec<String>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct WriteAsk {
    write: MarkWrite,
    supported: bool,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct EnteredAsk {
    viewed: Vec<String>,
    previous: Vec<String>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ShownTabAsk {
    count: usize,
    selected: Option<usize>,
    default_index: i64,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct EntryAsk {
    trigger: Trigger,
    flashes_on_read: bool,
    flashes_on_typing: bool,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct RunsAsk {
    running: Vec<RunKey>,
    statuses: Vec<WorkspaceStatus>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct RunNotifiesAsk {
    duration_ms: Option<u64>,
    minimum_seconds: f64,
    when_visible: bool,
    visibility: Visibility,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ProgramMatchAsk {
    title: String,
    body: String,
    level: Level,
    records: Vec<ProgramRecord>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AlertAsk {
    title: String,
    level: Level,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProgramNotifiesAsk {
    reason: ProgramReason,
    #[serde(default)]
    visibility: Visibility,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let name = operation.strip_prefix(PREFIX).ok_or(ERR_INVALID)?;
    match name {
        // The sound event a notice's arrival is decided under.
        b"sound" => {
            let ask: SoundAsk = read(request)?;
            value(&json!({
                "soundEvent": notices::sound_event(ask.notice, ask.outcome, ask.classified),
            }))
        }
        // Whether a decided notice goes on to the sound gate and delivery.
        b"goes_on" => {
            let ask: GoesOnAsk = read(request)?;
            value(&json!({ "goesOn": notices::goes_on(ask.acknowledge, ask.posting_enabled) }))
        }
        // The banner, its default sound, and the sound the app plays itself.
        b"delivery" => {
            let ask: DeliveryAsk = read(request)?;
            value(&notices::delivery(ask.desktop, ask.sound.as_deref()))
        }
        // A hand-off banner's words.
        b"handoff_text" => {
            let facts: HandoffFacts = read(request)?;
            value(&notices::handoff_text(&facts))
        }
        // A Run banner's words.
        b"sandbox_run_text" => {
            let ask: RunTextAsk = read(request)?;
            value(&notices::sandbox_run_text(&ask.task, ask.outcome))
        }
        // The notice a banner id names.
        b"banner" => {
            let ask: BannerAsk = read(request)?;
            value(&json!({ "banner": notices::banner(&ask.banner) }))
        }
        // What a hand-off banner's click does.
        b"handoff_open" => {
            let facts: HandoffOpenFacts = read(request)?;
            value(&json!({ "open": notices::handoff_open(facts) }))
        }
        // What a Run banner's click does.
        b"sandbox_run_open" => {
            let facts: RunOpenFacts = read(request)?;
            value(&json!({ "open": notices::sandbox_run_open(facts) }))
        }
        // The Needs you banners to post and to withdraw.
        b"attention_changes" => {
            let ask: ChangesAsk = read(request)?;
            let changes = notices::attention_changes(ask.previous.as_deref(), &ask.current);
            let post = notices::attention_posts(
                ask.previous.as_deref(),
                &ask.current,
                ask.eligible.as_deref(),
            );
            value(&json!({ "post": post, "withdraw": changes.withdraw }))
        }
        // The Needs you banners an earlier launch left.
        b"attention_stale" => {
            let ask: StaleAsk = read(request)?;
            value(&json!({ "stale": notices::attention_stale(&ask.retained, &ask.current_launch) }))
        }
        // What a Needs you banner's Show does.
        b"attention_show" => {
            let facts: AttentionShowFacts = read(request)?;
            value(&json!({
                "show": notices::attention_show(&facts),
                "tab": notices::attention_tab(&facts.banner),
            }))
        }
        // Mark Tab Unread's toggle: the refusal, else its writes in order.
        b"tab_unread_toggle" => {
            let facts: ToggleFacts = read(request)?;
            value(&notices::tab_unread_toggle(facts))
        }
        // One mark write on its own.
        b"tab_unread_write" => {
            let ask: WriteAsk = read(request)?;
            value(&notices::mark_write(ask.write, ask.supported))
        }
        // The tabs that came into view.
        b"tab_unread_entered" => {
            let ask: EnteredAsk = read(request)?;
            value(&json!({ "entered": notices::entered(&ask.viewed, &ask.previous) }))
        }
        // The tab a pane shows.
        b"shown_tab" => {
            let ask: ShownTabAsk = read(request)?;
            value(
                &json!({ "index": notices::shown_tab(ask.count, ask.selected, ask.default_index) }),
            )
        }
        // Whether going into a tab blinks its ring out.
        b"flashes_on_entry" => {
            let ask: EntryAsk = read(request)?;
            value(&json!({
                "flashes": notices::flashes_on_entry(ask.trigger, ask.flashes_on_read, ask.flashes_on_typing),
            }))
        }
        // The `cmux status run`s that finished, and the runs busy now.
        b"status_runs_finished" => {
            let ask: RunsAsk = read(request)?;
            value(&notices::runs_finished(&ask.running, &ask.statuses))
        }
        // Whether a finished run notifies.
        b"status_run_notifies" => {
            let ask: RunNotifiesAsk = read(request)?;
            value(&json!({
                "notifies": notices::run_notifies(ask.duration_ms, ask.minimum_seconds, ask.when_visible, ask.visibility),
                "visible": ask.visibility.is_visible(),
            }))
        }
        // The OSC 7501 record a notification was posted for.
        b"program_match" => {
            let ask: ProgramMatchAsk = read(request)?;
            value(&json!({
                "match": notices::program_match(&ask.title, &ask.body, ask.level, &ask.records),
            }))
        }
        // Whether a notification reads like an OSC 7501 alert.
        b"program_looks_like_alert" => {
            let ask: AlertAsk = read(request)?;
            value(&json!({ "alert": notices::looks_like_alert(&ask.title, ask.level) }))
        }
        // Whether a program alert shows at all.
        b"program_notifies" => {
            let ask: ProgramNotifiesAsk = read(request)?;
            value(&json!({ "notifies": notices::program_notifies(ask.reason, ask.visibility) }))
        }
        _ => Err(ERR_INVALID),
    }
}

//! Per-client attention (`client-attention-v1`): what each connected client
//! shows, and in which tabs its user typed recently.
//!
//! cmux-next's notification policy decides on these facts in the app
//! (NotificationPolicy.Arrival: `paneIsViewed` is "the tab is the focused
//! content of the key window while cmux is active", `appActive`, `typedAgo`
//! is the time since the last keystroke in the notifying tab, and
//! `minuteOfDay` is local time for quiet hours). cmux-browser moves that
//! policy into the daemon, so every client reports the facts here with
//! `report-client-attention` and the daemon keeps the latest report per
//! connection. The store is memory only: it is never journaled, never
//! broadcast, and a connection's record goes when the connection ends.
//!
//! A client sends at most about 4 reports per second (it coalesces on its
//! side). Latest wins: the daemon stores each report in O(1) under this
//! module's own lock, without the session lock. Ages (`ms_ago`,
//! `reported_ms_ago`) are counted from the daemon's monotonic clock at read
//! time, so a reader never sees a stale age.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::request_origin::{HelloRole, ORIGIN_FORBIDDEN};
use crate::{PaneId, SurfaceId};

/// Advertised in `identify`.
pub(crate) const CAPABILITY: &str = "client-attention-v1";

/// The longest input age the daemon keeps (one day). A larger value reads
/// as this one: the policy only asks "typed within N seconds".
const MAX_INPUT_AGE: Duration = Duration::from_secs(24 * 60 * 60);

/// The most `recent_input` entries one report may carry.
const MAX_RECENT_INPUT: usize = 16;

/// Real clock zones are UTC-12:00 to UTC+14:00; one day either way is the
/// sanity bound.
const MAX_UTC_OFFSET_MINUTES: i32 = 24 * 60;

/// One tab the user typed in, and how long ago.
#[derive(Deserialize)]
pub(super) struct ClientAttentionInput {
    surface: SurfaceId,
    ms_ago: u64,
}

/// `report-client-attention`.
#[derive(Deserialize)]
pub(super) struct ReportParams {
    client_id: String,
    key_window: bool,
    app_active: bool,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    tab: Option<usize>,
    #[serde(default)]
    recent_input: Vec<ClientAttentionInput>,
    #[serde(default)]
    utc_offset_minutes: Option<i32>,
}

/// `client-attention`.
#[derive(Deserialize)]
pub(super) struct ReadParams {
    #[serde(default)]
    client_id: Option<String>,
    /// Also answer the merged attention of this tab (what the notification
    /// policy reads when a notification arrives there).
    #[serde(default)]
    surface: Option<SurfaceId>,
}

/// One connection's latest report.
#[derive(Clone, Debug)]
struct Record {
    client_id: String,
    key_window: bool,
    app_active: bool,
    pane: Option<PaneId>,
    tab: Option<usize>,
    /// When the user last typed in each tab, on the daemon's clock.
    recent_input: Vec<(SurfaceId, Instant)>,
    utc_offset_minutes: Option<i32>,
    reported_at: Instant,
}

/// Where a tab is in the tree, for "is it the focused content".
#[derive(Clone, Copy, Debug)]
pub(super) struct TabLocation {
    pane: PaneId,
    index: usize,
    active: bool,
}

/// What the notification policy reads for one tab (Wave B 2d).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct TabAttention {
    /// Some client shows the tab as the focused content of its key window
    /// while its app is active (cmux-next `paneIsViewed`).
    pub(super) viewed: bool,
    /// The newest input in the tab over all clients (cmux-next `typedAgo`).
    pub(super) typed_ago: Option<Duration>,
}

#[derive(Default)]
pub(crate) struct ClientAttention(Mutex<BTreeMap<u64, Record>>);

/// A poisoned lock still guards whole records (no critical section leaves
/// one half written), so the store keeps working.
fn lock(state: &Mutex<BTreeMap<u64, Record>>) -> MutexGuard<'_, BTreeMap<u64, Record>> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

impl ClientAttention {
    fn store(&self, client: u64, record: Record) {
        lock(&self.0).insert(client, record);
    }

    /// The connection ended: its attention goes with it.
    pub(super) fn disconnect(&self, client: u64) {
        lock(&self.0).remove(&client);
    }

    fn records(&self) -> Vec<(u64, Record)> {
        lock(&self.0).iter().map(|(client, record)| (*client, record.clone())).collect()
    }

    /// The attention of every client for the tab `surface` at `location`
    /// (None: the tab is not in the tree, so nobody views it).
    pub(super) fn tab_attention(
        &self,
        surface: SurfaceId,
        location: Option<TabLocation>,
        now: Instant,
    ) -> TabAttention {
        let mut attention = TabAttention::default();
        for record in lock(&self.0).values() {
            if let Some(location) = location
                && record.key_window
                && record.app_active
                && record.pane == Some(location.pane)
                && record.tab.map_or(location.active, |index| index == location.index)
            {
                attention.viewed = true;
            }
            for (_, at) in record.recent_input.iter().filter(|(typed, _)| *typed == surface) {
                let ago = now.saturating_duration_since(*at);
                attention.typed_ago = Some(attention.typed_ago.map_or(ago, |best| best.min(ago)));
            }
        }
        attention
    }
}

#[derive(Debug)]
struct OriginForbidden;

impl std::fmt::Display for OriginForbidden {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a page relay connection may not report or read client attention")
    }
}

impl std::error::Error for OriginForbidden {}

/// The `error_code` of a refused attention command.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<OriginForbidden>().map(|_| ORIGIN_FORBIDDEN.to_string())
}

/// A page relay serves one page's view; its user's attention is the
/// hosting app's, which reports it on its own connection. A page may not
/// read where the user looks and types either.
fn refuse_page_relay(mux: &Mux, client: u64) -> anyhow::Result<()> {
    let state = mux.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
    let page_relay =
        state.clients.get(&client).is_some_and(|record| record.origin.role == HelloRole::PageRelay);
    if page_relay { Err(OriginForbidden.into()) } else { Ok(()) }
}

/// Same rule as `report-focus`: 1-128 ASCII graphic bytes.
fn validate_client_id(client_id: &str) -> anyhow::Result<()> {
    if client_id.is_empty()
        || client_id.len() > 128
        || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        anyhow::bail!("bad request: invalid client_id");
    }
    Ok(())
}

/// The instant `ms_ago` before `now`, capped at one day. A clock that
/// started less than `ms_ago` ago reads as "just now"; the age is then a
/// lower bound.
fn instant_ago(now: Instant, ms_ago: u64) -> Instant {
    let ago = Duration::from_millis(ms_ago).min(MAX_INPUT_AGE);
    now.checked_sub(ago).unwrap_or(now)
}

pub(super) fn report(mux: &Mux, client: u64, params: ReportParams) -> anyhow::Result<Value> {
    refuse_page_relay(mux, client)?;
    let ReportParams {
        client_id,
        key_window,
        app_active,
        pane,
        tab,
        recent_input,
        utc_offset_minutes,
    } = params;
    validate_client_id(&client_id)?;
    if tab.is_some() && pane.is_none() {
        anyhow::bail!("bad request: tab needs pane");
    }
    if recent_input.len() > MAX_RECENT_INPUT {
        anyhow::bail!("bad request: recent_input has more than {MAX_RECENT_INPUT} entries");
    }
    if utc_offset_minutes.is_some_and(|offset| offset.abs() > MAX_UTC_OFFSET_MINUTES) {
        anyhow::bail!("bad request: utc_offset_minutes out of range");
    }
    if let Some(pane) = pane
        && !mux.with_state(|state| state.panes.contains_key(&pane))
    {
        anyhow::bail!("unknown pane {pane}");
    }
    let now = Instant::now();
    // A tab named twice keeps its newest input. Tabs are not checked
    // against the tree: one may close while the report is on the wire, and
    // a closed tab gets no notification to decide on.
    let mut typed: Vec<(SurfaceId, Instant)> = Vec::with_capacity(recent_input.len());
    for ClientAttentionInput { surface, ms_ago } in recent_input {
        let at = instant_ago(now, ms_ago);
        match typed.iter_mut().find(|(seen, _)| *seen == surface) {
            Some(entry) => entry.1 = entry.1.max(at),
            None => typed.push((surface, at)),
        }
    }
    let record = Record {
        client_id,
        key_window,
        app_active,
        pane,
        tab,
        recent_input: typed,
        utc_offset_minutes,
        reported_at: now,
    };
    mux.control_clients.client_attention.store(client, record);
    Ok(json!({}))
}

pub(super) fn read(mux: &Mux, client: u64, params: ReadParams) -> anyhow::Result<Value> {
    refuse_page_relay(mux, client)?;
    if let Some(client_id) = &params.client_id {
        validate_client_id(client_id)?;
    }
    let store = &mux.control_clients.client_attention;
    let records: Vec<(u64, Record)> = store
        .records()
        .into_iter()
        .filter(|(_, record)| params.client_id.as_ref().is_none_or(|id| *id == record.client_id))
        .collect();
    // One state read: which reported panes still live, and where the asked
    // tab is now.
    let (live, location) = mux.with_state(|state| {
        let live: Vec<bool> = records
            .iter()
            .map(|(_, record)| record.pane.is_some_and(|pane| state.panes.contains_key(&pane)))
            .collect();
        let location = params.surface.and_then(|surface| {
            let pane = state.panes.get(&state.pane_of(surface)?)?;
            Some(TabLocation {
                pane: pane.id,
                index: pane.tabs.iter().position(|tab| *tab == surface)?,
                active: pane.active_surface() == Some(surface),
            })
        });
        (live, location)
    });
    let now = Instant::now();
    let clients: Vec<Value> = records
        .iter()
        .zip(live)
        .map(|((connection, record), live)| {
            let recent_input: Vec<Value> = record
                .recent_input
                .iter()
                .map(|(surface, at)| {
                    json!({"surface": surface, "ms_ago": millis(now.saturating_duration_since(*at))})
                })
                .collect();
            // A pane that closed after the report reads null (its tab too).
            json!({
                "client_id": record.client_id,
                "connection": connection,
                "key_window": record.key_window,
                "app_active": record.app_active,
                "pane": if live { record.pane } else { None },
                "tab": if live { record.tab } else { None },
                "recent_input": recent_input,
                "utc_offset_minutes": record.utc_offset_minutes,
                "reported_ms_ago": millis(now.saturating_duration_since(record.reported_at)),
            })
        })
        .collect();
    let all = store.records();
    let app_active = all.iter().any(|(_, record)| record.app_active);
    let mut reply = json!({"clients": clients, "app_active": app_active});
    if let Some(surface) = params.surface {
        let attention = store.tab_attention(surface, location, now);
        // Quiet hours read the local time of the newest report that has a
        // clock zone, preferring a client whose app is active.
        let utc_offset_minutes = all
            .iter()
            .filter(|(_, record)| record.utc_offset_minutes.is_some())
            .max_by_key(|(_, record)| (record.app_active, record.reported_at))
            .and_then(|(_, record)| record.utc_offset_minutes);
        reply["tab_attention"] = json!({
            "surface": surface,
            "pane": location.map(|location| location.pane),
            "viewed": attention.viewed,
            "app_active": app_active,
            "typed_ms_ago": attention.typed_ago.map(millis),
            "utc_offset_minutes": utc_offset_minutes,
        });
    }
    Ok(reply)
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

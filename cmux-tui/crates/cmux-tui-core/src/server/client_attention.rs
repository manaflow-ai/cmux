//! Per-client attention (`client-attention-v1`): what each connected client
//! shows and when its user last typed or clicked in it.
//!
//! cmux-next's notification policy decides on these facts in the app
//! (NotificationPolicy.Arrival: `paneIsViewed`, `appActive`, `typedAgo`).
//! cmux-browser moves that policy into the daemon, so every client reports
//! them here with `report-client-attention` and the daemon keeps the latest
//! report per connection. The store is memory only: it is never journaled,
//! never broadcast, and a connection's record goes when the connection ends.
//!
//! A client sends at most about 4 reports per second (it coalesces on its
//! side; latest wins). The daemon stores every report in O(1) under this
//! module's own lock, without the session lock, so an extra report costs a
//! socket line only. A report that comes less than [`COALESCE_WINDOW`] after
//! the previous one of the same connection answers `coalesced: true`, so a
//! client can see that it sends too often. Ages (`last_input_ms_ago`,
//! `reported_ms_ago`) are counted from the daemon's monotonic clock at read
//! time, so a reader never sees a stale age.

use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::PaneId;
use crate::request_origin::{HelloRole, ORIGIN_FORBIDDEN};

/// Advertised in `identify`.
pub(crate) const CAPABILITY: &str = "client-attention-v1";

/// Two reports closer than this answer `coalesced: true` (4 per second).
pub(crate) const COALESCE_WINDOW: Duration = Duration::from_millis(250);

/// The longest `last_input_ms_ago` the daemon keeps (one day). A larger value
/// reads as this one: the policy only asks "typed within N seconds".
const MAX_INPUT_AGE: Duration = Duration::from_secs(24 * 60 * 60);

/// `report-client-attention`.
#[derive(Deserialize)]
pub(super) struct ReportParams {
    client_id: String,
    key_window: bool,
    #[serde(default)]
    app_active: Option<bool>,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    tab: Option<usize>,
    #[serde(default)]
    last_input_ms_ago: Option<u64>,
}

/// `client-attention`.
#[derive(Deserialize)]
pub(super) struct ReadParams {
    #[serde(default)]
    client_id: Option<String>,
    /// Also answer the merged attention of this pane (what the
    /// notification policy reads when a notification arrives there).
    #[serde(default)]
    pane: Option<PaneId>,
}

/// One connection's latest report.
#[derive(Clone, Debug)]
struct Record {
    client_id: String,
    key_window: bool,
    app_active: bool,
    pane: Option<PaneId>,
    tab: Option<usize>,
    /// When the user last gave input, on the daemon's clock.
    last_input_at: Option<Instant>,
    reported_at: Instant,
}

/// What the notification policy reads for one pane (Wave B 2d).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct PaneAttention {
    /// Some client shows the pane as the focused pane of its key window.
    pub(super) viewed: bool,
    /// Some client that focuses the pane has its app active.
    pub(super) app_active: bool,
    /// The newest input in a client that focuses the pane.
    pub(super) last_input_ago: Option<Duration>,
}

#[derive(Default)]
pub(crate) struct ClientAttention(Mutex<BTreeMap<u64, Record>>);

/// A poisoned lock still guards whole records (no critical section leaves
/// one half written), so the store keeps working.
fn lock(state: &Mutex<BTreeMap<u64, Record>>) -> MutexGuard<'_, BTreeMap<u64, Record>> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

impl ClientAttention {
    /// Stores `record` for `client`; true when it came inside the coalesce
    /// window of the previous report.
    fn store(&self, client: u64, record: Record) -> bool {
        let mut state = lock(&self.0);
        let coalesced = state.get(&client).is_some_and(|previous| {
            record.reported_at.saturating_duration_since(previous.reported_at) < COALESCE_WINDOW
        });
        state.insert(client, record);
        coalesced
    }

    /// The connection ended: its attention goes with it.
    pub(super) fn disconnect(&self, client: u64) {
        lock(&self.0).remove(&client);
    }

    fn records(&self) -> Vec<(u64, Record)> {
        lock(&self.0).iter().map(|(client, record)| (*client, record.clone())).collect()
    }

    /// The attention of every client for `pane`, merged: viewed when any
    /// client shows it focused in its key window, and the newest input of
    /// the clients that focus it.
    pub(super) fn pane_attention(&self, pane: PaneId, now: Instant) -> PaneAttention {
        let mut attention = PaneAttention::default();
        for record in lock(&self.0).values().filter(|record| record.pane == Some(pane)) {
            attention.viewed |= record.key_window && record.app_active;
            attention.app_active |= record.app_active;
            if let Some(at) = record.last_input_at {
                let ago = now.saturating_duration_since(at);
                attention.last_input_ago =
                    Some(attention.last_input_ago.map_or(ago, |best| best.min(ago)));
            }
        }
        attention
    }

    /// Whether any client has its app active (cmux-next `appActive`).
    pub(super) fn any_app_active(&self) -> bool {
        lock(&self.0).values().any(|record| record.app_active)
    }
}

#[derive(Debug)]
struct OriginForbidden;

impl std::fmt::Display for OriginForbidden {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a page relay connection may not report client attention")
    }
}

impl std::error::Error for OriginForbidden {}

/// The `error_code` of a refused attention report.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<OriginForbidden>().map(|_| ORIGIN_FORBIDDEN.to_string())
}

/// A page relay serves one page's view; its user's attention is the
/// hosting app's, which reports it on its own connection.
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

pub(super) fn report(mux: &Mux, client: u64, params: ReportParams) -> anyhow::Result<Value> {
    refuse_page_relay(mux, client)?;
    let ReportParams { client_id, key_window, app_active, pane, tab, last_input_ms_ago } = params;
    validate_client_id(&client_id)?;
    if tab.is_some() && pane.is_none() {
        anyhow::bail!("bad request: tab needs pane");
    }
    if let Some(pane) = pane
        && !mux.with_state(|state| state.panes.contains_key(&pane))
    {
        anyhow::bail!("unknown pane {pane}");
    }
    let now = Instant::now();
    let last_input_at = last_input_ms_ago.map(|ago| {
        let ago = Duration::from_millis(ago).min(MAX_INPUT_AGE);
        // A clock that started less than `ago` ago reads as "just now"
        // minus what it can hold; the age is then a lower bound.
        now.checked_sub(ago).unwrap_or(now)
    });
    let record = Record {
        client_id,
        key_window,
        // A key window belongs to the active app; a client that does not
        // say otherwise is active exactly when its window is key.
        app_active: app_active.unwrap_or(key_window),
        pane,
        tab,
        last_input_at,
        reported_at: now,
    };
    let coalesced = mux.control_clients.client_attention.store(client, record);
    Ok(json!({"coalesced": coalesced}))
}

pub(super) fn read(mux: &Mux, params: ReadParams) -> anyhow::Result<Value> {
    if let Some(client_id) = &params.client_id {
        validate_client_id(client_id)?;
    }
    let records: Vec<(u64, Record)> = mux
        .control_clients
        .client_attention
        .records()
        .into_iter()
        .filter(|(_, record)| params.client_id.as_ref().is_none_or(|id| *id == record.client_id))
        .collect();
    // A pane that closed after the report reads null (its tab too).
    let live: Vec<bool> = mux.with_state(|state| {
        records
            .iter()
            .map(|(_, record)| record.pane.is_some_and(|pane| state.panes.contains_key(&pane)))
            .collect()
    });
    let now = Instant::now();
    let clients: Vec<Value> = records
        .iter()
        .zip(live)
        .map(|((connection, record), live)| {
            json!({
                "client_id": record.client_id,
                "connection": connection,
                "key_window": record.key_window,
                "app_active": record.app_active,
                "pane": if live { record.pane } else { None },
                "tab": if live { record.tab } else { None },
                "last_input_ms_ago": record
                    .last_input_at
                    .map(|at| millis(now.saturating_duration_since(at))),
                "reported_ms_ago": millis(now.saturating_duration_since(record.reported_at)),
            })
        })
        .collect();
    let mut reply = json!({
        "clients": clients,
        "app_active": mux.control_clients.client_attention.any_app_active(),
    });
    if let Some(pane) = params.pane {
        let attention = mux.control_clients.client_attention.pane_attention(pane, now);
        reply["pane_attention"] = json!({
            "pane": pane,
            "viewed": attention.viewed,
            "app_active": attention.app_active,
            "last_input_ms_ago": attention.last_input_ago.map(millis),
        });
    }
    Ok(reply)
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

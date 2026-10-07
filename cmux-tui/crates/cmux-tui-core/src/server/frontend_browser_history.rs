//! Raw protocol handlers for frontend-rendered browser tabs:
//! `update-frontend-browser-tab` (`frontend-browser-tabs-v1`) and the opaque
//! per-tab session history (`frontend-browser-history-v1`).

use super::*;

/// Opaque per-tab session history (back/forward entries, scroll) for
/// frontend-rendered browsers: `set-frontend-browser-history` and
/// `get-frontend-browser-history`. Never part of the tree.
pub const FRONTEND_BROWSER_HISTORY_CAPABILITY: &str = "frontend-browser-history-v1";

/// `new-frontend-browser-tab`: a browser tab whose page the frontend renders
/// (WebKit or CEF); the daemon persists its location and never attaches a CDP
/// target. With `idempotency_key` (`frontend-browser-tab-keys-v1`) a retry
/// returns the tab the first request created (state/frontend_browser_keys.rs).
#[derive(Deserialize)]
pub(super) struct NewTabParams {
    url: String,
    engine: String,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    favicon_url: Option<String>,
    #[serde(default)]
    profile_id: Option<String>,
    /// Install id of the hosting app (the record's only writer).
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    /// `frontend-browser-activate-v1`: false keeps the pane's active tab.
    #[serde(default = "activate_by_default")]
    activate: bool,
    /// `frontend-browser-insert-after-v1`: the tab lands right after this
    /// tab of the target pane (a link's opener, or the opener's last child),
    /// instead of at the end. Ignored when that tab is not in the pane.
    #[serde(default)]
    after: Option<SurfaceId>,
}

const fn activate_by_default() -> bool {
    true
}

pub(super) fn create(mux: &Arc<Mux>, params: NewTabParams) -> anyhow::Result<Value> {
    let NewTabParams {
        url,
        engine,
        pane,
        title,
        favicon_url,
        profile_id,
        owner,
        idempotency_key,
        cols,
        rows,
        activate,
        after,
    } = params;
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine,
        url,
        title,
        favicon_url,
        profile_id,
        owner,
    };
    let size = paired_surface_size("new-frontend-browser-tab", cols, rows)?;
    let (surface, replayed) = match idempotency_key {
        Some(key) => {
            let outcome = mux.new_frontend_browser_tab_keyed(
                pane,
                record,
                size,
                &key,
                crate::mux::FrontendTabPlacement { activate, after },
            )?;
            (outcome.surface, outcome.replayed)
        }
        None => (
            mux.new_frontend_browser_tab_placed(
                pane,
                record,
                size,
                crate::mux::FrontendTabPlacement { activate, after },
            )?,
            false,
        ),
    };
    let identity = surface.resource_identity();
    Ok(json!({
        "surface": surface.id,
        "tab_resource_id": identity.map(|identity| identity.tab_id.as_str()),
        "content_resource_id": identity.map(|identity| identity.content_id.as_str()),
        "replayed": replayed,
    }))
}

/// `update-frontend-browser-tab`: record a frontend-rendered browser's URL,
/// title, or favicon.
#[derive(Deserialize)]
pub(super) struct UpdateTabParams {
    surface: SurfaceId,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default, deserialize_with = "super::present_nullable")]
    favicon_url: Option<Option<String>>,
    #[serde(default)]
    owner: Option<String>,
}

/// `set-frontend-browser-history`: store a frontend-rendered browser's
/// opaque session history (a JSON object), or clear it with `null`.
#[derive(Deserialize)]
pub(super) struct SetParams {
    surface: SurfaceId,
    history: Value,
}

/// `get-frontend-browser-history`: read a frontend-rendered browser's stored
/// session history.
#[derive(Deserialize)]
pub(super) struct GetParams {
    surface: SurfaceId,
}

pub(super) fn update(mux: &Mux, params: UpdateTabParams) -> anyhow::Result<Value> {
    let UpdateTabParams { surface, url, title, favicon_url, owner } = params;
    let (record, changed) =
        mux.update_frontend_browser_tab_with_owner(surface, url, title, favicon_url, owner)?;
    Ok(json!({
        "surface": surface,
        "url": record.url,
        "title": record.title,
        "favicon_url": record.favicon_url,
        "owner": record.owner,
        "changed": changed,
    }))
}

pub(super) fn set(mux: &Mux, params: SetParams) -> anyhow::Result<Value> {
    let history = match params.history {
        Value::Null => None,
        Value::Object(object) => Some(serde_json::to_string(&object)?),
        _ => anyhow::bail!("bad request: history must be a JSON object or null"),
    };
    mux.set_frontend_browser_history(params.surface, history)?;
    Ok(json!({"surface": params.surface}))
}

pub(super) fn get(mux: &Mux, params: GetParams) -> anyhow::Result<Value> {
    let history = mux
        .frontend_browser_history(params.surface)?
        .map(|history| serde_json::from_str::<Value>(&history))
        .transpose()
        .context("stored frontend browser history is invalid")?;
    Ok(json!({"surface": params.surface, "history": history}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("frontend-browser-history", crate::SurfaceOptions::default())
    }

    fn run_json_command(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
        let command: Command = serde_json::from_value(request)?;
        let writer = MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        });
        handle_command(mux, mux.local_test_client(0), command, &writer)
    }

    #[test]
    fn cmux_next_frontend_browser_history_commands_round_trip() {
        let mux = test_mux();
        assert!(advertised_capabilities(false).contains(&FRONTEND_BROWSER_HISTORY_CAPABILITY));
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let created = run_json_command(
            &mux,
            json!({
                "cmd":"new-frontend-browser-tab",
                "pane": pane,
                "url":"https://cmux.com",
                "engine":"webkit",
            }),
        )
        .unwrap();
        let surface = created["surface"].as_u64().unwrap();
        let get = json!({"cmd":"get-frontend-browser-history","surface":surface});
        assert!(run_json_command(&mux, get.clone()).unwrap()["history"].is_null());

        let history = json!({
            "entries": [{"url":"https://cmux.com"}, {"url":"https://cmux.com/docs"}],
            "index": 1,
            "scroll": {"x": 0, "y": 480.5},
        });
        let stored = run_json_command(
            &mux,
            json!({"cmd":"set-frontend-browser-history","surface":surface,"history":history}),
        )
        .unwrap();
        assert_eq!(stored["surface"], surface);
        let read = run_json_command(&mux, get.clone()).unwrap();
        assert_eq!(read["surface"], surface);
        assert_eq!(read["history"], history);
        // The history stays out of the tree.
        let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
        assert!(!tree.to_string().contains("cmux.com/docs"));

        // Non-object and oversized values are bad requests that keep the
        // stored history; `history` is required, and `null` clears it.
        for rejected in [json!([]), json!("text"), json!(1), json!(true)] {
            let error = run_json_command(
                &mux,
                json!({"cmd":"set-frontend-browser-history","surface":surface,"history":rejected}),
            )
            .unwrap_err();
            assert!(error.to_string().contains("bad request"), "{error}");
        }
        let oversized = json!({
            "pad": "x".repeat(64 * 1024),
        });
        let error = run_json_command(
            &mux,
            json!({"cmd":"set-frontend-browser-history","surface":surface,"history":oversized}),
        )
        .unwrap_err();
        assert!(error.to_string().contains("exceeds"), "{error}");
        assert!(
            run_json_command(&mux, json!({"cmd":"set-frontend-browser-history","surface":surface}))
                .is_err()
        );
        assert_eq!(run_json_command(&mux, get.clone()).unwrap()["history"], history);
        run_json_command(
            &mux,
            json!({"cmd":"set-frontend-browser-history","surface":surface,"history":null}),
        )
        .unwrap();
        assert!(run_json_command(&mux, get).unwrap()["history"].is_null());

        // A PTY tab is not a frontend browser.
        let error = run_json_command(
            &mux,
            json!({"cmd":"set-frontend-browser-history","surface":terminal,"history":{}}),
        )
        .unwrap_err();
        assert!(error.to_string().contains("frontend-rendered"), "{error}");
        assert!(
            run_json_command(
                &mux,
                json!({"cmd":"get-frontend-browser-history","surface":terminal}),
            )
            .is_err()
        );
    }
}

#[cfg(test)]
#[path = "frontend_browser_keys_tests.rs"]
mod keys_tests;

#[cfg(test)]
#[path = "frontend_browser_reuse_tests.rs"]
mod reuse_tests;

#[cfg(test)]
#[path = "frontend_browser_activate_tests.rs"]
mod activate_tests;

#[cfg(test)]
#[path = "frontend_browser_insert_tests.rs"]
mod insert_tests;

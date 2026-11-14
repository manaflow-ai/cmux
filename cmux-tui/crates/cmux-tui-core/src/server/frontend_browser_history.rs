//! Raw protocol handlers for frontend-rendered browser tabs:
//! `new-frontend-browser-tab` (with `split`: `frontend-browser-tab-split-v1`),
//! `update-frontend-browser-tab` (`frontend-browser-tabs-v1`) and the opaque
//! per-tab session history (`frontend-browser-history-v1`).

use super::conversation_tabs_wire::ConversationTabSplitParams;
use super::*;
use crate::Actor;

/// Opaque per-tab session history (back/forward entries, scroll) for
/// frontend-rendered browsers: `set-frontend-browser-history` and
/// `get-frontend-browser-history`. Never part of the tree.
pub const FRONTEND_BROWSER_HISTORY_CAPABILITY: &str = "frontend-browser-history-v1";

/// `profile_id` on `update-frontend-browser-tab`: move the tab to another
/// browser profile (its id or exact name) in place, keeping its surface, tab
/// id and position. The hosting app re-creates the page in the new
/// profile's store (cookies, storage, cache), which reloads it.
pub const FRONTEND_BROWSER_TAB_PROFILE_CAPABILITY: &str = "frontend-browser-tab-profile-v1";

/// `new-frontend-browser-tab {pane, split}`: the tab is created in a new pane
/// on one side of `pane`, in one `pane.split` commit whose one `pane-added`
/// delta holds the pane with the tab, as `conversation-tab-split-v1` does for
/// a conversation tab. The source pane never lists the tab, so opening a
/// link to the right no longer shows it in the source pane first.
pub(crate) const FRONTEND_BROWSER_TAB_SPLIT_CAPABILITY: &str = "frontend-browser-tab-split-v1";

/// `new-frontend-browser-tab {workspace}`: the tab goes in that workspace's
/// active pane, or is the first tab of an empty workspace (no terminal is
/// made for it to replace). Sent instead of `pane`; `split` is refused.
pub(crate) const FRONTEND_BROWSER_TAB_WORKSPACE_CAPABILITY: &str =
    "frontend-browser-tab-workspace-v1";

/// `create-workspace {first_tab}`: the workspace and its first tab in one
/// request. `first_tab` is `{kind: "browser", ...}` with the fields of
/// `new-frontend-browser-tab` (no `pane`, `workspace`, `split` or `after`);
/// the reply's `first_tab` is that command's reply. A first tab that cannot
/// be made takes the workspace back, so no caller sees an empty workspace.
pub(crate) const WORKSPACE_FIRST_TAB_CAPABILITY: &str = "workspace-first-tab-v1";

/// The first tab of a `create-workspace` (`workspace-first-tab-v1`).
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub(crate) enum FirstTabParams {
    /// A frontend-rendered browser tab.
    Browser(NewTabParams),
}

impl FirstTabParams {
    /// Refuses a first tab that names a place of its own: it goes in the new workspace.
    pub(super) fn validate(&self) -> anyhow::Result<()> {
        let Self::Browser(tab) = self;
        anyhow::ensure!(
            tab.pane.is_none()
                && tab.workspace.is_none()
                && tab.split.is_none()
                && tab.after.is_none(),
            "bad request: first_tab takes no pane, workspace, split or after (it is the new workspace's first tab)"
        );
        Ok(())
    }

    /// Whether a replayed `create-workspace` can replay this tab too (it is keyed).
    pub(super) fn is_keyed(&self) -> bool {
        let Self::Browser(tab) = self;
        tab.idempotency_key.is_some()
    }

    /// Creates the tab as the first tab of `workspace`; the reply of its own command.
    pub(super) fn create(
        self,
        mux: &Arc<Mux>,
        client: u64,
        workspace: WorkspaceId,
    ) -> anyhow::Result<Value> {
        let Self::Browser(mut tab) = self;
        tab.workspace = Some(workspace);
        create(mux, client, tab)
    }
}

/// `new-frontend-browser-tab`: a browser tab whose page the frontend renders
/// (WebKit or CEF); the daemon persists its location and never attaches a CDP
/// target. With `idempotency_key` (`frontend-browser-tab-keys-v1`) a retry
/// returns the tab the first request created (state/frontend_browser_keys.rs).
#[derive(Deserialize)]
pub(crate) struct NewTabParams {
    url: String,
    engine: String,
    #[serde(default)]
    pane: Option<PaneId>,
    /// `frontend-browser-tab-workspace-v1`: the workspace to put the tab in
    /// (its first pane when it is empty), instead of `pane`.
    #[serde(default)]
    workspace: Option<WorkspaceId>,
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
    /// `frontend-browser-tab-split-v1`: with `pane`, the tab goes in a new
    /// pane split from it (`{direction, pane_id?, split_id?}`). The new pane
    /// holds only the tab, so `activate` has no effect and `after` is refused.
    #[serde(default)]
    split: Option<ConversationTabSplitParams>,
}

const fn activate_by_default() -> bool {
    true
}

pub(super) fn create(mux: &Arc<Mux>, client: u64, params: NewTabParams) -> anyhow::Result<Value> {
    let NewTabParams {
        url,
        engine,
        pane,
        workspace,
        title,
        favicon_url,
        profile_id,
        owner,
        idempotency_key,
        cols,
        rows,
        activate,
        after,
        split,
    } = params;
    anyhow::ensure!(
        workspace.is_none() || (pane.is_none() && split.is_none()),
        "bad request: send pane or workspace, not both; split goes with pane, not workspace"
    );
    let split = split.map(|split| split.tab_split(pane)).transpose()?;
    anyhow::ensure!(
        split.is_none() || after.is_none(),
        "bad request: after does not apply with split (the new pane holds only the tab)"
    );
    let profile_id = profile_id
        .map(|profile| {
            mux.workspace_registry
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .resolve_browser_profile_id(&profile)
        })
        .transpose()?;
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine,
        url,
        title,
        favicon_url,
        profile_id,
        owner,
    };
    let size = paired_surface_size("new-frontend-browser-tab", cols, rows)?;
    let actor = origin_gate::connection_actor(mux, client);
    let placement = crate::mux::FrontendTabPlacement { activate, after, index: None };
    let (surface, replayed) = match (idempotency_key, split, workspace) {
        (Some(key), None, Some(workspace)) => {
            let outcome = mux.new_frontend_browser_tab_in_workspace_keyed_as(
                &actor, workspace, record, &key, placement,
            )?;
            (outcome.surface, outcome.replayed)
        }
        (None, None, Some(workspace)) => (
            mux.new_frontend_browser_tab_in_workspace_as(&actor, workspace, record, placement)?,
            false,
        ),
        (Some(key), None, None) => {
            let outcome =
                mux.new_frontend_browser_tab_keyed_as(&actor, pane, record, size, &key, placement)?;
            (outcome.surface, outcome.replayed)
        }
        (Some(key), Some(split), _) => {
            let outcome =
                mux.new_frontend_browser_tab_split_keyed_as(&actor, split, record, size, &key)?;
            (outcome.surface, outcome.replayed)
        }
        (None, None, None) => {
            (mux.new_frontend_browser_tab_placed_as(&actor, pane, record, size, placement)?, false)
        }
        (None, Some(split), _) => {
            (mux.new_frontend_browser_tab_split_as(&actor, split, record, size)?, false)
        }
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
    #[serde(default, deserialize_with = "super::present_nullable")]
    profile_id: Option<Option<String>>,
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

pub(super) fn update(mux: &Mux, actor: &Actor, params: UpdateTabParams) -> anyhow::Result<Value> {
    let UpdateTabParams { surface, url, title, favicon_url, profile_id, owner } = params;
    let (record, changed) = mux.update_frontend_browser_tab_with_owner_and_profile_as(
        actor,
        surface,
        url,
        title,
        favicon_url,
        profile_id,
        owner,
    )?;
    Ok(json!({
        "surface": surface,
        "url": record.url,
        "title": record.title,
        "favicon_url": record.favicon_url,
        "profile_id": record.profile_id,
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

#[cfg(test)]
#[path = "frontend_browser_split_tests.rs"]
mod split_tests;

#[cfg(test)]
#[path = "workspace_first_tab_tests.rs"]
mod workspace_first_tab_tests;

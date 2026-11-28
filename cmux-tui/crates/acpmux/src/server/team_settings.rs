//! RFD 0170 phase 4 RPCs: the calling principal's customization page, a person's write of their own
//! (or, as a team admin, the team's) choices, and `Open in cmux` for a Slack message
//! (`cmux_team_messaging::settings`; the store is `hub/team_settings.rs`).
//!
//! Behind the same gate as the rest of team messaging (`team.rs` `authorize`, so
//! `meshRelay.teamMessaging`). The rules live in the crate; this file reads params, finds the viewer
//! in the published team directory and answers the crate's typed view as it serializes (camelCase).
//! A write answers the new page, so a settings view never computes one itself.

use super::*;
use cmux_team_messaging::customization::Customization;
use cmux_team_messaging::handoff::SlackMessage;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::settings::{self, Scope, SettingsError, SettingsStore, ViewContext};

/// The largest `customization` param read, in bytes of JSON.
pub(crate) const MAX_CHOICE_BYTES: usize = 64 * 1024;

/// The answer to `method` if it is one of the settings RPCs; None for every other method.
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        method,
        crate::rpc::method::MUX_TEAM_CUSTOMIZATION
            | crate::rpc::method::MUX_TEAM_CUSTOMIZE
            | crate::rpc::method::MUX_TEAM_HANDOFF
    ) {
        return None;
    }
    let view = hub.team_view();
    let cell = hub.team_settings();
    let (answer, changed) = cell.with(|store| {
        answer(view.as_deref(), store, conn.is_person(), conn.caller(), method, params)
    });
    if changed {
        let hub = Arc::clone(hub);
        let saved = tokio::task::spawn_blocking(move || hub.team_settings().save()).await;
        match saved {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                return Some(Err(RpcError::internal(format!("team settings not saved: {e}"))
                    .with_data(json!({"reason": "team_settings_not_saved"}))));
            }
            Err(e) => return Some(Err(RpcError::internal(format!("team settings save: {e}")))),
        }
    }
    Some(answer)
}

/// One settings call for the connection that is `person` or runs in session `caller`, and whether
/// it changed the store (so it is saved).
pub(crate) fn answer(
    view: Option<&crate::hub::TeamView>,
    store: &mut SettingsStore,
    person: bool,
    caller: Option<&str>,
    method: &str,
    params: &Value,
) -> (Result<Value, RpcError>, bool) {
    let mut changed = false;
    let result = (|| {
        let view = view.ok_or_else(|| {
            RpcError::invalid_params(
                "the team directory is not read yet: no address book from the hub",
            )
            .with_data(json!({"reason": "team_directory_unavailable"}))
        })?;
        let viewer = view.viewer(person, caller).ok_or_else(|| {
            RpcError::invalid_params("this connection is not a principal of the team directory")
                .with_data(json!({"reason": "team_directory_unknown_viewer"}))
        })?;
        let team_id = params.get("teamId").and_then(Value::as_str).unwrap_or(&view.team_id);
        let team = view.team(team_id).ok_or_else(not_visible)?;
        let cx = ViewContext {
            team,
            spaces: &view.spaces,
            principals: &view.principals,
            threads: &view.threads,
        };
        let body = match method {
            crate::rpc::method::MUX_TEAM_CUSTOMIZATION => page(store, viewer, &cx)?,
            crate::rpc::method::MUX_TEAM_CUSTOMIZE => {
                let scope: Scope = field(params, "scope")?;
                let raw = params.get("customization").cloned().unwrap_or(Value::Null);
                if serde_json::to_vec(&raw).map_or(true, |b| b.len() > MAX_CHOICE_BYTES) {
                    return Err(refused(SettingsError::TooLarge("bytes in one customization")));
                }
                let choice: Customization = if raw.is_null() {
                    Customization::default()
                } else {
                    serde_json::from_value(raw).map_err(|e| {
                        RpcError::invalid_params(format!("customization: {e}"))
                            .with_data(json!({"reason": "customization_bad_shape"}))
                    })?
                };
                store.set(viewer, team, scope, choice).map_err(refused)?;
                changed = true;
                page(store, viewer, &cx)?
            }
            _ => match params.get("op").and_then(Value::as_str).unwrap_or("open") {
                "open" => {
                    let message: SlackMessage = field(params, "message")?;
                    to_value(store.handoff(viewer, &cx, &message))?
                }
                "bind" => {
                    let slack: RefKey = field(params, "slack")?;
                    let thread: RefKey = field(params, "thread")?;
                    let before = store.bindings().len();
                    store.bind(viewer, &cx, slack, thread).map_err(refused)?;
                    changed = store.bindings().len() != before;
                    json!({"bound": true})
                }
                "project" => {
                    let thread: RefKey = field(params, "thread")?;
                    if !cx.can_read_thread(viewer, &thread) {
                        return Err(not_visible());
                    }
                    let message_id =
                        params.get("messageId").and_then(Value::as_str).unwrap_or_default();
                    json!({"projection": store.project(&thread, message_id)})
                }
                other => {
                    return Err(RpcError::invalid_params(format!(
                        "op {other:?} is not open, bind or project"
                    )));
                }
            },
        };
        let mut body = body;
        if let Value::Object(map) = &mut body {
            map.insert("generation".into(), json!(view.generation));
        }
        Ok(body)
    })();
    (result, changed)
}

fn page(
    store: &SettingsStore,
    viewer: &cmux_team_messaging::Principal,
    cx: &ViewContext<'_>,
) -> Result<Value, RpcError> {
    to_value(settings::view(store, viewer, cx).ok_or_else(not_visible)?)
}

fn to_value(v: impl serde::Serialize) -> Result<Value, RpcError> {
    serde_json::to_value(v).map_err(|e| RpcError::internal(e.to_string()))
}

fn field<T: serde::de::DeserializeOwned>(params: &Value, name: &str) -> Result<T, RpcError> {
    let raw = params
        .get(name)
        .cloned()
        .ok_or_else(|| RpcError::invalid_params(format!("{name} is required")))?;
    serde_json::from_value(raw).map_err(|e| RpcError::invalid_params(format!("{name}: {e}")))
}

fn refused(e: SettingsError) -> RpcError {
    RpcError::invalid_params(e.to_string()).with_data(json!({"reason": e.reason()}))
}

/// The viewer is not in the team, or it does not exist: one answer for both.
fn not_visible() -> RpcError {
    RpcError::invalid_params("not visible to this connection")
        .with_data(json!({"reason": "team_directory_not_visible"}))
}

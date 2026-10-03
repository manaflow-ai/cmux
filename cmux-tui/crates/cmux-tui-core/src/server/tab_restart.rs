//! `restart-tab` (`tab-restart-v1`): restart a dead terminal tab in place
//! (`Mux::restart_tab`, plans/cmux-next/ownership.md section 3.2).

use super::*;
use crate::mux::tab_restart::{TabRestartError, TabRestartRequest};

/// Advertises `restart-tab`: a dead terminal tab (host lost, process ended
/// under `keep_on_exit`, or kept by keep-layout) restarts in place with a
/// new shell in its last directory, keeping its id, placement, name, pin
/// and group. A replayed `idempotency_key` returns the first result.
pub const TAB_RESTART_CAPABILITY: &str = "tab-restart-v1";

/// `restart-tab`.
#[derive(Deserialize)]
pub(super) struct RestartTabParams {
    surface: TabRef,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    env: Option<BTreeMap<String, String>>,
    #[serde(default)]
    only_lost: bool,
    #[serde(default)]
    transaction: Option<String>,
}

pub(super) fn restart(mux: &Arc<Mux>, params: RestartTabParams) -> anyhow::Result<Value> {
    validate_client_transaction(params.transaction.as_deref())?;
    let surface = resolve_tab_refs(mux, std::slice::from_ref(&params.surface))?[0];
    let env = params.env.as_ref().map(crate::mux::validate_terminal_env).transpose()?;
    let outcome = mux.restart_tab(
        TabRestartRequest {
            surface,
            idempotency_key: params.idempotency_key,
            cwd: params.cwd,
            env: env.unwrap_or_default(),
            only_lost: params.only_lost,
        },
        params.transaction.as_deref().map(Arc::from),
    )?;
    let mut reply = outcome.result;
    reply["replayed"] = json!(outcome.replayed);
    reply["resource_revision"] = json!(outcome.resource_revision);
    if let Some(transaction) = params.transaction {
        reply["transaction"] = json!(transaction);
    }
    Ok(reply)
}

/// The `error_code` of a rejected restart.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<TabRestartError>().map(|error| error.code().to_string())
}

// The test seeds a terminal with a Unix-only fixture.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::workspace_registry::TerminalOnExit;

    fn send(
        mux: &Arc<Mux>,
        outbound: &BoundedOutbound,
        writer: &MessageWriter,
        request: Value,
    ) -> Value {
        handle_message(mux, 7, &request.to_string(), writer);
        serde_json::from_str(&outbound.try_pop().unwrap()).unwrap()
    }

    /// The wire: a live tab is a typed reject; a host-lost tab restarts in
    /// place; the same key replays.
    #[test]
    fn cmux_next_restart_tab_wire_rejects_live_tabs_and_replays_keys() {
        assert!(advertised_capabilities(false).contains(&TAB_RESTART_CAPABILITY));
        let mux = Mux::new_for_test("restart-tab-wire", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let live = mux.new_workspace(None, Some((80, 22))).unwrap().id;
        let refused = send(
            &mux,
            &outbound,
            &writer,
            json!({"id": 1, "cmd": "restart-tab", "surface": live, "idempotency_key": "live-1"}),
        );
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(refused["error_code"], "tab-restart-not-dead", "{refused}");

        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let dead = mux
            .seed_running_terminal_with_on_exit_for_test(
                "00000000000040008000000000000001",
                "10000000000040008000000000000001",
                &workspace.key,
                TerminalOnExit::Close,
            )
            .unwrap();
        mux.surface_exited(dead);
        let request = json!({
            "id": 2, "cmd": "restart-tab", "surface": dead, "idempotency_key": "dead-1",
            "transaction": "restart-1",
        });
        let restarted = send(&mux, &outbound, &writer, request.clone());
        assert_eq!(restarted["ok"], true, "{restarted}");
        assert_eq!(restarted["data"]["surface"], json!(dead));
        assert_eq!(restarted["data"]["replayed"], false);
        assert_eq!(restarted["data"]["transaction"], "restart-1");
        let replayed = send(&mux, &outbound, &writer, request);
        assert_eq!(replayed["data"]["replayed"], true, "{replayed}");
        assert_eq!(replayed["data"]["terminal_id"], restarted["data"]["terminal_id"]);
    }
}

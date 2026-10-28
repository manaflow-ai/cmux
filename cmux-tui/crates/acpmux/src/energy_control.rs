//! `_acpmux/energy {saver?: bool}`: Energy Saver reaches
//! acpmux through its control channel. The cmux daemon sends its mode (the
//! app's `energy.set` override, or its own reading) on its agent chat watch's
//! connection, as that watch connects and on each edge
//! (cmux-tui-core `mux/acpmux_energy.rs`), as Chrome's
//! `BatterySaverModeManager` sends one `SetBatterySaverMode` per edge to each
//! child process
//! (chrome/browser/performance_manager/public/user_tuning/battery_saver_mode_manager.h).
//! An acpmux that no daemon watches keeps the mode it was last sent.
//!
//! `saver` sets the mode; without it (or `null`) the call only reads. The
//! handler flips one atomic and wakes the maintenance clock on an edge: no
//! I/O. The answer is `{pid, saver, changed, jobs}`, `jobs` the maintenance
//! jobs' names (`maintenance.rs`). The unix socket and the local app only:
//! a Web or peer origin gets "Method not found".

use serde_json::{Value, json};

use crate::maintenance::Maintenance;
use crate::rpc::{RpcError, method};
use crate::server::Origin;

/// The mode the call asks for; `None` reads only.
fn requested(params: &Value) -> Result<Option<bool>, RpcError> {
    match params.get("saver") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(saver)) => Ok(Some(*saver)),
        Some(_) => Err(RpcError::invalid_params("saver must be true, false or null")),
    }
}

pub(crate) async fn handle(
    maintenance: &Maintenance,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Err(RpcError::method_not_found(method::MUX_ENERGY));
    }
    let energy = maintenance.energy();
    let changed = requested(params)?.is_some_and(|saver| energy.set_saver(saver));
    Ok(json!({
        "pid": std::process::id(),
        "saver": energy.is_saver(),
        "changed": changed,
        "jobs": maintenance.jobs().await,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn energy_sets_on_an_edge_and_reads_without_saver() {
        let maintenance = Maintenance::default();
        let on = handle(&maintenance, Origin::Local, &json!({"saver": true})).await.unwrap();
        assert_eq!((on["saver"].clone(), on["changed"].clone()), (json!(true), json!(true)));
        let again = handle(&maintenance, Origin::LocalApp, &json!({"saver": true})).await.unwrap();
        assert_eq!(again["changed"], json!(false));
        let read = handle(&maintenance, Origin::Local, &json!({})).await.unwrap();
        assert_eq!((read["saver"].clone(), read["changed"].clone()), (json!(true), json!(false)));
        assert_eq!(read["jobs"], json!([]));
        let off = handle(&maintenance, Origin::Local, &json!({"saver": null})).await.unwrap();
        assert_eq!(off["saver"], json!(true));
    }

    #[tokio::test]
    async fn energy_is_refused_off_the_local_origins_and_checks_saver() {
        let maintenance = Maintenance::default();
        for origin in [Origin::Web, Origin::Peer] {
            let error = handle(&maintenance, origin, &json!({"saver": true})).await.unwrap_err();
            assert_eq!(error.code, RpcError::method_not_found(method::MUX_ENERGY).code);
        }
        assert!(!maintenance.energy().is_saver());
        let error = handle(&maintenance, Origin::Local, &json!({"saver": "on"})).await.unwrap_err();
        assert_eq!(error.code, RpcError::invalid_params("").code);
    }
}

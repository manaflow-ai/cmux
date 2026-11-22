//! Explicit, stateless planning estimate for the default-off History unit-cost experiment.
//! No provider rates, billing reads, persistence or configuration changes.
use super::super::Origin;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};

fn input(params: &Value, key: &str) -> Result<f64, RpcError> {
    let value = match params.get(key) {
        // Decimal keyboards use either separator. Grouping is unsupported: mixed or
        // repeated separators still fail parsing instead of silently changing magnitude.
        Some(Value::String(text)) => text.trim().replace(',', ".").parse::<f64>().ok(),
        Some(Value::Number(value)) => value.as_f64(),
        _ => None,
    };
    value
        .filter(|v| v.is_finite())
        .ok_or_else(|| RpcError::invalid_params(format!("{key} must be a finite number")))
}

pub(super) fn handle(origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if !matches!(origin, Origin::Local | Origin::LocalApp) {
        return Err(RpcError::method_not_found(method::MUX_UNIT_COST));
    }
    let seconds = input(params, "seconds")?;
    let hourly = input(params, "hourlyUsd")?;
    let busy = input(params, "busyPercent")?;
    if seconds < 0.0 || hourly < 0.0 || busy <= 0.0 || busy > 100.0 {
        return Err(RpcError::invalid_params(
            "nonnegative duration and rate, and busy percent in (0, 100], required",
        ));
    }
    let cost = (seconds / 3600.0) * hourly / (busy / 100.0);
    if !cost.is_finite() {
        return Err(RpcError::invalid_params("estimate exceeds the supported numeric range"));
    }
    Ok(json!({"costUsd": cost}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unit_cost_is_local_only() {
        for origin in [Origin::Web, Origin::Peer] {
            assert_eq!(handle(origin, &json!({})).unwrap_err().code, -32601);
        }
    }
    #[test]
    fn unit_cost_accounts_for_idle_time() {
        let result =
            handle(Origin::Local, &json!({"seconds":"900", "hourlyUsd":"2", "busyPercent":"50"}))
                .unwrap();
        assert_eq!(result["costUsd"], 1.0);
        let zero = handle(Origin::LocalApp, &json!({"seconds":0,"hourlyUsd":2,"busyPercent":100}))
            .unwrap();
        assert_eq!(zero["costUsd"], 0.0);
    }
    #[test]
    fn unit_cost_accepts_decimal_comma_inputs() {
        let result = handle(
            Origin::LocalApp,
            &json!({"seconds":"900,0", "hourlyUsd":"1,5", "busyPercent":"37,5"}),
        )
        .unwrap();
        assert_eq!(result["costUsd"], 1.0);
        for text in ["1,000.50", "1.000,50", "1,2,3", "1 000", ","] {
            assert!(handle(
                Origin::LocalApp,
                &json!({"seconds":900,"hourlyUsd":text,"busyPercent":50}),
            ).is_err());
        }
    }
    #[test]
    fn unit_cost_rejects_unknown_invalid_and_overflow() {
        for params in [
            json!({}),
            json!({"seconds":"","hourlyUsd":1,"busyPercent":100}),
            json!({"seconds":1,"hourlyUsd":1,"busyPercent":0}),
            json!({"seconds":1,"hourlyUsd":1,"busyPercent":101}),
            json!({"seconds":-1,"hourlyUsd":1,"busyPercent":100}),
            json!({"seconds":1,"hourlyUsd":"NaN","busyPercent":100}),
            json!({"seconds":"1e308","hourlyUsd":"1e308","busyPercent":1}),
        ] {
            assert!(handle(Origin::Local, &params).is_err());
        }
    }
}

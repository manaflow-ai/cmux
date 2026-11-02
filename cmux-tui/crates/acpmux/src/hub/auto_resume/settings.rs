//! Settings > Agents uses the existing retry engine and attempt count. Defaults leave the
//! daemon's autoResumeDelaysMs unchanged; no retry is added for a successful or cancelled turn.
use serde_json::Value;
use std::sync::OnceLock;

const ENABLED: &str = "agents.retry.enabled";
const INTERVAL: &str = "agents.retry.intervalSeconds";
const SOURCE: &str = include_str!("../../../../../../schemas/settings/source/agent-retry.json");

fn rows() -> &'static Value {
    static ROWS: OnceLock<Value> = OnceLock::new();
    ROWS.get_or_init(|| serde_json::from_str(SOURCE).unwrap_or(Value::Null))
}

fn row(key: &str) -> &'static Value {
    rows()["lists"][0]["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row["key"] == key)
        .unwrap_or(&Value::Null)
}

pub(super) fn read(configured: Option<&Vec<u64>>) -> Vec<u64> {
    let settings = crate::user_settings::read();
    resolve(
        configured,
        match &settings {
            crate::user_settings::Settings::Parsed(doc) => Some(doc),
            _ => None,
        },
    )
}

fn resolve(configured: Option<&Vec<u64>>, doc: Option<&Value>) -> Vec<u64> {
    let value = |key| doc.and_then(|doc| crate::user_settings::value(doc, key));
    let enabled =
        value(ENABLED).and_then(|v| v.as_bool()).or_else(|| row(ENABLED)["default"].as_bool())
            != Some(false);
    if !enabled {
        return Vec::new();
    }
    let range = &row(INTERVAL)["range"];
    let seconds = value(INTERVAL)
        .and_then(|v| v.as_u64())
        .filter(|n| {
            *n >= range["min"].as_u64().unwrap_or(0) && *n <= range["max"].as_u64().unwrap_or(0)
        })
        .or_else(|| row(INTERVAL)["default"].as_u64())
        .unwrap_or(0);
    let mut delays = configured.cloned().unwrap_or_else(|| super::DEFAULT_DELAYS_MS.to_vec());
    if seconds > 0 {
        delays.fill(seconds * 1000);
    }
    delays
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn retry_settings_default_preserves_existing_schedule_and_off_config() {
        let configured = vec![10_000, 40_000];
        assert_eq!(resolve(Some(&configured), None), configured);
        assert_eq!(resolve(None, Some(&json!({}))), super::super::DEFAULT_DELAYS_MS);
        assert!(
            resolve(Some(&vec![]), Some(&json!({"agents.retry.intervalSeconds": 5}))).is_empty()
        );
    }

    #[test]
    fn retry_settings_off_and_interval_apply_without_changing_attempt_count() {
        let configured = vec![10_000, 40_000];
        assert!(
            resolve(Some(&configured), Some(&json!({"agents":{"retry":{"enabled":false}}})))
                .is_empty()
        );
        assert_eq!(
            resolve(Some(&configured), Some(&json!({"agents":{"retry":{"intervalSeconds":3}}}))),
            vec![3000, 3000]
        );
        assert_eq!(
            resolve(Some(&configured), Some(&json!({"agents.retry.intervalSeconds":60}))),
            vec![60000, 60000]
        );
    }

    #[test]
    fn retry_settings_invalid_interval_retains_previous_schedule() {
        let configured = vec![10_000, 40_000];
        for value in [json!(-1), json!(3601), json!("20"), json!(1.5), json!(null)] {
            assert_eq!(
                resolve(Some(&configured), Some(&json!({"agents.retry.intervalSeconds":value}))),
                configured
            );
        }
    }
}

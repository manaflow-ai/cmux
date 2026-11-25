//! Optional cmux-platform wake-on-message support.

use anyhow::{Result, anyhow};
use serde_json::Value;

use crate::config::MachineWakeConfig;

fn path_segment(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// A lane-place lease is carried in the session's tags/host record. Keep this
/// parser tolerant while the platform and peer summary contracts roll out.
pub fn paused_lease(summary: &Value) -> Option<String> {
    fn paused_lease_in(value: &Value) -> Option<String> {
        let object = value.as_object()?;
        let paused = ["state", "machineState", "leaseState"].into_iter().any(|key| {
            object
                .get(key)
                .and_then(Value::as_str)
                .is_some_and(|state| state.eq_ignore_ascii_case("paused"))
        });
        if paused {
            // The id and state must come from the same host/lease record. Never
            // pair a paused state from one record with another record's lease.
            if let Some(id) = object
                .get("leaseId")
                .and_then(Value::as_str)
                .or_else(|| object.get("lease").and_then(Value::as_str))
            {
                return Some(id.to_owned());
            }
            for key in ["lease", "host", "hostRecord", "machine"] {
                if let Some(id) = object.get(key).and_then(paused_lease_in) {
                    return Some(id);
                }
            }
            return None;
        }
        ["lease", "host", "hostRecord", "machine", "peer", "sessionReceipt", "tags"]
            .into_iter()
            .filter_map(|key| object.get(key))
            .find_map(paused_lease_in)
    }
    paused_lease_in(summary)
}

pub fn has_paused_lease(summary: &Value) -> bool {
    paused_lease(summary).is_some()
}

/// Wake is idempotent at the platform API. Errors are returned so the outbox
/// retries delivery instead of losing a message while a machine is starting.
pub async fn wake(config: &MachineWakeConfig, summary: &Value) -> Result<bool> {
    if !config.enabled {
        return Ok(false);
    }
    let Some(lease) = paused_lease(summary) else { return Ok(false) };
    if config.base_url.is_empty() {
        return Err(anyhow!("machine wake is enabled without baseUrl"));
    }
    let url = format!(
        "{}/v1/machines/leases/{}/wake",
        config.base_url.trim_end_matches('/'),
        path_segment(&lease)
    );
    let client = reqwest::Client::new();
    let mut request = client.post(url);
    if let Some(token) = &config.token {
        request = request.bearer_auth(token);
    }
    let response = request.send().await?;
    if !response.status().is_success() {
        return Err(anyhow!("machine wake returned {}", response.status()));
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn finds_paused_lease_in_host_record_or_tags() {
        assert_eq!(
            paused_lease(&json!({"host": {"lease": {"leaseId": "l1", "state": "paused"}}})),
            Some("l1".into())
        );
        assert_eq!(
            paused_lease(&json!({"host": {"lease": "l2", "state": "paused"}})),
            Some("l2".into())
        );
        assert_eq!(paused_lease(&json!({"tags": {"lease": "l3"}, "status": "idle"})), None);
    }
}

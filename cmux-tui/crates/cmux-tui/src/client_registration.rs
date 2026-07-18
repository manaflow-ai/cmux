use std::io::{BufRead, Write};

use serde_json::{Value, json};
use uuid::Uuid;

const REGISTRATION_REQUEST_ID: u64 = 0;

/// Registers a short-lived local command connection as trusted automation.
///
/// Trust still comes from the server's peer-credential check. The caller only
/// declares its narrow client kind, then verifies the exact same-UID role and
/// connection-bound topology lease returned by the daemon.
pub(crate) fn register_trusted_automation(
    writer: &mut impl Write,
    reader: &mut impl BufRead,
) -> anyhow::Result<()> {
    let client_uuid = Uuid::new_v4();
    let process_instance_uuid = Uuid::new_v4();
    writeln!(
        writer,
        "{}",
        json!({
            "id": REGISTRATION_REQUEST_ID,
            "cmd": "register-client",
            "protocol_min": 9,
            "protocol_max": 9,
            "client_uuid": client_uuid,
            "process_instance_uuid": process_instance_uuid,
            "client_kind": "automation",
        })
    )?;

    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            anyhow::bail!("transport closed before automation registration response");
        }
        let response: Value = serde_json::from_str(&line)?;
        if response.get("event").is_some()
            || response.get("id").and_then(Value::as_u64) != Some(REGISTRATION_REQUEST_ID)
        {
            continue;
        }
        if response.get("ok").and_then(Value::as_bool) != Some(true) {
            anyhow::bail!(
                "automation registration rejected: {}",
                response.get("error").and_then(Value::as_str).unwrap_or("unknown error")
            );
        }
        let registration = response.get("data").unwrap_or(&Value::Null);
        validate_trusted_automation_registration(registration, client_uuid, process_instance_uuid)?;
        return Ok(());
    }
}

fn validate_trusted_automation_registration(
    registration: &Value,
    client_uuid: Uuid,
    process_instance_uuid: Uuid,
) -> anyhow::Result<()> {
    let registered_client = registration
        .get("client_uuid")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let registered_process = registration
        .get("process_instance_uuid")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let lease_id = registration
        .get("topology_lease_id")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    if registration.get("protocol").and_then(Value::as_u64) != Some(9)
        || registered_client != Some(client_uuid)
        || registered_process != Some(process_instance_uuid)
        || registration.get("client_kind").and_then(Value::as_str) != Some("automation")
        || registration.get("role").and_then(Value::as_str) != Some("trusted-automation")
        || lease_id.is_none()
        || registration
            .get("topology_lease_generation")
            .and_then(Value::as_u64)
            .is_none_or(|generation| generation == 0)
    {
        anyhow::bail!(
            "cmux-tui daemon did not grant the expected same-UID protocol-v9 automation role"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automation_registration_requires_exact_identity_role_and_live_lease() {
        let client_uuid = Uuid::new_v4();
        let process_instance_uuid = Uuid::new_v4();
        let mut registration = json!({
            "protocol": 9,
            "client_uuid": client_uuid,
            "process_instance_uuid": process_instance_uuid,
            "client_kind": "automation",
            "role": "trusted-automation",
            "topology_lease_id": Uuid::new_v4(),
            "topology_lease_generation": 1,
        });

        validate_trusted_automation_registration(&registration, client_uuid, process_instance_uuid)
            .unwrap();

        registration["role"] = json!("unaffiliated");
        assert!(
            validate_trusted_automation_registration(
                &registration,
                client_uuid,
                process_instance_uuid,
            )
            .is_err()
        );
        registration["role"] = json!("trusted-automation");
        registration["topology_lease_generation"] = json!(0);
        assert!(
            validate_trusted_automation_registration(
                &registration,
                client_uuid,
                process_instance_uuid,
            )
            .is_err()
        );
    }
}

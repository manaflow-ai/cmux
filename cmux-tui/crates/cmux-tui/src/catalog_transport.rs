//! Exact identity fence for a prepared session endpoint.
//!
//! A connector reads the public `session.get` response and private owner
//! identity before it gives the transport to a window. Names and socket paths
//! never satisfy this check.

use anyhow::Context;
use cmux_tui_core::resource::{
    EnvelopeType, MachinePublicId, PROTOCOL, RequestEnvelope, RequestId, ResourceOperation,
    ResponseEnvelope, SessionPublicId,
};
use cmux_tui_core::server::PROTOCOL_VERSION as PRIVATE_PROTOCOL_VERSION;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::device_session_catalog::ResourceAddress;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicSessionIdentity {
    pub address: ResourceAddress,
    pub generation: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnerObservation {
    pub registry_id: String,
    pub generation: String,
    pub process_id: Option<u32>,
    pub lifecycle_ready: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpectedCatalogIdentity {
    pub address: Option<ResourceAddress>,
    pub registry_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedCatalogIdentity {
    pub address: ResourceAddress,
    pub registry_id: String,
    pub owner_generation: String,
    pub process_id: Option<u32>,
}

pub fn session_get_request(request_id: &str) -> anyhow::Result<Value> {
    let request = RequestEnvelope {
        protocol: PROTOCOL.to_string(),
        envelope_type: EnvelopeType::Request,
        id: RequestId::parse(request_id)?,
        operation: ResourceOperation::SessionGet,
        params: json!({"machine":"current", "session":"current"}),
        idempotency_key: None,
    };
    request.validate()?;
    Ok(serde_json::to_value(request)?)
}

pub fn parse_session_get_response(
    value: Value,
    expected_request_id: &str,
) -> anyhow::Result<PublicSessionIdentity> {
    let response = serde_json::from_value::<ResponseEnvelope>(value)?;
    response.validate()?;
    anyhow::ensure!(
        response.id == RequestId::parse(expected_request_id)?,
        "session identity response has a different request id"
    );
    if !response.ok {
        let message = response
            .error
            .map(|error| error.to_string())
            .unwrap_or_else(|| "unknown resource error".to_string());
        anyhow::bail!("session identity request failed: {message}");
    }
    let result = response.result.context("session identity response omitted its result")?;
    let machine_id =
        result["machine_id"].as_str().context("session identity response omitted machine_id")?;
    let session_id =
        result["id"].as_str().context("session identity response omitted session id")?;
    let generation =
        result["generation"].as_str().context("session identity response omitted generation")?;
    validate_owner_identifier("public owner generation", generation)?;
    Ok(PublicSessionIdentity {
        address: ResourceAddress {
            machine_id: MachinePublicId::parse(machine_id)?,
            session_id: SessionPublicId::parse(session_id)?,
        },
        generation: generation.to_string(),
    })
}

pub fn parse_owner_identify(value: &Value) -> anyhow::Result<OwnerObservation> {
    anyhow::ensure!(value["app"] == "cmux-tui", "endpoint is not cmux-tui");
    anyhow::ensure!(
        value["protocol"].as_u64() == Some(u64::from(PRIVATE_PROTOCOL_VERSION)),
        "endpoint private protocol is incompatible"
    );
    let registry_id =
        value["registry_id"].as_str().context("owner identity omitted registry_id")?;
    let generation = value["generation"].as_str().context("owner identity omitted generation")?;
    validate_owner_identifier("registry id", registry_id)?;
    validate_owner_identifier("private owner generation", generation)?;
    let lifecycle_ready =
        value["lifecycle_ready"].as_bool().context("owner identity omitted lifecycle_ready")?;
    let process_id = value["pid"]
        .as_u64()
        .map(u32::try_from)
        .transpose()
        .context("owner identity pid is out of range")?;
    Ok(OwnerObservation {
        registry_id: registry_id.to_string(),
        generation: generation.to_string(),
        process_id,
        lifecycle_ready,
    })
}

fn validate_owner_identifier(name: &str, value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.trim().is_empty() && value.len() <= 128 && !value.chars().any(char::is_control),
        "{name} is invalid"
    );
    Ok(())
}

pub fn verify_catalog_identity(
    expected: &ExpectedCatalogIdentity,
    public: PublicSessionIdentity,
    owner: OwnerObservation,
) -> anyhow::Result<VerifiedCatalogIdentity> {
    anyhow::ensure!(owner.lifecycle_ready, "session owner is not ready");
    anyhow::ensure!(
        public.generation == owner.generation,
        "public and private owner generations do not match"
    );
    if let Some(expected_address) = &expected.address {
        anyhow::ensure!(
            expected_address == &public.address,
            "session endpoint has a different public identity"
        );
    }
    if let Some(expected_registry_id) = &expected.registry_id {
        anyhow::ensure!(
            expected_registry_id == &owner.registry_id,
            "session endpoint has a different registry identity"
        );
    }
    Ok(VerifiedCatalogIdentity {
        address: public.address,
        registry_id: owner.registry_id,
        owner_generation: owner.generation,
        process_id: owner.process_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn address(machine: char, session: char) -> ResourceAddress {
        ResourceAddress {
            machine_id: MachinePublicId::parse(format!(
                "machine_{}",
                machine.to_string().repeat(32)
            ))
            .unwrap(),
            session_id: SessionPublicId::parse(format!(
                "session_{}",
                session.to_string().repeat(32)
            ))
            .unwrap(),
        }
    }

    fn public(address: ResourceAddress) -> PublicSessionIdentity {
        PublicSessionIdentity { address, generation: "generation-1".to_string() }
    }

    fn owner() -> OwnerObservation {
        OwnerObservation {
            registry_id: "registry-1".to_string(),
            generation: "generation-1".to_string(),
            process_id: Some(42),
            lifecycle_ready: true,
        }
    }

    #[test]
    fn identity_request_selects_the_endpoint_singletons() {
        let request = session_get_request("catalog-identity").unwrap();
        assert_eq!(request["protocol"], PROTOCOL);
        assert_eq!(request["operation"], "session.get");
        assert_eq!(request["params"], json!({"machine":"current", "session":"current"}));
    }

    #[test]
    fn session_identity_response_requires_the_exact_request_id() {
        let expected_address = address('0', '0');
        let response = ResponseEnvelope::success(
            RequestId::parse("different-request").unwrap(),
            json!({
                "id": expected_address.session_id,
                "machine_id": expected_address.machine_id,
                "generation": "generation-1",
            }),
        );

        let error = parse_session_get_response(
            serde_json::to_value(response).unwrap(),
            "catalog-request",
        )
        .unwrap_err();
        assert!(error.to_string().contains("different request id"));
    }

    #[test]
    fn exact_public_and_registry_identity_is_verified() {
        let expected_address = address('1', 'a');
        let verified = verify_catalog_identity(
            &ExpectedCatalogIdentity {
                address: Some(expected_address.clone()),
                registry_id: Some("registry-1".to_string()),
            },
            public(expected_address.clone()),
            owner(),
        )
        .unwrap();
        assert_eq!(verified.address, expected_address);
        assert_eq!(verified.owner_generation, "generation-1");
    }

    #[test]
    fn provider_first_binding_accepts_only_one_verified_observation() {
        let observed = address('2', 'b');
        let verified = verify_catalog_identity(
            &ExpectedCatalogIdentity { address: None, registry_id: None },
            public(observed.clone()),
            owner(),
        )
        .unwrap();
        assert_eq!(verified.address, observed);
    }

    #[test]
    fn reconnect_rejects_same_name_with_different_identity() {
        let expected = address('3', 'c');
        let observed = address('3', 'd');
        let error = verify_catalog_identity(
            &ExpectedCatalogIdentity {
                address: Some(expected),
                registry_id: Some("registry-1".to_string()),
            },
            public(observed),
            owner(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("different public identity"));
    }

    #[test]
    fn endpoint_is_not_ready_until_private_identity_is_ready() {
        let expected = address('4', 'e');
        let mut observation = owner();
        observation.lifecycle_ready = false;
        let error = verify_catalog_identity(
            &ExpectedCatalogIdentity {
                address: Some(expected.clone()),
                registry_id: Some("registry-1".to_string()),
            },
            public(expected),
            observation,
        )
        .unwrap_err();
        assert!(error.to_string().contains("not ready"));
    }

    #[test]
    fn private_owner_identity_rejects_an_empty_registry_id() {
        let error = parse_owner_identify(&json!({
            "app": "cmux-tui",
            "protocol": PRIVATE_PROTOCOL_VERSION,
            "registry_id": "",
            "generation": "generation-1",
            "lifecycle_ready": true,
        }))
        .unwrap_err();
        assert!(error.to_string().contains("registry id is invalid"));
    }
}

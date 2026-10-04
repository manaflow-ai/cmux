//! Typed records of the network, tunnel, firewall, domain and publication
//! answers of the Cloud API (`web/app/api/vm/{network,tunnel,firewall,
//! domains,publications}`). Field names stay camelCase like the API.
//! Unknown fields are dropped; a missing optional field is left out.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One private network (`GET /api/vm/network`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Network {
    pub id: String,
    #[serde(default)]
    pub cidr: Option<String>,
    #[serde(default)]
    pub cidr_v6: Option<String>,
    pub scope: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NetworkList {
    pub networks: Vec<Network>,
}

/// One side of a firewall rule.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FirewallEndpoint {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vm_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vpc_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tunnel_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cidr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<String>,
}

/// One allow rule (`VMFirewallRule`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FirewallRule {
    pub id: String,
    pub action: String,
    pub source: FirewallEndpoint,
    pub destination: FirewallEndpoint,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FirewallRuleList {
    pub rules: Vec<FirewallRule>,
}

/// The answer of a tunnel attach or detach.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelChange {
    pub tunnel_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attached: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detached: Option<bool>,
}

/// The answer of a key rotation. `clientConfig` has a blank `PrivateKey`
/// line; the server refuses an answer that carries a value there.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelKey {
    pub tunnel_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub network_id: Option<String>,
    pub client_public_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_public_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_config: Option<String>,
}

/// A publication routed through a custom domain.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DomainPublication {
    pub id: String,
    pub hostname: String,
    pub state: String,
}

/// One custom domain (`CustomDomainDto`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomDomain {
    pub id: String,
    pub hostname: String,
    /// `not_required`, `pending`, `verified` or `failed`.
    pub verification_state: String,
    /// `missing`, `pending`, `active` or `failed`.
    #[serde(default)]
    pub certificate_state: Option<String>,
    #[serde(default)]
    pub created_at: Option<String>,
    /// The DNS records to add, in order (`{purpose, recordTypes, name,
    /// value}`); null until a challenge exists.
    #[serde(default)]
    pub dns_instructions: Option<Value>,
    #[serde(default)]
    pub publications: Vec<DomainPublication>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DomainList {
    pub domains: Vec<CustomDomain>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DomainAnswer {
    pub domain: CustomDomain,
}

/// One published port (`PublicationDto`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Publication {
    pub id: String,
    pub hostname: String,
    #[serde(default)]
    pub url: Option<String>,
    /// `generated` or `custom`.
    #[serde(default)]
    pub domain_kind: Option<String>,
    pub vm_id: String,
    pub port: u16,
    /// `personal`, `team` or `public`.
    pub access_mode: String,
    #[serde(default)]
    pub team_id: Option<String>,
    pub state: String,
    #[serde(default)]
    pub routing_revision: Option<u64>,
    #[serde(default)]
    pub verification: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PublicationList {
    pub publications: Vec<Publication>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PublicationAnswer {
    pub publication: Publication,
}

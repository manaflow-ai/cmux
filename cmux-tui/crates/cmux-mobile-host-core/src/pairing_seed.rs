//! `IPhonePairingSeed`: the phones a tagged test instance trusts without its person-only prompt
//! (DEBUG builds only; cmux-next-ios/SECURITY.md "Test-only pairing seed"). The app reads
//! `CMUX_NEXT_IPHONE_PAIRING_SEED` and the file; this decides whether the file trusts a request.

use serde::Deserialize;

/// The pair request's fields a seed entry can name.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeedRequest {
    pub phone_device_id: String,
    pub name: String,
    pub identity_key: String,
    pub approval_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: Option<String>,
    name: Option<String>,
    identity_key: Option<String>,
    approval_key: Option<String>,
}

#[derive(Debug, Deserialize)]
struct File {
    devices: Vec<Entry>,
}

impl Entry {
    /// Every field the entry gives matches (`id` or `name` at least); an empty entry matches nothing.
    fn matches(&self, request: &SeedRequest) -> bool {
        if self.id.is_none() && self.name.is_none() {
            return false;
        }
        self.id
            .as_ref()
            .is_none_or(|id| id.to_lowercase() == request.phone_device_id.to_lowercase())
            && self.name.as_ref().is_none_or(|name| *name == request.name)
            && self
                .identity_key
                .as_ref()
                .is_none_or(|key| key.to_lowercase() == request.identity_key)
            && self
                .approval_key
                .as_ref()
                .is_none_or(|key| key.to_lowercase() == request.approval_key)
    }
}

/// Whether the seed file's text trusts `request`; an unreadable (`None`) or invalid file trusts nothing.
pub fn trusts(seed: Option<&str>, request: &SeedRequest) -> bool {
    let Some(file) = seed.and_then(|text| serde_json::from_str::<File>(text).ok()) else {
        return false;
    };
    file.devices.iter().any(|entry| entry.matches(request))
}

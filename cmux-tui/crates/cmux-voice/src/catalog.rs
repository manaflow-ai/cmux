//! The dictation providers cmux knows. The ids are the `agentPane.dictationEngine` setting's
//! values and never change; labels may.

use serde::Serialize;

/// Where the provider runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Local,
    Cloud,
}

/// How a recording reaches the provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Wire {
    /// The app's own on-device engine: nothing goes over the network.
    Builtin,
    /// `POST <base>/audio/transcriptions`, multipart, `{"text": ...}` back (OpenAI, Groq, and the
    /// local servers that copy the route).
    OpenaiTranscriptions,
    /// whisper.cpp's server: `POST <base>/inference`, multipart, `{"text": ...}` back.
    WhisperCppInference,
}

/// Whether the provider takes an API key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyUse {
    None,
    Optional,
    Required,
}

/// What a provider can do. Only `DictationBatch` is implemented; the others are reserved so a
/// streaming or real-time provider can be added without changing callers (see the crate doc).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Capability {
    /// Record, then send the whole recording; the words arrive on stop.
    DictationBatch,
    /// Reserved: words arrive while the person speaks.
    DictationStreaming,
    /// Reserved: a spoken conversation with a model.
    RealtimeVoice,
}

/// One catalog entry, serialized as the contract's `{id, label, kind, wire, key, defaultUrl,
/// defaultModel}`. An empty `default_url` means the person must give one; an empty
/// `default_model` means no `model` field is sent unless the person sets one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Provider {
    pub id: &'static str,
    pub label: &'static str,
    pub kind: Kind,
    pub wire: Wire,
    pub key: KeyUse,
    pub default_url: &'static str,
    pub default_model: &'static str,
    #[serde(skip)]
    pub capabilities: &'static [Capability],
}

impl Provider {
    /// Whether the provider can do `capability`.
    pub fn supports(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }
}

/// The id of the default engine, today's on-device dictation.
pub const ON_DEVICE: &str = "onDevice";

const BATCH: &[Capability] = &[Capability::DictationBatch];

/// Every provider, in the order Settings lists them.
pub const PROVIDERS: &[Provider] = &[
    Provider {
        id: ON_DEVICE,
        label: "On This Mac",
        kind: Kind::Local,
        wire: Wire::Builtin,
        key: KeyUse::None,
        default_url: "",
        default_model: "",
        capabilities: BATCH,
    },
    Provider {
        id: "openai",
        label: "OpenAI",
        kind: Kind::Cloud,
        wire: Wire::OpenaiTranscriptions,
        key: KeyUse::Required,
        default_url: "https://api.openai.com/v1",
        default_model: "gpt-4o-mini-transcribe",
        capabilities: BATCH,
    },
    Provider {
        id: "groq",
        label: "Groq",
        kind: Kind::Cloud,
        wire: Wire::OpenaiTranscriptions,
        key: KeyUse::Required,
        default_url: "https://api.groq.com/openai/v1",
        default_model: "whisper-large-v3-turbo",
        capabilities: BATCH,
    },
    Provider {
        id: "localServer",
        label: "Local Server",
        kind: Kind::Local,
        wire: Wire::OpenaiTranscriptions,
        key: KeyUse::Optional,
        default_url: "http://127.0.0.1:8000/v1",
        default_model: "",
        capabilities: BATCH,
    },
    Provider {
        id: "whisperCpp",
        label: "whisper.cpp Server",
        kind: Kind::Local,
        wire: Wire::WhisperCppInference,
        key: KeyUse::None,
        default_url: "http://127.0.0.1:8080",
        default_model: "",
        capabilities: BATCH,
    },
    Provider {
        id: "custom",
        label: "Custom Endpoint",
        kind: Kind::Cloud,
        wire: Wire::OpenaiTranscriptions,
        key: KeyUse::Optional,
        default_url: "",
        default_model: "",
        capabilities: BATCH,
    },
];

/// The provider with this id.
pub fn find(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

/// The provider with this id, or on-device for anything unknown (an unknown setting value must
/// never send audio anywhere).
pub fn find_or_on_device(id: &str) -> &'static Provider {
    find(id).unwrap_or(&ON_DEVICE_PROVIDER)
}

const ON_DEVICE_PROVIDER: Provider = Provider {
    id: ON_DEVICE,
    label: "On This Mac",
    kind: Kind::Local,
    wire: Wire::Builtin,
    key: KeyUse::None,
    default_url: "",
    default_model: "",
    capabilities: BATCH,
};

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalog_serializes_in_the_contract_shape() {
        let v = serde_json::to_value(PROVIDERS).unwrap();
        assert_eq!(
            v,
            json!([
                {"id": "onDevice", "label": "On This Mac", "kind": "local", "wire": "builtin",
                 "key": "none", "defaultUrl": "", "defaultModel": ""},
                {"id": "openai", "label": "OpenAI", "kind": "cloud", "wire": "openaiTranscriptions",
                 "key": "required", "defaultUrl": "https://api.openai.com/v1",
                 "defaultModel": "gpt-4o-mini-transcribe"},
                {"id": "groq", "label": "Groq", "kind": "cloud", "wire": "openaiTranscriptions",
                 "key": "required", "defaultUrl": "https://api.groq.com/openai/v1",
                 "defaultModel": "whisper-large-v3-turbo"},
                {"id": "localServer", "label": "Local Server", "kind": "local",
                 "wire": "openaiTranscriptions", "key": "optional",
                 "defaultUrl": "http://127.0.0.1:8000/v1", "defaultModel": ""},
                {"id": "whisperCpp", "label": "whisper.cpp Server", "kind": "local",
                 "wire": "whisperCppInference", "key": "none",
                 "defaultUrl": "http://127.0.0.1:8080", "defaultModel": ""},
                {"id": "custom", "label": "Custom Endpoint", "kind": "cloud",
                 "wire": "openaiTranscriptions", "key": "optional", "defaultUrl": "",
                 "defaultModel": ""},
            ])
        );
    }

    #[test]
    fn ids_are_unique_and_unknown_reads_as_on_device() {
        let mut ids: Vec<_> = PROVIDERS.iter().map(|p| p.id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), PROVIDERS.len());
        assert_eq!(find_or_on_device("nope").id, ON_DEVICE);
        assert_eq!(find_or_on_device("").id, ON_DEVICE);
        assert_eq!(find_or_on_device("groq").id, "groq");
        assert_eq!(find("onDevice"), Some(&ON_DEVICE_PROVIDER));
    }

    #[test]
    fn every_provider_dictates_in_batch_only_for_now() {
        for p in PROVIDERS {
            assert!(p.supports(Capability::DictationBatch), "{}", p.id);
            assert!(!p.supports(Capability::DictationStreaming), "{}", p.id);
            assert!(!p.supports(Capability::RealtimeVoice), "{}", p.id);
        }
    }
}

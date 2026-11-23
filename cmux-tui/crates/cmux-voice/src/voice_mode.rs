//! Voice mode's providers: how the person's voice reaches the agent and how the agent's words are
//! read, behind one capability, [`Capability::RealtimeVoice`].
//!
//! Two shapes ([`crate::relay::Transport`]):
//!
//! - **Cascade** (`cascade`): the dictation engine the person already picked hears them (any
//!   provider in [`crate::catalog::PROVIDERS`], on-device included), local voice detection
//!   ([`crate::vad`]) gives barge-in, and a [`SpeechEngine`] reads: the system voice (no key,
//!   nothing sent) or an OpenAI-style `POST <base>/audio/speech` ([`crate::speak`]). A fully local
//!   stack is a first-class provider, not a fallback.
//! - **Speech to speech** (`openaiRealtime`): the service the iPhone uses, as a relay
//!   ([`crate::realtime`]), with the key the person saved for it.
//!
//! The voice mode settings (`agentPane.voiceMode`, `...VoiceModeSpeech`, `...VoiceModeVoice`,
//! `...VoiceModeModel`) are read like the dictation ones; an unknown value is `off`, which shows no
//! voice button (a dead button is not shipped).

use serde::Serialize;

use crate::catalog::{Capability, KeyUse, Kind};
use crate::relay::Transport;

/// A voice mode provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceProvider {
    pub id: &'static str,
    pub label: &'static str,
    pub kind: Kind,
    pub key: KeyUse,
    #[serde(skip)]
    pub transport: Transport,
    pub default_url: &'static str,
    pub default_model: &'static str,
    pub default_voice: &'static str,
    #[serde(skip)]
    pub capabilities: &'static [Capability],
}

impl VoiceProvider {
    pub fn supports(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }
}

const REALTIME: &[Capability] = &[Capability::RealtimeVoice];

/// The voice mode setting's value that shows no voice button (the default).
pub const OFF: &str = "off";

/// Every voice mode provider, in the order Settings lists them.
pub const VOICE_PROVIDERS: &[VoiceProvider] = &[
    VoiceProvider {
        id: "cascade",
        label: "Dictation and Speech",
        kind: Kind::Local,
        key: KeyUse::None,
        transport: Transport::Cascade,
        default_url: "",
        default_model: "",
        default_voice: "",
        capabilities: REALTIME,
    },
    VoiceProvider {
        id: "openaiRealtime",
        label: "OpenAI Realtime",
        kind: Kind::Cloud,
        key: KeyUse::Required,
        transport: Transport::Realtime,
        default_url: "https://api.openai.com/v1",
        default_model: "gpt-realtime-2.1",
        default_voice: "marin",
        capabilities: REALTIME,
    },
];

/// The voice mode provider with this id; `None` for `off` and anything unknown.
pub fn find_voice(id: &str) -> Option<&'static VoiceProvider> {
    VOICE_PROVIDERS.iter().find(|p| p.id == id.trim())
}

/// Who reads the agent's words in a cascade.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SpeechEngine {
    /// The system voice, in the app (`AVSpeechSynthesizer`): no key, nothing sent.
    System,
    /// `POST <base>/audio/speech` ([`crate::speak`]): a hosted service with a key, or a local
    /// Kokoro or Piper server that copies the route.
    OpenaiSpeech,
}

impl SpeechEngine {
    /// The engine named by the setting; the system voice for anything unknown (it sends nothing).
    pub fn parse(value: &str) -> Self {
        match value.trim() {
            "openaiSpeech" => Self::OpenaiSpeech,
            _ => Self::System,
        }
    }
}

/// The voice mode settings, raw.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VoiceSettings {
    pub mode: String,
    pub speech: String,
    pub voice: String,
    pub model: String,
}

/// What voice mode runs, or `None` when it is off.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoicePlan {
    pub provider: &'static str,
    pub transport: &'static str,
    /// Cascade only: who reads.
    pub speech: Option<SpeechEngine>,
    pub model: String,
    pub voice: String,
}

/// Resolves the settings to a plan; `None` is off (no voice button).
pub fn plan(settings: &VoiceSettings) -> Option<VoicePlan> {
    let provider = find_voice(&settings.mode)?;
    let or = |given: &str, default: &str| {
        let given = given.trim();
        if given.is_empty() { default.to_owned() } else { given.to_owned() }
    };
    let (transport, speech) = match provider.transport {
        Transport::Cascade => ("cascade", Some(SpeechEngine::parse(&settings.speech))),
        Transport::Realtime => ("realtime", None),
    };
    Some(VoicePlan {
        provider: provider.id,
        transport,
        speech,
        model: or(&settings.model, provider.default_model),
        voice: or(&settings.voice, provider.default_voice),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn settings(mode: &str, speech: &str) -> VoiceSettings {
        VoiceSettings { mode: mode.into(), speech: speech.into(), ..VoiceSettings::default() }
    }

    #[test]
    fn off_and_unknown_show_no_voice_button() {
        for mode in ["", OFF, "nonsense"] {
            assert_eq!(plan(&settings(mode, "")), None, "{mode}");
        }
    }

    #[test]
    fn every_voice_provider_is_realtime_voice() {
        for p in VOICE_PROVIDERS {
            assert!(p.supports(Capability::RealtimeVoice), "{}", p.id);
            assert!(!p.supports(Capability::DictationBatch), "{}", p.id);
        }
    }

    #[test]
    fn a_cascade_reads_with_the_system_voice_unless_told_otherwise() {
        let p = plan(&settings("cascade", "")).map(|p| p.speech);
        assert_eq!(p, Some(Some(SpeechEngine::System)));
        let p = plan(&settings("cascade", "openaiSpeech")).map(|p| p.speech);
        assert_eq!(p, Some(Some(SpeechEngine::OpenaiSpeech)));
        let p = plan(&settings("cascade", "weird")).map(|p| p.speech);
        assert_eq!(p, Some(Some(SpeechEngine::System)));
    }

    #[test]
    fn speech_to_speech_takes_its_defaults_and_overrides() {
        let v = serde_json::to_value(plan(&settings("openaiRealtime", "openaiSpeech"))).ok();
        assert_eq!(
            v,
            Some(json!({"provider": "openaiRealtime", "transport": "realtime", "speech": null,
                        "model": "gpt-realtime-2.1", "voice": "marin"}))
        );
        let s = VoiceSettings {
            mode: "openaiRealtime".into(),
            voice: " cedar ".into(),
            model: "gpt-realtime-2.1-mini".into(),
            ..VoiceSettings::default()
        };
        let p = plan(&s).map(|p| (p.model, p.voice));
        assert_eq!(p, Some(("gpt-realtime-2.1-mini".into(), "cedar".into())));
    }
}

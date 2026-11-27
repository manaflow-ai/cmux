//! Dictation providers a person brings to cmux (Settings > Agent Pane > dictation engine).
//!
//! - [`catalog`]: the providers cmux knows, as static data with stable ids (the values of the
//!   `agentPane.dictationEngine` setting).
//! - [`endpoint`]: the settings (engine, URL override, model override) resolved to the endpoint a
//!   recording goes to, the URL rule (https; http only to loopback, or to a private-LAN host when
//!   no key is sent) and the Keychain account a key is saved under, `<providerId>@<origin>`, so a
//!   key only ever goes to the origin it was saved for.
//! - [`provider`]: the [`provider::DictationProvider`] trait and its HTTP implementation of the
//!   two batch wires (the OpenAI-style `POST <base>/audio/transcriptions` and whisper.cpp's
//!   `POST <base>/inference`), with errors in the closed [`error::ErrorCode`] set.
//! - [`audio`]: the recording as the caller hands it over (base64 bytes), capped.
//! - [`state`]: the JSON the acpmux `_acpmux/voice/*` methods answer.
//!
//! Adding streaming dictation or a real-time voice mode later: each catalog entry lists its
//! [`catalog::Capability`]s (`dictationBatch` today; `dictationStreaming` and `realtimeVoice` are
//! reserved). A streaming provider (a WebSocket wire) becomes a new [`catalog::Wire`] variant and a
//! new implementation of [`provider::DictationProvider`]; the trait gains a `stream` method with a
//! default body that answers `not_configured`, so every existing implementation and caller stays
//! as it is. A caller asks [`catalog::Provider::supports`] before it offers a mode. Real-time voice
//! is a separate trait beside this one (a duplex session, not a request), picked by the same
//! capability list. Only the batch path exists now.

pub mod audio;
pub mod catalog;
pub mod endpoint;
pub mod error;
pub mod multipart;
pub mod provider;
pub mod relay;
pub mod speech;
pub mod state;

pub use audio::{Audio, AudioError, MAX_AUDIO_BYTES};
pub use catalog::{Capability, KeyUse, Kind, PROVIDERS, Provider, Wire};
pub use endpoint::{Endpoint, Resolved, Settings, key_account, resolve};
pub use error::{ErrorCode, VoiceError};
pub use provider::{BatchRequest, DictationProvider, Http, Transcript, provider_for};
pub use relay::{
    Effect as RelayEffect, Phase as RelayPhase, RelayEvent, RelayState,
    Transition as RelayTransition, reduce as reduce_relay,
};
pub use speech::{is_noise, speakable};
pub use state::{State, check_reply, state, transcribe_reply};

/// The Keychain service every dictation key is saved under (a generic password).
pub const KEY_SERVICE: &str = "cmux-voice-key";

#[cfg(test)]
mod test_server;

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
//! - [`audio`]: the recording as the caller hands it over (a path or base64), capped.
//! - [`state`]: the JSON the acpmux `_acpmux/voice/*` methods answer.
//!
//! - [`session`]: the streaming dictation session as a pure reducer (events in, effects out):
//!   the one lifecycle every surface draws.
//! - [`stream`]: the streaming wire (a WebSocket: audio up as it is spoken, partial and final
//!   words back), driving [`session`].
//!
//! Each catalog entry lists its [`catalog::Capability`]s: `dictationBatch` for all,
//! `dictationStreaming` for a provider with the streaming wire ([`stream::stream_url`]), and
//! `realtimeVoice` reserved. A caller asks [`catalog::Provider::supports`] before it offers a
//! mode. Real-time voice is a separate session beside these (a duplex conversation), picked by
//! the same capability list.

pub mod audio;
pub mod catalog;
pub mod endpoint;
pub mod error;
pub mod multipart;
pub mod provider;
pub mod session;
pub mod state;
pub mod stream;

pub use audio::{Audio, AudioError, MAX_AUDIO_BYTES};
pub use catalog::{Capability, KeyUse, Kind, PROVIDERS, Provider, Wire};
pub use endpoint::{Endpoint, Resolved, Settings, key_account, resolve};
pub use error::{ErrorCode, VoiceError};
pub use provider::{BatchRequest, DictationProvider, Http, Transcript, provider_for, usable_key};
pub use session::{Effect, Event, Phase, Session, Shown};
pub use state::{State, check_reply, state, transcribe_reply};
pub use stream::{Command, stream_url};

/// The Keychain service every dictation key is saved under (a generic password).
pub const KEY_SERVICE: &str = "cmux-voice-key";

#[cfg(test)]
mod test_server;

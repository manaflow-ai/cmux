//! The recording bytes supplied by the caller, in base64. No filesystem access.

use base64::Engine;

use crate::error::{ErrorCode, VoiceError};

/// The largest recording sent: 24 MiB (OpenAI's transcription limit is 25 MB).
pub const MAX_AUDIO_BYTES: u64 = 25_165_824;

/// The recording supplied by the caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Audio {
    /// The file's bytes, standard base64.
    Base64(String),
}

/// Why a recording could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioError {
    /// The caller's request is not valid base64.
    Invalid(String),
    /// Over the cap: refused before anything is sent.
    TooLarge(VoiceError),
}

fn too_large(cap: u64) -> AudioError {
    AudioError::TooLarge(VoiceError::new(
        ErrorCode::TooLarge,
        &format!("the recording is over the {cap} byte limit"),
        None,
    ))
}

impl Audio {
    /// The recording's bytes, at most `cap` of them.
    pub fn load(&self, cap: u64) -> Result<Vec<u8>, AudioError> {
        match self {
            Self::Base64(text) => {
                let text = text.trim();
                // Every 4 characters decode to at most 3 bytes.
                let most = u64::try_from(text.len())
                    .unwrap_or(u64::MAX)
                    .checked_div(4)
                    .unwrap_or(0)
                    .saturating_mul(3);
                if most > cap.saturating_add(3) {
                    return Err(too_large(cap));
                }
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(text)
                    .map_err(|_| AudioError::Invalid("audio is not standard base64".into()))?;
                if !u64::try_from(bytes.len()).is_ok_and(|n| n <= cap) {
                    return Err(too_large(cap));
                }
                Ok(bytes)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_input_loads() {
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"RIFF1234WAVE");
        assert_eq!(Audio::Base64(b64).load(MAX_AUDIO_BYTES).unwrap(), b"RIFF1234WAVE");
    }

    #[test]
    fn bad_inputs_are_invalid() {
        assert!(matches!(
            Audio::Base64("not base64!!".into()).load(10),
            Err(AudioError::Invalid(_))
        ));
    }

    #[test]
    fn oversize_is_too_large() {
        let b64 = base64::engine::general_purpose::STANDARD.encode([0u8; 11]);
        let Err(AudioError::TooLarge(error)) = Audio::Base64(b64.clone()).load(10) else {
            panic!("not too large")
        };
        assert_eq!(error.code, ErrorCode::TooLarge);
        assert_eq!(Audio::Base64(b64).load(11).unwrap().len(), 11);
        // A huge base64 string is refused on its length, before decoding.
        let huge = "A".repeat(4000);
        assert!(matches!(Audio::Base64(huge).load(100), Err(AudioError::TooLarge(_))));
    }
}

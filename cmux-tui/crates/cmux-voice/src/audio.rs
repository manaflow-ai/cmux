//! The recording, as the caller hands it over: a WAV file's path or its bytes in base64.

use std::io::Read;
use std::path::PathBuf;

use base64::Engine;

use crate::error::{ErrorCode, VoiceError};

/// The largest recording sent: 24 MiB (OpenAI's transcription limit is 25 MB).
pub const MAX_AUDIO_BYTES: u64 = 25_165_824;

/// Where the recording is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Audio {
    /// An absolute path to a regular file.
    Path(PathBuf),
    /// The file's bytes, standard base64.
    Base64(String),
}

/// Why a recording could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AudioError {
    /// The caller's request is wrong (a relative path, no such file, not base64).
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
            Self::Path(path) => {
                if !path.is_absolute() {
                    return Err(AudioError::Invalid("path must be absolute".into()));
                }
                let meta = std::fs::metadata(path)
                    .map_err(|e| AudioError::Invalid(format!("cannot read the recording: {e}")))?;
                if !meta.is_file() {
                    return Err(AudioError::Invalid("path is not a regular file".into()));
                }
                if meta.len() > cap {
                    return Err(too_large(cap));
                }
                let file = std::fs::File::open(path)
                    .map_err(|e| AudioError::Invalid(format!("cannot read the recording: {e}")))?;
                let mut bytes = Vec::new();
                file.take(cap.saturating_add(1))
                    .read_to_end(&mut bytes)
                    .map_err(|e| AudioError::Invalid(format!("cannot read the recording: {e}")))?;
                if !u64::try_from(bytes.len()).is_ok_and(|n| n <= cap) {
                    return Err(too_large(cap));
                }
                Ok(bytes)
            }
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

    fn temp_file(name: &str, bytes: &[u8]) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("cmux-voice-audio-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("recording.wav");
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn path_and_base64_inputs_load() {
        let path = temp_file("ok", b"RIFF1234WAVE");
        assert_eq!(Audio::Path(path.clone()).load(MAX_AUDIO_BYTES).unwrap(), b"RIFF1234WAVE");
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"RIFF1234WAVE");
        assert_eq!(Audio::Base64(b64).load(MAX_AUDIO_BYTES).unwrap(), b"RIFF1234WAVE");
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn bad_inputs_are_invalid() {
        assert!(matches!(Audio::Path("rel.wav".into()).load(10), Err(AudioError::Invalid(_))));
        assert!(matches!(
            Audio::Path("/nonexistent/cmux-voice.wav".into()).load(10),
            Err(AudioError::Invalid(_))
        ));
        assert!(matches!(Audio::Path(std::env::temp_dir()).load(10), Err(AudioError::Invalid(_))));
        assert!(matches!(
            Audio::Base64("not base64!!".into()).load(10),
            Err(AudioError::Invalid(_))
        ));
    }

    #[test]
    fn oversize_is_too_large() {
        let path = temp_file("big", &[0u8; 11]);
        let Err(AudioError::TooLarge(e)) = Audio::Path(path.clone()).load(10) else {
            panic!("not too large")
        };
        assert_eq!(e.code, ErrorCode::TooLarge);
        assert_eq!(Audio::Path(path.clone()).load(11).unwrap().len(), 11);
        let b64 = base64::engine::general_purpose::STANDARD.encode([0u8; 11]);
        assert!(matches!(Audio::Base64(b64.clone()).load(10), Err(AudioError::TooLarge(_))));
        assert_eq!(Audio::Base64(b64).load(11).unwrap().len(), 11);
        // A huge base64 string is refused on its length, before decoding.
        let huge = "A".repeat(4000);
        assert!(matches!(Audio::Base64(huge).load(100), Err(AudioError::TooLarge(_))));
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }
}

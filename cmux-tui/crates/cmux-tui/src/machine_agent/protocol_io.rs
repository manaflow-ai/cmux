use std::io::{self, BufRead, Write};

use cmux_tui_machine_agent_protocol::{Envelope, MAX_FRAME_BYTES};
use zeroize::Zeroize;

#[derive(Debug)]
pub(super) enum FrameReadError {
    Io(io::Error),
    Disconnected,
    Truncated,
    TooLarge,
    Invalid(serde_json::Error),
}

impl std::fmt::Display for FrameReadError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "machine-agent transport read failed: {error}"),
            Self::Disconnected => formatter.write_str("machine-agent transport disconnected"),
            Self::Truncated => formatter.write_str("machine-agent transport ended mid-frame"),
            Self::TooLarge => {
                write!(formatter, "machine-agent frame exceeds {MAX_FRAME_BYTES} bytes")
            }
            Self::Invalid(error) => write!(formatter, "invalid machine-agent frame: {error}"),
        }
    }
}

impl std::error::Error for FrameReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Invalid(error) => Some(error),
            _ => None,
        }
    }
}

pub(super) fn read_frame<R: BufRead>(reader: &mut R) -> Result<Envelope, FrameReadError> {
    let mut frame = Vec::new();
    loop {
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error) => {
                frame.zeroize();
                return Err(FrameReadError::Io(error));
            }
        };
        if available.is_empty() {
            return if frame.is_empty() {
                Err(FrameReadError::Disconnected)
            } else {
                frame.zeroize();
                Err(FrameReadError::Truncated)
            };
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            if frame.len().saturating_add(newline) > MAX_FRAME_BYTES {
                frame.zeroize();
                return Err(FrameReadError::TooLarge);
            }
            frame.extend_from_slice(&available[..newline]);
            reader.consume(newline + 1);
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            let decoded = serde_json::from_slice(&frame).map_err(FrameReadError::Invalid);
            frame.zeroize();
            return decoded;
        }
        if frame.len().saturating_add(available.len()) > MAX_FRAME_BYTES {
            frame.zeroize();
            return Err(FrameReadError::TooLarge);
        }
        let consumed = available.len();
        frame.extend_from_slice(available);
        reader.consume(consumed);
    }
}

pub(super) fn write_frame<W: Write>(writer: &mut W, frame: &Envelope) -> io::Result<()> {
    let mut encoded = serde_json::to_vec(frame)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if encoded.len() > MAX_FRAME_BYTES {
        encoded.zeroize();
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("machine-agent frame exceeds {MAX_FRAME_BYTES} bytes"),
        ));
    }
    let result = writer
        .write_all(&encoded)
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush());
    encoded.zeroize();
    result
}

#[cfg(test)]
mod tests {
    use std::io::{BufReader, Cursor};

    use cmux_tui_machine_agent_protocol::{Heartbeat, Message};

    use super::*;

    #[test]
    fn bounded_reader_rejects_oversized_truncated_and_malformed_frames() {
        let oversized = vec![b'x'; MAX_FRAME_BYTES + 1];
        assert!(matches!(
            read_frame(&mut BufReader::new(Cursor::new(oversized))),
            Err(FrameReadError::TooLarge)
        ));
        assert!(matches!(
            read_frame(&mut BufReader::new(Cursor::new(b"{".to_vec()))),
            Err(FrameReadError::Truncated)
        ));
        assert!(matches!(
            read_frame(&mut BufReader::new(Cursor::new(b"{}\n".to_vec()))),
            Err(FrameReadError::Invalid(_))
        ));

        let mut wire = Vec::new();
        let expected = Envelope::new(Message::Ping(Heartbeat { nonce: 7 }));
        write_frame(&mut wire, &expected).unwrap();
        assert_eq!(read_frame(&mut BufReader::new(Cursor::new(wire))).unwrap(), expected);
    }
}

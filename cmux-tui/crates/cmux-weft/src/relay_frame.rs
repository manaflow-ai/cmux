//! Relay frames: one WebSocket binary message carries one WireGuard datagram
//! prefixed by a 32-byte WireGuard public key. Client to relay the key names
//! the destination; relay to client it names the sender (stamped by the
//! relay from the sender's ticket, never taken from the client).

/// Largest datagram a frame carries. A 1280-byte inner MTU plus WireGuard's
/// 32-byte overhead fits with room to spare.
pub const MAX_DATAGRAM: usize = 2048;

pub fn encode(key: &[u8; 32], datagram: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(32 + datagram.len());
    frame.extend_from_slice(key);
    frame.extend_from_slice(datagram);
    frame
}

/// The key and datagram of a frame, or `None` when its size is out of range.
pub fn decode(frame: &[u8]) -> Option<([u8; 32], &[u8])> {
    if frame.len() <= 32 || frame.len() > 32 + MAX_DATAGRAM {
        return None;
    }
    let (key, datagram) = frame.split_at(32);
    Some((key.try_into().ok()?, datagram))
}

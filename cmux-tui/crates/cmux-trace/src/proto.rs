//! A protobuf wire encoder for the Perfetto exporter ([`crate::export`]): varints, fixed64,
//! doubles and length-delimited fields, nothing else. Perfetto's own `protozero`
//! (`src/protozero/message.cc`) is the model: append-only writes into one buffer, a nested message
//! closed by writing its length in front of it. The field numbers live where they are used
//! ([`crate::export`]'s `field` module), next to the `.proto` file each comes from.

/// Wire types (protobuf encoding spec).
const VARINT: u8 = 0;
const FIXED64: u8 = 1;
const LENGTH_DELIMITED: u8 = 2;

/// An append-only protobuf message buffer.
#[derive(Default)]
pub(crate) struct Message {
    bytes: Vec<u8>,
}

impl Message {
    pub(crate) fn new() -> Message {
        Message { bytes: Vec::new() }
    }

    pub(crate) fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub(crate) fn clear(&mut self) {
        self.bytes.clear();
    }

    fn tag(&mut self, field: u32, wire: u8) {
        push_varint(&mut self.bytes, u64::from(field) << 3 | u64::from(wire));
    }

    /// `uint32`, `uint64` or an enum.
    pub(crate) fn uint(&mut self, field: u32, value: u64) -> &mut Message {
        self.tag(field, VARINT);
        push_varint(&mut self.bytes, value);
        self
    }

    /// `int32` or `int64`: two's complement, so a negative value takes ten bytes (not zigzag).
    pub(crate) fn int(&mut self, field: u32, value: i64) -> &mut Message {
        self.uint(field, value as u64)
    }

    pub(crate) fn bool(&mut self, field: u32, value: bool) -> &mut Message {
        self.uint(field, u64::from(value))
    }

    pub(crate) fn fixed64(&mut self, field: u32, value: u64) -> &mut Message {
        self.tag(field, FIXED64);
        self.bytes.extend_from_slice(&value.to_le_bytes());
        self
    }

    pub(crate) fn double(&mut self, field: u32, value: f64) -> &mut Message {
        self.fixed64(field, value.to_bits())
    }

    pub(crate) fn bytes(&mut self, field: u32, value: &[u8]) -> &mut Message {
        self.tag(field, LENGTH_DELIMITED);
        push_varint(&mut self.bytes, value.len() as u64);
        self.bytes.extend_from_slice(value);
        self
    }

    pub(crate) fn string(&mut self, field: u32, value: &str) -> &mut Message {
        self.bytes(field, value.as_bytes())
    }

    /// A nested message: `body` writes its fields, then its length goes in front of them.
    pub(crate) fn message(&mut self, field: u32, body: impl FnOnce(&mut Message)) -> &mut Message {
        self.tag(field, LENGTH_DELIMITED);
        let start = self.bytes.len();
        body(self);
        let len = self.bytes.len() - start;
        let mut prefix = [0u8; 10];
        let prefix_len = encode_varint(len as u64, &mut prefix);
        self.bytes.splice(start..start, prefix[..prefix_len].iter().copied());
        self
    }
}

/// Writes `value` as a varint into `out`; returns its length (1 to 10 bytes).
fn encode_varint(mut value: u64, out: &mut [u8; 10]) -> usize {
    let mut len = 0;
    loop {
        let byte = (value & 0x7F) as u8;
        value >>= 7;
        if value == 0 {
            out[len] = byte;
            return len + 1;
        }
        out[len] = byte | 0x80;
        len += 1;
    }
}

pub(crate) fn push_varint(bytes: &mut Vec<u8>, value: u64) {
    let mut out = [0u8; 10];
    let len = encode_varint(value, &mut out);
    bytes.extend_from_slice(&out[..len]);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints_match_the_protobuf_spec() {
        let cases: [(u64, &[u8]); 5] = [
            (0, &[0x00]),
            (1, &[0x01]),
            (150, &[0x96, 0x01]),
            (300, &[0xAC, 0x02]),
            (u64::MAX, &[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
        ];
        for (value, bytes) in cases {
            let mut out = Vec::new();
            push_varint(&mut out, value);
            assert_eq!(out, bytes, "varint {value}");
        }
    }

    #[test]
    fn a_negative_int_is_ten_bytes_of_twos_complement() {
        let mut message = Message::new();
        message.int(1, -1);
        assert_eq!(
            message.as_bytes(),
            &[0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        );
    }

    #[test]
    fn a_nested_message_is_prefixed_with_its_length() {
        // The protobuf spec's example: message Test3 { Test1 c = 3; } with Test1.a = 150.
        let mut message = Message::new();
        message.message(3, |inner| {
            inner.uint(1, 150);
        });
        assert_eq!(message.as_bytes(), &[0x1A, 0x03, 0x08, 0x96, 0x01]);
    }

    #[test]
    fn a_long_nested_message_takes_a_two_byte_length() {
        let mut message = Message::new();
        let text = "x".repeat(200);
        message.message(1, |inner| {
            inner.string(2, &text);
        });
        let bytes = message.as_bytes();
        assert_eq!(&bytes[..3], &[0x0A, 0xCB, 0x01], "203 bytes of body");
        assert_eq!(bytes.len(), 3 + 203);
    }

    #[test]
    fn fixed64_and_doubles_are_little_endian() {
        let mut message = Message::new();
        message.fixed64(47, 0x0102_0304_0506_0708).double(5, 1.5);
        assert_eq!(
            message.as_bytes(),
            &[
                0xF9, 0x02, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x29, 0, 0, 0, 0, 0, 0,
                0xF8, 0x3F
            ]
        );
    }
}

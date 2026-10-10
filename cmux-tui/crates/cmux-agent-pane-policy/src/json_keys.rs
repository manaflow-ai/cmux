//! The strict duplicate-key check for page frames, a port of CmuxNextAgentPane
//! `AcpmuxJSONKeys` (AcpmuxJSONKeys.swift, ad349 round 7). A parser keeps one
//! of two duplicate keys without an error (Foundation one, serde_json the
//! last), so a frame with a duplicate could be checked as one value and acted
//! on as the other: such a frame is refused before any parse.
//!
//! It reads the whole JSON grammar (RFC 8259) without recursion. Keys are
//! decoded and compared after NFC normalization, as Swift compares strings
//! (canonical equivalence), so a composed and a decomposed accent are one key
//! here too.

use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Clean,
    Malformed,
    Duplicate,
}

/// The verdict on `text`: not one well-formed JSON text, an object with two
/// keys that are equal strings, or clean.
pub fn verdict(text: &str) -> Verdict {
    let bytes = text.as_bytes();
    if bytes.is_empty() {
        return Verdict::Malformed;
    }
    let mut reader = Reader { bytes, i: 0, stack: Vec::new(), duplicate: false };
    let well_formed = reader.well_formed_without_duplicates();
    if reader.duplicate {
        Verdict::Duplicate
    } else if well_formed {
        Verdict::Clean
    } else {
        Verdict::Malformed
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Expect {
    Value,
    ValueOrEnd,
    Key,
    KeyOrEnd,
    CommaOrEnd,
}

struct Reader<'a> {
    bytes: &'a [u8],
    i: usize,
    /// The open containers: an object's keys so far, or None for an array.
    stack: Vec<Option<HashSet<String>>>,
    duplicate: bool,
}

impl Reader<'_> {
    fn well_formed_without_duplicates(&mut self) -> bool {
        let count = self.bytes.len();
        let mut expect = Expect::Value;
        self.space();
        while self.i < count {
            match expect {
                Expect::Value | Expect::ValueOrEnd => {
                    if expect == Expect::ValueOrEnd && self.bytes[self.i] == b']' {
                        self.i += 1;
                        self.stack.pop();
                        expect = Expect::CommaOrEnd;
                    } else {
                        match self.bytes[self.i] {
                            b'{' => {
                                self.stack.push(Some(HashSet::new()));
                                self.i += 1;
                                expect = Expect::KeyOrEnd;
                            }
                            b'[' => {
                                self.stack.push(None);
                                self.i += 1;
                                expect = Expect::ValueOrEnd;
                            }
                            b'"' => {
                                if self.string(false).is_none() {
                                    return false;
                                }
                                expect = Expect::CommaOrEnd;
                            }
                            b't' | b'f' | b'n' => {
                                if !self.literal() {
                                    return false;
                                }
                                expect = Expect::CommaOrEnd;
                            }
                            b'-' | b'0'..=b'9' => {
                                if !self.number() {
                                    return false;
                                }
                                expect = Expect::CommaOrEnd;
                            }
                            _ => return false,
                        }
                    }
                }
                Expect::Key | Expect::KeyOrEnd => {
                    if expect == Expect::KeyOrEnd && self.bytes[self.i] == b'}' {
                        self.i += 1;
                        self.stack.pop();
                        expect = Expect::CommaOrEnd;
                    } else {
                        if self.bytes[self.i] != b'"' {
                            return false;
                        }
                        let Some(key) = self.string(true) else { return false };
                        let key: String = key.nfc().collect();
                        match self.stack.last_mut() {
                            Some(Some(keys)) => {
                                if !keys.insert(key) {
                                    self.duplicate = true;
                                    return false;
                                }
                            }
                            _ => return false,
                        }
                        self.space();
                        if self.i >= count || self.bytes[self.i] != b':' {
                            return false;
                        }
                        self.i += 1;
                        expect = Expect::Value;
                    }
                }
                Expect::CommaOrEnd => {
                    let Some(top) = self.stack.last() else { return false };
                    let array = top.is_none();
                    match (self.bytes[self.i], array) {
                        (b',', false) => expect = Expect::Key,
                        (b',', true) => expect = Expect::Value,
                        (b'}', false) | (b']', true) => {
                            self.stack.pop();
                            expect = Expect::CommaOrEnd;
                        }
                        _ => return false,
                    }
                    self.i += 1;
                }
            }
            self.space();
        }
        expect == Expect::CommaOrEnd && self.stack.is_empty()
    }

    fn space(&mut self) {
        while self.i < self.bytes.len()
            && matches!(self.bytes[self.i], b' ' | b'\n' | b'\r' | b'\t')
        {
            self.i += 1;
        }
    }

    fn literal(&mut self) -> bool {
        for word in [&b"true"[..], b"false", b"null"] {
            if self.bytes[self.i..].starts_with(word) {
                self.i += word.len();
                return true;
            }
        }
        false
    }

    fn digits(&mut self) -> bool {
        let start = self.i;
        while self.i < self.bytes.len() && self.bytes[self.i].is_ascii_digit() {
            self.i += 1;
        }
        self.i > start
    }

    fn number(&mut self) -> bool {
        let count = self.bytes.len();
        if self.bytes[self.i] == b'-' {
            self.i += 1;
        }
        if self.i >= count {
            return false;
        }
        match self.bytes[self.i] {
            b'0' => self.i += 1,
            b'1'..=b'9' => {
                self.digits();
            }
            _ => return false,
        }
        if self.i < count && self.bytes[self.i] == b'.' {
            self.i += 1;
            if !self.digits() {
                return false;
            }
        }
        if self.i < count && matches!(self.bytes[self.i], b'e' | b'E') {
            self.i += 1;
            if self.i < count && matches!(self.bytes[self.i], b'+' | b'-') {
                self.i += 1;
            }
            if !self.digits() {
                return false;
            }
        }
        true
    }

    fn hex4(&self, at: usize) -> Option<u32> {
        let digits = self.bytes.get(at..at + 4)?;
        let mut value = 0u32;
        for &b in digits {
            value = value << 4 | (b as char).to_digit(16)?;
        }
        Some(value)
    }

    /// The length of the well-formed UTF-8 sequence at `i`, or None.
    fn sequence(&self) -> Option<usize> {
        let count = self.bytes.len();
        let lead = self.bytes[self.i];
        let (length, second): (usize, (u8, u8)) = match lead {
            0x00..=0x7F => (1, (0x80, 0xBF)),
            0xC2..=0xDF => (2, (0x80, 0xBF)),
            0xE0 => (3, (0xA0, 0xBF)),
            0xE1..=0xEC | 0xEE..=0xEF => (3, (0x80, 0xBF)),
            0xED => (3, (0x80, 0x9F)),
            0xF0 => (4, (0x90, 0xBF)),
            0xF1..=0xF3 => (4, (0x80, 0xBF)),
            0xF4 => (4, (0x80, 0x8F)),
            _ => return None,
        };
        if self.i + length > count {
            return None;
        }
        if length > 1 && !(second.0..=second.1).contains(&self.bytes[self.i + 1]) {
            return None;
        }
        for k in 2..length {
            if !(0x80..=0xBF).contains(&self.bytes[self.i + k]) {
                return None;
            }
        }
        Some(length)
    }

    /// The string at `i` (a quote): its decoded text when `decode`, else an
    /// empty one. None when malformed.
    fn string(&mut self, decode: bool) -> Option<String> {
        let count = self.bytes.len();
        self.i += 1;
        let mut out: Vec<u8> = Vec::new();
        while self.i < count {
            let byte = self.bytes[self.i];
            if byte == b'"' {
                self.i += 1;
                return Some(if decode { String::from_utf8(out).ok()? } else { String::new() });
            }
            if byte < 0x20 {
                return None;
            }
            if byte == b'\\' {
                let escape = *self.bytes.get(self.i + 1)?;
                let escaped = match escape {
                    b'"' | b'\\' | b'/' => escape,
                    b'b' => 0x08,
                    b'f' => 0x0C,
                    b'n' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'u' => {
                        let mut scalar = self.hex4(self.i + 2)?;
                        self.i += 6;
                        if (0xD800..=0xDBFF).contains(&scalar) {
                            if self.bytes.get(self.i) != Some(&b'\\')
                                || self.bytes.get(self.i + 1) != Some(&b'u')
                            {
                                return None;
                            }
                            let low = self.hex4(self.i + 2)?;
                            if !(0xDC00..=0xDFFF).contains(&low) {
                                return None;
                            }
                            self.i += 6;
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00);
                        } else if (0xDC00..=0xDFFF).contains(&scalar) {
                            return None;
                        }
                        let c = char::from_u32(scalar)?;
                        if decode {
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
                        }
                        continue;
                    }
                    _ => return None,
                };
                if decode {
                    out.push(escaped);
                }
                self.i += 2;
                continue;
            }
            let length = self.sequence()?;
            if decode {
                out.extend_from_slice(&self.bytes[self.i..self.i + length]);
            }
            self.i += length;
        }
        None
    }
}

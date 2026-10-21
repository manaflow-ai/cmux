//! Forward-only recursive-descent JSON editor.
//!
//! It walks the input once, left to right, and writes the output as it goes.
//! A value whose path matches no trie node is located by a structural scan and
//! copied with one `extend_from_slice`: nothing in it can matter for
//! compatibility, so it is never parsed. Only members on a rule path are
//! looked at, and only subtrees with type changes or cross-parent moves are
//! parsed into values.
//!
//! The fast path does not validate the bytes it copies; the peer's own parser
//! still does. The parts the editor walks are checked and reported as
//! [`CompatError::Malformed`].

use serde_json::Value;

use crate::CompatError;
use crate::trie::Node;

pub(crate) fn rewrite(root: &Node, input: &[u8], out: &mut Vec<u8>) -> Result<(), CompatError> {
    let mut editor = Editor { input, pos: 0, out };
    editor.ws();
    editor.value(Some(root))?;
    let tail = editor.pos;
    editor.ws();
    if editor.pos != input.len() {
        return Err(CompatError::Malformed(editor.pos));
    }
    // Keep framing whitespace (a trailing newline) as it was.
    editor.out.extend_from_slice(&input[tail..]);
    Ok(())
}

struct Editor<'a, 'o> {
    input: &'a [u8],
    pos: usize,
    out: &'o mut Vec<u8>,
}

/// Byte classes for the structural scan.
const PLAIN: u8 = 0;
const QUOTE: u8 = 1;
const OPEN: u8 = 2;
const CLOSE: u8 = 3;

static CLASS: [u8; 256] = {
    let mut table = [PLAIN; 256];
    table[b'"' as usize] = QUOTE;
    table[b'{' as usize] = OPEN;
    table[b'[' as usize] = OPEN;
    table[b'}' as usize] = CLOSE;
    table[b']' as usize] = CLOSE;
    table
};

impl Editor<'_, '_> {
    #[inline]
    fn ws(&mut self) {
        while let Some(b' ' | b'\n' | b'\r' | b'\t') = self.input.get(self.pos) {
            self.pos += 1;
        }
    }

    #[inline]
    fn peek(&self) -> Result<u8, CompatError> {
        self.input.get(self.pos).copied().ok_or(CompatError::Malformed(self.pos))
    }

    fn expect_byte(&mut self, byte: u8) -> Result<(), CompatError> {
        if self.peek()? != byte {
            return Err(CompatError::Malformed(self.pos));
        }
        self.pos += 1;
        Ok(())
    }

    /// End (exclusive) of the string starting at `start` (on its quote).
    #[inline]
    fn string_end(&self, start: usize) -> Result<usize, CompatError> {
        let bytes = self.input;
        let mut i = start + 1;
        loop {
            match bytes.get(i) {
                Some(b'"') => return Ok(i + 1),
                Some(b'\\') => i += 2,
                Some(_) => i += 1,
                None => return Err(CompatError::Malformed(start)),
            }
        }
    }

    /// End (exclusive) of the value starting at `self.pos`, without parsing it.
    fn value_end(&self) -> Result<usize, CompatError> {
        let bytes = self.input;
        let start = self.pos;
        match self.peek()? {
            b'"' => self.string_end(start),
            b'{' | b'[' => {
                let mut depth = 0usize;
                let mut i = start;
                while i < bytes.len() {
                    match CLASS[bytes[i] as usize] {
                        PLAIN => i += 1,
                        QUOTE => i = self.string_end(i)?,
                        OPEN => {
                            depth += 1;
                            i += 1;
                        }
                        _ => {
                            depth -= 1;
                            i += 1;
                            if depth == 0 {
                                return Ok(i);
                            }
                        }
                    }
                }
                Err(CompatError::Malformed(start))
            }
            _ => {
                let mut i = start;
                while let Some(&b) = bytes.get(i) {
                    if matches!(b, b',' | b'}' | b']' | b' ' | b'\n' | b'\r' | b'\t') {
                        break;
                    }
                    i += 1;
                }
                if i == start {
                    return Err(CompatError::Malformed(start));
                }
                Ok(i)
            }
        }
    }

    fn copy_value(&mut self) -> Result<(), CompatError> {
        let end = self.value_end()?;
        self.out.extend_from_slice(&self.input[self.pos..end]);
        self.pos = end;
        Ok(())
    }

    fn skip_value(&mut self) -> Result<(), CompatError> {
        self.pos = self.value_end()?;
        Ok(())
    }

    fn value(&mut self, node: Option<&Node>) -> Result<(), CompatError> {
        let Some(node) = node.filter(|n| !n.is_identity()) else {
            return self.copy_value();
        };
        if !node.slow.is_empty() {
            return self.materialize(node);
        }
        match self.peek()? {
            b'{' => self.object(node),
            b'[' => self.array(node),
            _ => self.copy_value(),
        }
    }

    fn materialize(&mut self, node: &Node) -> Result<(), CompatError> {
        let end = self.value_end()?;
        let mut value: Value = serde_json::from_slice(&self.input[self.pos..end])
            .map_err(|_| CompatError::Malformed(self.pos))?;
        node.apply_value(&mut value);
        serde_json::to_writer(&mut *self.out, &value)
            .map_err(|_| CompatError::Malformed(self.pos))?;
        self.pos = end;
        Ok(())
    }

    fn array(&mut self, node: &Node) -> Result<(), CompatError> {
        self.pos += 1;
        self.out.push(b'[');
        let element = node.wild.as_deref();
        self.ws();
        if self.peek()? == b']' {
            self.pos += 1;
            self.out.push(b']');
            return Ok(());
        }
        loop {
            self.ws();
            self.value(element)?;
            self.ws();
            match self.peek()? {
                b',' => {
                    self.pos += 1;
                    self.out.push(b',');
                }
                b']' => {
                    self.pos += 1;
                    self.out.push(b']');
                    return Ok(());
                }
                _ => return Err(CompatError::Malformed(self.pos)),
            }
        }
    }

    fn object(&mut self, node: &Node) -> Result<(), CompatError> {
        self.pos += 1;
        self.out.push(b'{');
        let mut first = true;
        let mut seen = if node.has_defaults { vec![false; node.members.len()] } else { Vec::new() };
        self.ws();
        if self.peek()? == b'}' {
            self.pos += 1;
        } else {
            loop {
                self.ws();
                if self.peek()? != b'"' {
                    return Err(CompatError::Malformed(self.pos));
                }
                let key_start = self.pos;
                let key_end = self.string_end(key_start)?;
                let raw_key = &self.input[key_start..key_end];
                self.pos = key_end;
                self.ws();
                self.expect_byte(b':')?;
                self.ws();
                let inner = &raw_key[1..raw_key.len() - 1];
                let decoded;
                let key: &str = if inner.contains(&b'\\') {
                    decoded = serde_json::from_slice::<String>(raw_key)
                        .map_err(|_| CompatError::Malformed(key_start))?;
                    &decoded
                } else {
                    std::str::from_utf8(inner).map_err(|_| CompatError::Malformed(key_start))?
                };
                match node.lookup(key) {
                    Some(index) => {
                        let member = &node.members[index];
                        if let Some(flag) = seen.get_mut(index) {
                            *flag = true;
                        }
                        if member.output.is_some() {
                            if !first {
                                self.out.push(b',');
                            }
                            first = false;
                            self.out.extend_from_slice(&member.output_json);
                            self.value(Some(&member.node))?;
                        } else {
                            self.skip_value()?;
                        }
                    }
                    None if node.drops(key) => self.skip_value()?,
                    None => {
                        if !first {
                            self.out.push(b',');
                        }
                        first = false;
                        self.out.extend_from_slice(raw_key);
                        self.out.push(b':');
                        self.value(node.wild.as_deref())?;
                    }
                }
                self.ws();
                match self.peek()? {
                    b',' => self.pos += 1,
                    b'}' => {
                        self.pos += 1;
                        break;
                    }
                    _ => return Err(CompatError::Malformed(self.pos)),
                }
            }
        }
        if node.has_defaults {
            for (index, member) in node.members.iter().enumerate() {
                if seen[index] || member.output.is_none() {
                    continue;
                }
                if let Some(default) = &member.default {
                    if !first {
                        self.out.push(b',');
                    }
                    first = false;
                    self.out.extend_from_slice(&member.output_json);
                    serde_json::to_writer(&mut *self.out, default)
                        .map_err(|_| CompatError::Malformed(self.pos))?;
                }
            }
        }
        self.out.push(b'}');
        Ok(())
    }
}

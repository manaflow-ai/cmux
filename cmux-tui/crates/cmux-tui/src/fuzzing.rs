//! Fuzz entry points for the cmux-tui/fuzz workspace (feature `fuzzing`).
//!
//! Each `*_one_input` takes libFuzzer bytes and drives one decoder or
//! scheduler of this crate with no terminal, socket or session, the way
//! Chromium's fuzzers call a component's own entry point
//! (testing/libfuzzer/getting_started.md). The schedulers run on their own
//! state, single threaded, so an input replays the same interleaving every
//! time. A panic or a broken accounting invariant is a finding.

/// A cursor over fuzz bytes. Reads past the end return `None`, which ends
/// the op stream.
pub(crate) struct FuzzBytes<'a> {
    data: &'a [u8],
}

impl<'a> FuzzBytes<'a> {
    pub(crate) fn new(data: &'a [u8]) -> Self {
        Self { data }
    }

    pub(crate) fn byte(&mut self) -> Option<u8> {
        let (&first, rest) = self.data.split_first()?;
        self.data = rest;
        Some(first)
    }

    pub(crate) fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes([self.byte()?, self.byte()?]))
    }

    pub(crate) fn flag(&mut self) -> Option<bool> {
        self.byte().map(|byte| byte & 1 == 1)
    }

    /// Up to `len` bytes, fewer at the end of the input.
    pub(crate) fn take(&mut self, len: usize) -> &'a [u8] {
        let (head, rest) = self.data.split_at(len.min(self.data.len()));
        self.data = rest;
        head
    }

    pub(crate) fn rest(&mut self) -> &'a [u8] {
        std::mem::take(&mut self.data)
    }

    /// One of `items`, picked by the next byte.
    pub(crate) fn pick<T: Copy>(&mut self, items: &[T]) -> Option<T> {
        let byte = self.byte()?;
        items.get(usize::from(byte) % items.len()).copied()
    }
}

/// The ordered PTY input scheduler (`pty_input`): enqueue, dequeue, operation
/// completion, retirement, reservation cancel and generation switches in any
/// order, with remote timeouts and transport failures.
pub fn pty_input_one_input(data: &[u8]) {
    crate::pty_input::fuzz::one_input(data);
}

/// The browser input scheduler (`browser_input`): per-surface lanes, global
/// admission, fallbacks for releases and resizes, lane eviction and retirement.
pub fn browser_input_one_input(data: &[u8]) {
    crate::browser_input::fuzz::one_input(data);
}

/// Host key decoding (`keys`): crossterm's byte parser, `KeyboardInput`
/// normalization and the ghostty key encoder in a fuzz-chosen terminal mode.
pub fn keys_one_input(data: &[u8]) {
    crate::keys::fuzz::one_input(data);
}

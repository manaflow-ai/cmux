//! Mouse encoding on `Surface`: encode pointer input against the terminal's
//! current mouse mode, optionally guarded by the semantics or snapshot the
//! frontend rendered.

use super::*;

impl Surface {
    pub fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode(input, output)),
            Err(TryLockError::Poisoned(error)) => Some(error.into_inner().encode(input, output)),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    /// Encode only when the terminal still matches the semantics captured
    /// with the rendered frame. The terminal and encoder locks stay held
    /// across comparison and encoding so parser updates cannot interleave.
    pub fn encode_mouse_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode(input, output)))
    }

    /// Encode only when both terminal semantics and content still match the
    /// immutable frame that admitted this uncaptured pointer event.
    pub fn encode_mouse_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected.semantics {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        if pty.render_generation.load(Ordering::Acquire) != expected.content_generation {
            return Some(GuardedMouseEncode::ContentChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode(input, output)))
    }

    pub fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode_release(input, output)),
            Err(TryLockError::Poisoned(error)) => {
                Some(error.into_inner().encode_release(input, output))
            }
            Err(TryLockError::WouldBlock) => None,
        }
    }

    pub fn encode_mouse_press_pair(
        &self,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => {
                Some(encoders.encode_press_pair(press, release, press_output, release_output))
            }
            Err(TryLockError::Poisoned(error)) => Some(error.into_inner().encode_press_pair(
                press,
                release,
                press_output,
                release_output,
            )),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    /// Encode a press and its matching release against one rendered terminal
    /// semantic snapshot, without a parser update between validation and
    /// encoding either half.
    pub fn encode_mouse_press_pair_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode_press_pair(
            press,
            release,
            press_output,
            release_output,
        )))
    }

    /// Encode a press and its matching release only while the terminal still
    /// matches the immutable content frame that admitted the press.
    pub fn encode_mouse_press_pair_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected.semantics {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        if pty.render_generation.load(Ordering::Acquire) != expected.content_generation {
            return Some(GuardedMouseEncode::ContentChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode_press_pair(
            press,
            release,
            press_output,
            release_output,
        )))
    }

    pub fn reset_mouse_motion_dedupe(&self) {
        let Some(pty) = self.as_pty() else { return };
        pty.mouse_encoders.lock().unwrap().reset_motion_dedupe();
    }
}

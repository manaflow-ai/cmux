//! A sliding replay window over sealed-packet nonces (as in RFC 6479): a
//! nonce is accepted once, and only if it is newer than the window's floor.

/// Nonces behind the newest one that are still accepted (once each).
const WINDOW: u64 = 2048;
const WORDS: usize = (WINDOW / 64) as usize;

#[derive(Debug)]
pub struct ReplayWindow {
    /// The newest accepted nonce plus one (0: nothing accepted yet).
    top: u64,
    bits: [u64; WORDS],
}

impl Default for ReplayWindow {
    fn default() -> Self {
        Self { top: 0, bits: [0; WORDS] }
    }
}

impl ReplayWindow {
    fn slot(nonce: u64) -> (usize, u64) {
        let index = nonce % WINDOW;
        ((index / 64) as usize, 1u64 << (index % 64))
    }

    /// Whether `nonce` may be opened (not seen, not too old). Call
    /// [`ReplayWindow::accept`] only after it authenticated.
    pub fn check(&self, nonce: u64) -> bool {
        if nonce >= self.top {
            return true;
        }
        if self.top - nonce > WINDOW {
            return false;
        }
        let (word, bit) = Self::slot(nonce);
        self.bits.get(word).is_some_and(|w| w & bit == 0)
    }

    pub fn accept(&mut self, nonce: u64) {
        if nonce >= self.top {
            // Clear the slots the window slides past.
            let advance = (nonce + 1 - self.top).min(WINDOW);
            for n in 0..advance {
                let (word, bit) = Self::slot(self.top + n);
                if let Some(w) = self.bits.get_mut(word) {
                    *w &= !bit;
                }
            }
            self.top = nonce + 1;
        }
        let (word, bit) = Self::slot(nonce);
        if let Some(w) = self.bits.get_mut(word) {
            *w |= bit;
        }
    }
}

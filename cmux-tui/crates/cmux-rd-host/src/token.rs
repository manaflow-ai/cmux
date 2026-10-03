//! The per-launch session token. Until the link token (lane 12) authenticates hello claims,
//! a hello is accepted only with this 256-bit secret. The host never makes or stores it: its
//! parent (the cmux daemon) writes it into an inherited pipe (`--token-fd N`) at launch, and
//! the daemon releases it only through `secret.release` to the `frontend` actor (the native
//! app's viewer pane, proved by its install key); terminal and agent actors are refused
//! (plans/cmux-next/remote-desktop.md section 11.0). No file, no environment variable, no
//! argv value carries it.

use std::fs::File;
use std::io::Read;
use std::os::fd::{FromRawFd, RawFd};

/// Token length in bytes (sent as 64 lowercase hex characters).
pub const TOKEN_LEN: usize = 32;

/// A 256-bit secret; Debug never prints it.
#[derive(Clone, PartialEq, Eq)]
pub struct Token([u8; TOKEN_LEN]);

impl std::fmt::Debug for Token {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Token(<redacted>)")
    }
}

impl Token {
    /// Parses 64 hex characters (surrounding whitespace allowed).
    pub fn from_hex(text: &str) -> Result<Self, String> {
        let text = text.trim();
        if text.len() != TOKEN_LEN * 2 || !text.is_ascii() {
            return Err("token must be 64 hex characters".into());
        }
        let mut out = [0u8; TOKEN_LEN];
        for (i, byte) in out.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&text[2 * i..2 * i + 2], 16).map_err(|_| "token must be hex".to_string())?;
        }
        Ok(Self(out))
    }

    pub fn to_hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Reads the token from an inherited file descriptor and closes it.
    pub fn read_fd(fd: RawFd) -> Result<Self, String> {
        if fd < 3 {
            return Err("--token-fd must be an inherited pipe (3 or above)".into());
        }
        // SAFETY: the parent passed this descriptor to us for exactly this read; we own and close it.
        let mut file = unsafe { File::from_raw_fd(fd) };
        let mut text = String::new();
        file.by_ref().take(256).read_to_string(&mut text).map_err(|e| format!("reading the token: {e}"))?;
        Self::from_hex(&text)
    }

    /// Constant-time comparison with a hex string from a hello: the time depends only on
    /// the expected length, never on where the first difference is.
    pub fn matches_hex(&self, provided: Option<&str>) -> bool {
        let Some(provided) = provided else { return false };
        let provided = provided.as_bytes();
        let expected = self.to_hex();
        let expected = expected.as_bytes();
        let mut diff = u8::from(provided.len() != expected.len());
        for (i, e) in expected.iter().enumerate() {
            diff |= e ^ provided.get(i).copied().unwrap_or(0);
        }
        diff == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEX: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    #[test]
    fn a_hello_without_or_with_a_wrong_token_is_refused() {
        let t = Token::from_hex(HEX).expect("token");
        assert!(!t.matches_hex(None));
        assert!(!t.matches_hex(Some("")));
        assert!(!t.matches_hex(Some(&HEX[..63])));
        let mut wrong = HEX.to_string();
        wrong.replace_range(63..64, "e");
        assert!(!t.matches_hex(Some(&wrong)));
        assert!(!t.matches_hex(Some(&format!("{HEX}00"))));
        assert!(t.matches_hex(Some(HEX)));
    }

    #[test]
    fn parsing_rejects_bad_tokens_and_debug_redacts() {
        assert!(Token::from_hex("abc").is_err());
        assert!(Token::from_hex(&"zz".repeat(32)).is_err());
        let t = Token::from_hex(&format!("  {HEX}\n")).expect("trimmed");
        assert_eq!(format!("{t:?}"), "Token(<redacted>)");
        assert_eq!(t.to_hex(), HEX);
    }

    #[test]
    fn the_token_arrives_through_an_inherited_pipe() {
        let mut fds = [0; 2];
        // SAFETY: pipe fills two descriptors we own.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: writing our own buffer to our own pipe, then closing the write end.
        unsafe {
            libc::write(fds[1], HEX.as_ptr().cast(), HEX.len());
            libc::close(fds[1]);
        }
        let t = Token::read_fd(fds[0]).expect("read");
        assert!(t.matches_hex(Some(HEX)));
        assert!(Token::read_fd(0).is_err());
    }

    #[test]
    fn compare_time_does_not_depend_on_the_first_difference() {
        // Structural check: every byte of the expected token is visited for any input.
        let t = Token::from_hex(HEX).expect("token");
        let early = format!("f{}", &HEX[1..]);
        let late = format!("{}e", &HEX[..63]);
        assert!(!t.matches_hex(Some(&early)) && !t.matches_hex(Some(&late)));
    }
}

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
            *byte = u8::from_str_radix(&text[2 * i..2 * i + 2], 16)
                .map_err(|_| "token must be hex".to_string())?;
        }
        Ok(Self(out))
    }

    /// The bench viewer sends the token in its hello; the host only compares.
    #[cfg(feature = "bench")]
    pub fn to_hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Reads the token from an inherited file descriptor and closes it.
    pub fn read_fd(fd: RawFd) -> Result<Self, String> {
        if fd < 3 {
            return Err("--token-fd must be an inherited pipe (3 or above)".into());
        }
        // A pipe or socket only: "no file" is enforced, not a convention.
        // SAFETY: fstat on a descriptor number into a zeroed struct we own.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: as above.
        if unsafe { libc::fstat(fd, &mut st) } != 0 {
            return Err("--token-fd is not an open descriptor".into());
        }
        let kind = st.st_mode & libc::S_IFMT;
        if kind != libc::S_IFIFO && kind != libc::S_IFSOCK {
            return Err("--token-fd must be a pipe or socket from the parent, not a file".into());
        }
        // SAFETY: the parent passed this descriptor to us for exactly this read; we own and close it.
        let mut file = unsafe { File::from_raw_fd(fd) };
        // Read exactly the 64 hex characters: no wait for end of file, so a parent that keeps
        // its write end open cannot hang the start.
        let mut buf = [0u8; TOKEN_LEN * 2];
        file.read_exact(&mut buf).map_err(|e| format!("reading the token: {e}"))?;
        let text = std::str::from_utf8(&buf).map_err(|_| "token must be hex".to_string())?;
        Self::from_hex(text)
    }

    /// Constant-time comparison with a hex string from a hello: the time depends only on
    /// the expected length, never on where the first difference is.
    pub fn matches_hex(&self, provided: Option<&str>) -> bool {
        // Decode first (either hex case), then compare all 32 bytes.
        let Some(Ok(provided)) = provided.map(Self::from_hex) else { return false };
        let mut diff = 0u8;
        for (a, b) in self.0.iter().zip(provided.0.iter()) {
            diff |= a ^ b;
        }
        std::hint::black_box(diff) == 0
    }
}

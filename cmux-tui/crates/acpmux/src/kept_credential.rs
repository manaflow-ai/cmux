//! A hibernated chat's delivered launch credential, kept across a daemon that ends without a
//! handoff (a crash, a SIGKILL, a rollback's restart): `agent_credentials.rs` "Left open".
//!
//! The credential lives in memory only (`agent_credentials.rs`): a live agent carries it in its
//! env, which an adopting daemon reads back. A hibernated chat has no agent, so before this the
//! credential sat in the ending daemon's memory alone and the chat's next start ran on no login
//! (Claude's "Not logged in"; the carrier chaos probe's agent daemon restart, cmuxterm-hq
//! `goals/cloud-resume-no-lost-output.md`). While it sleeps, it is also kept in the kernel's
//! per-user keyring (Linux `add_key(2)`): kernel memory, never a file, gone at reboot like the
//! daemon's own. Only this user's processes can read it, the same ones that can read a live
//! agent's `/proc/PID/environ`, the existing recovery source. It is kept from the hibernation
//! ([`keep`]) until the chat is no longer hibernated or its credential is withdrawn ([`forget`]),
//! with a kernel timeout ([`TIMEOUT_S`]) for a chat closed while asleep. A daemon that loads a
//! hibernated chat reads it back ([`read`]) through the same checks as an agent's env
//! (`agent_credentials::recovered_from_launch`). Elsewhere (not Linux, or a sandbox without
//! keyrings) nothing is kept and a crash still loses it, as before. Names only are ever logged.

use crate::agent_credentials::AgentCredential;

/// A kept credential the kernel drops by itself: a chat closed or deleted while asleep.
pub(crate) const TIMEOUT_S: u32 = 7 * 24 * 3600;

fn description(session: &str) -> String {
    format!("acpmux-launch-credential:{session}")
}

/// The variables of `credential` as one `NAME=value` NUL-separated list (an env's own shape).
fn payload(credential: &AgentCredential) -> Vec<u8> {
    let mut out = Vec::new();
    for (name, value) in crate::agent_credentials::launch_pairs(credential) {
        out.extend_from_slice(name.as_bytes());
        out.push(b'=');
        out.extend_from_slice(value.as_bytes());
        out.push(0);
    }
    out
}

fn parse(bytes: &[u8]) -> Option<AgentCredential> {
    let pairs: Vec<(String, String)> = bytes
        .split(|b| *b == 0)
        .filter_map(|entry| {
            let (k, v) = std::str::from_utf8(entry).ok()?.split_once('=')?;
            Some((k.to_owned(), v.to_owned()))
        })
        .collect();
    crate::agent_credentials::recovered_from_launch(&pairs)
}

/// Keeps `credential` for `session` while its agent sleeps. Whether the kernel took it.
pub(crate) fn keep(session: &str, credential: &AgentCredential) -> bool {
    let mut bytes = payload(credential);
    let kept = sys::add(&description(session), &bytes);
    bytes.fill(0);
    let names: Vec<&str> = credential.names().collect();
    match kept {
        Ok(()) => tracing::info!(
            session,
            ?names,
            "a hibernated chat's launch credential is kept in the user keyring"
        ),
        Err(e) => {
            tracing::info!(session, ?names, error = %e, "the user keyring took no launch credential: a daemon crash while it sleeps loses it")
        }
    }
    kept.is_ok()
}

/// The credential [`keep`] kept for `session`, if any. It stays kept until [`forget`].
pub(crate) fn read(session: &str) -> Option<AgentCredential> {
    let mut bytes = sys::read(&description(session)).ok()??;
    let credential = parse(&bytes);
    bytes.fill(0);
    credential
}

/// Drops what [`keep`] kept for `session`; none kept is no error.
pub(crate) fn forget(session: &str) {
    sys::forget(&description(session));
}

#[cfg(target_os = "linux")]
mod sys {
    use std::ffi::CString;
    use std::io;

    const KEY_SPEC_USER_KEYRING: libc::c_long = -4;
    const KEYCTL_SETPERM: libc::c_long = 5;
    const KEYCTL_UNLINK: libc::c_long = 9;
    const KEYCTL_SEARCH: libc::c_long = 10;
    const KEYCTL_READ: libc::c_long = 11;
    const KEYCTL_SET_TIMEOUT: libc::c_long = 15;
    const KEYCTL_INVALIDATE: libc::c_long = 21;
    /// Possessor: everything. The user (this uid's later daemon, whose session keyring may not
    /// possess the user keyring under a service manager): view, read, write, search, setattr.
    const PERM: libc::c_long = 0x3f00_0000 | 0x002f_0000;
    /// The largest payload: one credential (`agent_credentials` bounds a value to 16 KiB) and
    /// its endpoint.
    const MAX: usize = 64 * 1024;

    fn ok(n: libc::c_long) -> io::Result<libc::c_long> {
        if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n) }
    }

    fn search(desc: &CString) -> io::Result<libc::c_long> {
        // SAFETY: `keyctl(KEYCTL_SEARCH, ring, type, desc, dest)` with NUL-terminated strings.
        ok(unsafe {
            libc::syscall(
                libc::SYS_keyctl,
                KEYCTL_SEARCH,
                KEY_SPEC_USER_KEYRING,
                c"user".as_ptr(),
                desc.as_ptr(),
                0 as libc::c_long,
            )
        })
    }

    pub(super) fn add(desc: &str, payload: &[u8]) -> io::Result<()> {
        let desc = CString::new(desc).map_err(io::Error::other)?;
        // SAFETY: `add_key(type, desc, payload, len, ring)`; the payload outlives the call.
        let key = ok(unsafe {
            libc::syscall(
                libc::SYS_add_key,
                c"user".as_ptr(),
                desc.as_ptr(),
                payload.as_ptr().cast::<libc::c_void>(),
                payload.len(),
                KEY_SPEC_USER_KEYRING,
            )
        })?;
        // SAFETY: `keyctl(KEYCTL_SETPERM, key, perm)` and `keyctl(KEYCTL_SET_TIMEOUT, key, s)`.
        let set = ok(unsafe { libc::syscall(libc::SYS_keyctl, KEYCTL_SETPERM, key, PERM) })
            .and_then(|_| {
                ok(unsafe {
                    libc::syscall(
                        libc::SYS_keyctl,
                        KEYCTL_SET_TIMEOUT,
                        key,
                        super::TIMEOUT_S as libc::c_long,
                    )
                })
            });
        if let Err(e) = set {
            // A key another daemon cannot read, or one with no end, is not kept.
            // SAFETY: `keyctl(KEYCTL_INVALIDATE, key)`.
            unsafe { libc::syscall(libc::SYS_keyctl, KEYCTL_INVALIDATE, key) };
            return Err(e);
        }
        Ok(())
    }

    pub(super) fn read(desc: &str) -> io::Result<Option<Vec<u8>>> {
        let desc = CString::new(desc).map_err(io::Error::other)?;
        let key = match search(&desc) {
            Ok(key) => key,
            Err(e)
                if matches!(
                    e.raw_os_error(),
                    Some(libc::ENOKEY | libc::EKEYEXPIRED | libc::EKEYREVOKED)
                ) =>
            {
                return Ok(None);
            }
            Err(e) => return Err(e),
        };
        let mut buf = vec![0u8; MAX];
        // SAFETY: `keyctl(KEYCTL_READ, key, buf, len)` writes at most `len` bytes into `buf`.
        let n = ok(unsafe {
            libc::syscall(
                libc::SYS_keyctl,
                KEYCTL_READ,
                key,
                buf.as_mut_ptr().cast::<libc::c_void>(),
                buf.len(),
            )
        })? as usize;
        if n > buf.len() {
            buf.fill(0);
            return Ok(None);
        }
        buf.truncate(n);
        Ok(Some(buf))
    }

    pub(super) fn forget(desc: &str) {
        let Ok(desc) = CString::new(desc) else { return };
        while let Ok(key) = search(&desc) {
            // SAFETY: `keyctl(KEYCTL_INVALIDATE, key)`, else unlinked from the user keyring.
            let gone = unsafe { libc::syscall(libc::SYS_keyctl, KEYCTL_INVALIDATE, key) } == 0
                || unsafe {
                    libc::syscall(libc::SYS_keyctl, KEYCTL_UNLINK, key, KEY_SPEC_USER_KEYRING)
                } == 0;
            if !gone {
                return;
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod sys {
    use std::io;

    pub(super) fn add(_desc: &str, _payload: &[u8]) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no kernel keyring here"))
    }

    pub(super) fn read(_desc: &str) -> io::Result<Option<Vec<u8>>> {
        Ok(None)
    }

    pub(super) fn forget(_desc: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn credential() -> AgentCredential {
        AgentCredential::parse(&serde_json::json!({
            "env": {"CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-kept-credential-test-token"}
        }))
        .unwrap()
    }

    #[test]
    fn payload_reads_back_as_the_same_credential() {
        let credential = credential();
        assert_eq!(parse(&payload(&credential)).as_ref(), Some(&credential));
    }

    /// Kept, read back by a later reader, and forgotten. A kernel or sandbox without keyrings
    /// (`keep` false) keeps nothing, and then nothing reads back.
    #[test]
    fn kept_credential_reads_back_until_forgotten() {
        let session = format!("kept-test-{}", uuid::Uuid::now_v7());
        let credential = credential();
        let kept = keep(&session, &credential);
        if cfg!(target_os = "linux") && !kept {
            eprintln!("no user keyring in this sandbox: keep refused, nothing is kept");
        }
        assert_eq!(read(&session).as_ref(), kept.then_some(&credential));
        forget(&session);
        assert!(read(&session).is_none());
    }
}

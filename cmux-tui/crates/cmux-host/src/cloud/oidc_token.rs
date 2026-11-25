//! Keyless cloud credentials (https://github.com/manaflow-ai/cmux/issues/48427, exploratory): this machine's
//! OIDC token from its team's cmux issuer (`POST /v1/cloud/oidc/token` as the machine's own `vm` install,
//! cmux-platform `src/server/cloud/OidcRoute.ts`), kept fresh in [`TOKEN_FILE`] like a cloud metadata service, so a customer's
//! cloud SDK reads it through workload identity federation: `AWS_WEB_IDENTITY_TOKEN_FILE`, a GCP
//! external-account `credential_source.file`, Vault's `jwt` login, `AZURE_FEDERATED_TOKEN_FILE`.
//!
//! Opt-in: only while the work user's `~/.config/cmux/oidc/audience` names an audience (one line, the
//! audience the customer's cloud expects, such as `sts.amazonaws.com`). The marker is read without
//! following a link, only as a regular file of the work user, and at most [`MAX_AUDIENCE`] bytes. Without
//! it the token file is removed. The token is written 0600 for the work user in a folder only root writes
//! (`gateway_token::write_token`), renewed when less than half its life is left, and never logged. The file
//! never holds a token for another audience or an expired one: it is removed first when the marker changes,
//! and once the held token expires (both checked every minute). A failing issuer is asked again with backoff
//! (up to [`MAX_BACKOFF`]), logged once per run of failures.

use std::fs;
use std::io::Read as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use super::client::{CloudClient, Http};
use super::sender::Answer;
use crate::daemon_spec::{WORK_HOME, WORK_USER};
use crate::linux::spawn::lookup_user;

/// Straight under root's `/run`, like the gateway token: no folder above the file is the work user's.
pub const TOKEN_DIR: &str = "/run/cmux-oidc";
pub const TOKEN_FILE: &str = "/run/cmux-oidc/token";
/// The longest audience the issuer accepts (cmux-platform `Oidc.ts` AUDIENCE).
pub const MAX_AUDIENCE: usize = 256;
/// The token life asked for; it is renewed once half of it is gone.
pub const TTL_SECONDS: u64 = 900;
const EVERY: Duration = Duration::from_secs(60);
/// The longest wait between asks while the issuer refuses or does not answer (it is off where the backend has
/// no cloud credentials, such as production for now).
pub const MAX_BACKOFF: Duration = Duration::from_secs(30 * 60);

static GENERATION: AtomicU64 = AtomicU64::new(0);

pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/oidc/audience")
}

/// The audience the marker names, if it is a regular file of `owner_uid` holding one printable line.
pub fn read_audience(path: &Path, owner_uid: u32) -> Option<String> {
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.uid() != owner_uid || meta.len() > (MAX_AUDIENCE + 2) as u64 {
        return None;
    }
    let mut text = String::new();
    file.by_ref().take((MAX_AUDIENCE + 2) as u64).read_to_string(&mut text).ok()?;
    let audience = text.trim();
    let printable = !audience.is_empty()
        && audience.len() <= MAX_AUDIENCE
        && audience.bytes().all(|b| (0x21..=0x7e).contains(&b));
    printable.then(|| audience.to_owned())
}

/// The token and its expiry (ms) from the issuer's answer, or the refusal to log.
pub fn token_of(answer: &Answer) -> Result<(String, u64), String> {
    match answer {
        Answer::Http { status: 200, body } => {
            let token = body.get("token").and_then(|t| t.as_str()).filter(|t| !t.is_empty());
            let expires = body.get("expires_at").and_then(|e| e.as_u64());
            match (token, expires) {
                (Some(t), Some(e)) => Ok((t.to_owned(), e)),
                _ => Err("the issuer's answer has no token".into()),
            }
        }
        Answer::Http { status, body } => {
            let code = body
                .get("error")
                .and_then(|e| e.get("code"))
                .and_then(|c| c.as_str())
                .unwrap_or("");
            Err(format!("the issuer refused ({status} {code})"))
        }
        Answer::Transport => Err("the issuer did not answer".into()),
    }
}

/// Whether a token minted for `audience` that expires at `expires_ms` should be renewed at `now_ms`.
pub fn renew(held: Option<&(String, u64)>, audience: &str, now_ms: u64) -> bool {
    match held {
        None => true,
        Some((aud, expires)) => {
            aud != audience || expires.saturating_sub(now_ms) < TTL_SECONDS * 1000 / 2
        }
    }
}

/// Whether the token in the file must go before anything else at `now_ms`: it is for another audience, or expired.
pub fn stale(held: Option<&(String, u64)>, audience: Option<&str>, now_ms: u64) -> bool {
    held.is_some_and(|(aud, expires)| audience.is_some_and(|a| a != aud) || *expires <= now_ms)
}

/// The wait before the next ask after `failures` failures in a row: EVERY, doubling, at most MAX_BACKOFF.
pub fn backoff(failures: u32) -> Duration {
    EVERY.saturating_mul(1 << failures.min(5)).min(MAX_BACKOFF)
}

/// Stops the thread when dropped (a rebind replaces it).
pub struct OidcToken {
    stop: Arc<AtomicBool>,
}

impl Drop for OidcToken {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl OidcToken {
    pub fn spawn<H: Http + Send + 'static>(
        mut client: CloudClient<H>,
        now_wall_ms: fn() -> u64,
        log: fn(&str),
    ) -> std::io::Result<OidcToken> {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        let newest = move || GENERATION.load(Ordering::SeqCst) == generation;
        std::thread::Builder::new().name("cmux-host-oidc-token".to_owned()).spawn(move || {
            let marker = marker(Path::new(WORK_HOME));
            // (audience, expires_ms) of the token in the file.
            let mut held: Option<(String, u64)> = None;
            let mut failures: u32 = 0;
            // While the issuer fails, the next ask waits until here; the marker and expiry are still checked
            // every EVERY, so a removed marker or an expired token leaves the file within a minute.
            let mut next_ask_ms: u64 = 0;
            let remove = |held: &mut Option<(String, u64)>| {
                if newest() && (held.is_some() || Path::new(TOKEN_FILE).exists()) {
                    let _ = fs::remove_file(TOKEN_FILE);
                }
                *held = None;
            };
            while !stopping.load(Ordering::SeqCst) && newest() {
                let audience = lookup_user(WORK_USER).and_then(|u| read_audience(&marker, u.uid));
                let now = now_wall_ms();
                if audience.is_none() || stale(held.as_ref(), audience.as_deref(), now) {
                    remove(&mut held);
                }
                if let Some(audience) = audience
                    && renew(held.as_ref(), &audience, now)
                    && now >= next_ask_ms
                {
                    let answer = client.oidc_token(&audience, TTL_SECONDS, now_wall_ms());
                    match token_of(&answer).and_then(|(t, e)| {
                        super::gateway_token::write_token(Path::new(TOKEN_DIR), &t).map(|()| e)
                    }) {
                        Ok(expires) => {
                            if held.is_none() {
                                log("cloud credentials: this machine's OIDC token is kept in /run/cmux-oidc/token");
                            }
                            held = Some((audience, expires));
                            failures = 0;
                            next_ask_ms = 0;
                        }
                        Err(e) => {
                            if failures == 0 {
                                log(&format!("cloud credentials token: {e}; asking again with backoff"));
                            }
                            failures = failures.saturating_add(1);
                            next_ask_ms = now_wall_ms().saturating_add(backoff(failures).as_millis() as u64);
                        }
                    }
                }
                for _ in 0..EVERY.as_secs() {
                    if stopping.load(Ordering::SeqCst) {
                        break;
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
            }
            if newest() {
                let _ = fs::remove_file(TOKEN_FILE);
            }
        })?;
        Ok(OidcToken { stop })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The marker root reads in the work user's home: one printable line of the work user's own regular file,
    /// never through a link, never someone else's file, never an oversized one.
    #[test]
    fn the_audience_marker_is_read_only_as_the_work_users_own_small_regular_file() {
        let dir = tempfile::tempdir().unwrap();
        let uid = unsafe { libc::geteuid() };
        let file = dir.path().join("audience");
        fs::write(&file, "sts.amazonaws.com\n").unwrap();
        assert_eq!(read_audience(&file, uid).as_deref(), Some("sts.amazonaws.com"));
        assert_eq!(read_audience(&file, uid.wrapping_add(1)), None);
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert_eq!(read_audience(&link, uid), None);
        fs::write(&file, "two words\n").unwrap();
        assert_eq!(read_audience(&file, uid), None);
        fs::write(&file, "x".repeat(MAX_AUDIENCE + 3)).unwrap();
        assert_eq!(read_audience(&file, uid), None);
        assert_eq!(read_audience(&dir.path().join("missing"), uid), None);
    }

    #[test]
    fn a_token_is_renewed_at_half_life_or_when_the_audience_changes() {
        let held = ("vault".to_owned(), 1_000_000 + TTL_SECONDS * 1000);
        assert!(renew(None, "vault", 1_000_000));
        assert!(!renew(Some(&held), "vault", 1_000_000));
        assert!(renew(Some(&held), "sts.amazonaws.com", 1_000_000));
        assert!(renew(Some(&held), "vault", 1_000_000 + TTL_SECONDS * 500 + 1));
    }

    /// A token for another audience or past its expiry never stays in the file, even when renewing fails.
    #[test]
    fn a_token_for_another_audience_or_expired_is_stale() {
        let held = ("vault".to_owned(), 2_000);
        assert!(!stale(None, Some("vault"), 1_000));
        assert!(!stale(Some(&held), Some("vault"), 1_999));
        assert!(stale(Some(&held), Some("sts.amazonaws.com"), 1_000));
        assert!(stale(Some(&held), Some("vault"), 2_000));
        assert!(stale(Some(&held), None, 3_000));
        assert_eq!(backoff(1), Duration::from_secs(120));
        assert_eq!(backoff(40), MAX_BACKOFF);
    }
}

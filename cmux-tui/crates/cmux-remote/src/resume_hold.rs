//! The two ends of a held [`ResumablePipe`]: the client that keeps reconnecting it
//! ([`hold`], ssh's ProxyCommand side) and the far machine's table of parked pipes
//! ([`Parking`], beside the sshd it bridges to). RFD 0127 cut 4.
//!
//! Each new transport begins with an in-band resume handshake. It runs after the carrier's
//! service answer, so the circuit's dial path carries it as plain bytes:
//!
//! - The client sends `MAGIC`, then a token (all zero asks for a new pipe), then its received
//!   count (`u64`, big-endian).
//! - The far end answers `MAGIC`, then the pipe's token, then its own received count. An
//!   all-zero token means the far end holds no such pipe (it finished, it expired, or the far
//!   acpmux restarted); the client cannot resume it.
//!
//! Each end then sends again from the count the other gave ([`Claim::run`]).

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Notify;

use crate::resume_pipe::{Ran, ResumablePipe};

/// A pipe's name between its two ends: random, so only the end that opened it can resume it.
pub type Token = [u8; 16];

const MAGIC: &[u8; 4] = b"cmr1";
const NONE: Token = [0; 16];
const HANDSHAKE_BYTES: usize = 4 + 16 + 8;

/// How long a parked pipe waits for its client to come back after its transport broke. An
/// acpmux restart (exec handover, or a crash and the service manager's restart) comes back in
/// seconds; this also covers a laptop's network change.
pub const RESUME_GRACE: Duration = Duration::from_secs(120);

/// The longest time a handshake may take.
const HANDSHAKE_WAIT: Duration = Duration::from_secs(20);

fn handshake(token: Token, received: u64) -> [u8; HANDSHAKE_BYTES] {
    let mut out = [0u8; HANDSHAKE_BYTES];
    out[..4].copy_from_slice(MAGIC);
    out[4..20].copy_from_slice(&token);
    out[20..].copy_from_slice(&received.to_be_bytes());
    out
}

async fn read_handshake<T: AsyncRead + Unpin>(io: &mut T) -> Result<(Token, u64), String> {
    let mut buf = [0u8; HANDSHAKE_BYTES];
    tokio::time::timeout(HANDSHAKE_WAIT, io.read_exact(&mut buf))
        .await
        .map_err(|_| "the resume handshake was not answered in time".to_owned())?
        .map_err(|e| format!("the resume handshake broke: {e}"))?;
    if &buf[..4] != MAGIC {
        return Err("the other end does not speak the resume handshake".into());
    }
    let mut token = NONE;
    token.copy_from_slice(&buf[4..20]);
    let mut count = [0u8; 8];
    count.copy_from_slice(&buf[20..]);
    Ok((token, u64::from_be_bytes(count)))
}

async fn write_handshake<T: AsyncWrite + Unpin>(
    io: &mut T,
    token: Token,
    received: u64,
) -> Result<(), String> {
    io.write_all(&handshake(token, received)).await.map_err(|e| e.to_string())?;
    io.flush().await.map_err(|e| e.to_string())
}

/// How a [`hold`] ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Held {
    /// Both sides ended and every byte arrived.
    Finished,
    /// The pipe cannot go on: why.
    Failed(String),
}

/// Carry `local` (the ProxyCommand's stdio) to the far end through `connect`'s transports.
/// When a transport breaks, ask `connect` for another and resume the pipe on it. Give up when
/// none comes within `grace` of the break, or when the far end no longer holds the pipe.
///
/// `connect` gives a transport already past the carrier's service answer: the
/// `remote.pipe` request with `resume`, or a carrier stream to `cmux-tui` `target: resume`.
pub async fn hold<L, T, C, Fut>(local: L, mut connect: C, grace: Duration) -> Held
where
    L: AsyncRead + AsyncWrite + Send,
    T: AsyncRead + AsyncWrite + Send + Unpin,
    C: FnMut() -> Fut,
    Fut: Future<Output = Result<T, String>>,
{
    let pipe = ResumablePipe::new(local);
    let mut token: Option<Token> = None;
    let mut broke: Option<Instant> = None;
    let mut backoff = Duration::from_millis(50);
    loop {
        let why = match connect().await {
            Err(e) => e,
            Ok(mut transport) => {
                let claim = pipe.claim().await;
                let ours = claim.received();
                let said = async {
                    write_handshake(&mut transport, token.unwrap_or(NONE), ours).await?;
                    read_handshake(&mut transport).await
                };
                match said.await {
                    Err(e) => e,
                    Ok((NONE, _)) if token.is_none() => {
                        return Held::Failed("the far end did not open the pipe".into());
                    }
                    // Gone on the far side: only fine when nothing was left to carry.
                    Ok((NONE, _)) if pipe.peer_finished() => return Held::Finished,
                    Ok((NONE, _)) => {
                        return Held::Failed("the far end no longer holds this pipe".into());
                    }
                    Ok((theirs, _)) if token.is_some_and(|ours| ours != theirs) => {
                        return Held::Failed("the far end answered for another pipe".into());
                    }
                    Ok((theirs, peer_received)) => {
                        token = Some(theirs);
                        broke = None;
                        backoff = Duration::from_millis(50);
                        match claim.run(transport, peer_received).await {
                            Ran::Finished => return Held::Finished,
                            Ran::Failed(e) => return Held::Failed(e),
                            Ran::Broken(e) => e,
                        }
                    }
                }
            }
        };
        // Nothing was opened yet: the first transport's failure is the caller's to report.
        if token.is_none() {
            return Held::Failed(why);
        }
        let since = *broke.get_or_insert_with(Instant::now);
        if since.elapsed() >= grace {
            return Held::Failed(format!("no transport came back within {grace:?}: {why}"));
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(2));
    }
}

struct Parked<L> {
    pipe: Arc<ResumablePipe<L>>,
    /// Who opened it: only the same peer may resume it.
    owner: String,
    /// Bumped by every transport that takes the pipe; an expiry checks no newer one came.
    runs: u64,
}

/// This machine's held pipes, by token: each one waits [`RESUME_GRACE`] for its client after a
/// break.
pub struct Parking<L> {
    pipes: Mutex<HashMap<Token, Parked<L>>>,
    /// Told whenever a transport takes a pipe, so a broken run's wait ends early.
    taken: Notify,
    grace: Duration,
}

impl<L: AsyncRead + AsyncWrite + Send + 'static> Parking<L> {
    pub fn new(grace: Duration) -> Arc<Self> {
        Arc::new(Self { pipes: Mutex::new(HashMap::new()), taken: Notify::new(), grace })
    }

    fn pipes(&self) -> std::sync::MutexGuard<'_, HashMap<Token, Parked<L>>> {
        self.pipes.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Pipes held now.
    pub fn len(&self) -> usize {
        self.pipes().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Serve one transport from `owner` (the peer's proven name or key). Read its handshake.
    /// A new pipe reaches the local side through `connect`; a known one resumes. Carry the pipe
    /// until this transport's run ends. A run that broke returns once the pipe is taken by a
    /// newer transport or dropped, the grace past with none.
    pub async fn serve<T, C, Fut, E>(
        self: &Arc<Self>,
        mut transport: T,
        owner: &str,
        connect: C,
    ) -> Ran
    where
        T: AsyncRead + AsyncWrite + Send + Unpin,
        C: FnOnce() -> Fut,
        Fut: Future<Output = Result<L, E>>,
        E: std::fmt::Display,
    {
        let (token, peer_received) = match read_handshake(&mut transport).await {
            Ok(said) => said,
            Err(e) => return Ran::Broken(e),
        };
        let found = if token == NONE {
            match connect().await {
                Ok(local) => {
                    let mut token = NONE;
                    match getrandom::fill(&mut token) {
                        Ok(()) => {
                            let pipe = Arc::new(ResumablePipe::new(local));
                            let parked =
                                Parked { pipe: pipe.clone(), owner: owner.to_owned(), runs: 0 };
                            self.pipes().insert(token, parked);
                            Ok((token, pipe))
                        }
                        Err(e) => Err(format!("no randomness for a pipe token: {e}")),
                    }
                }
                Err(e) => Err(format!("the local side is not reachable: {e}")),
            }
        } else {
            let pipes = self.pipes();
            pipes
                .get(&token)
                .filter(|p| p.owner == owner)
                .map(|p| (token, p.pipe.clone()))
                .ok_or_else(|| "no such pipe".to_owned())
        };
        let (token, pipe) = match found {
            Ok(found) => found,
            Err(e) => {
                let _ = write_handshake(&mut transport, NONE, 0).await;
                return Ran::Failed(e);
            }
        };
        let claim = pipe.claim().await;
        let run = {
            let mut pipes = self.pipes();
            let Some(parked) = pipes.get_mut(&token) else {
                return Ran::Failed("the pipe expired under its resume".into());
            };
            parked.runs += 1;
            parked.runs
        };
        self.taken.notify_waiters();
        if let Err(e) = write_handshake(&mut transport, token, claim.received()).await {
            drop(claim);
            self.expire_unless_taken(token, run).await;
            return Ran::Broken(e);
        }
        let ran = claim.run(transport, peer_received).await;
        match &ran {
            Ran::Finished | Ran::Failed(_) => {
                let mut pipes = self.pipes();
                if pipes.get(&token).is_some_and(|p| p.runs == run) {
                    pipes.remove(&token);
                }
            }
            Ran::Broken(_) => self.expire_unless_taken(token, run).await,
        }
        ran
    }

    /// Wait for a newer transport to take the pipe; drop it when none did within the grace.
    async fn expire_unless_taken(&self, token: Token, run: u64) {
        let deadline = tokio::time::Instant::now() + self.grace;
        loop {
            // Made before the check, so a take between the two still wakes it.
            let taken = self.taken.notified();
            if self.pipes().get(&token).is_none_or(|p| p.runs != run) {
                return;
            }
            if tokio::time::timeout_at(deadline, taken).await.is_err() {
                let mut pipes = self.pipes();
                if pipes.get(&token).is_some_and(|p| p.runs == run) {
                    pipes.remove(&token);
                }
                return;
            }
        }
    }
}

#[cfg(test)]
#[path = "resume_hold_tests.rs"]
mod tests;

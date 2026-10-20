//! The single receiver authority writer; token readers keep the same verifier.
use std::sync::{
    Arc, Mutex, Weak,
    atomic::{AtomicU64, Ordering},
};
use std::time::Instant;

use super::{NativePolicy, NativeTokenVerifier, ReceiverTime};
use crate::keyset::Keyset;
use crate::token::TokenRefused;

type Monotonic = Arc<dyn Fn() -> Option<Instant> + Send + Sync>;

/// An owned read attempt. Canceling it closes authority, rather than leaving
/// a failed or abandoned refresh's previous policy indefinitely usable.
pub struct Refresh {
    verifier: Weak<NativeTokenVerifier>,
    owner: Arc<()>,
    serial: u64,
    started: Instant,
    done: bool,
}
impl Refresh {
    pub fn started(&self) -> Instant {
        self.started
    }
}
impl Drop for Refresh {
    fn drop(&mut self) {
        if !self.done
            && let Some(verifier) = self.verifier.upgrade()
        {
            verifier.clear_authority();
        }
    }
}

pub struct Owner {
    verifier: Arc<NativeTokenVerifier>,
    time: Arc<Mutex<Option<ReceiverTime>>>,
    monotonic: Monotonic,
    identity: Arc<()>,
    serial: AtomicU64,
}

impl Owner {
    pub fn new(keys: Keyset) -> Result<Self, TokenRefused> {
        Self::with_clock(keys, || Some(Instant::now()))
    }

    pub fn with_clock(
        keys: Keyset,
        clock: impl Fn() -> Option<Instant> + Send + Sync + 'static,
    ) -> Result<Self, TokenRefused> {
        let time: Arc<Mutex<Option<ReceiverTime>>> = Arc::new(Mutex::new(None));
        let read = time.clone();
        let monotonic: Monotonic = Arc::new(clock);
        let tick = monotonic.clone();
        let verifier = NativeTokenVerifier::new(
            keys,
            move || {
                let anchor = (*read.lock().ok()?)?;
                let now = tick()?;
                Some(ReceiverTime {
                    unix_ms: anchor.unix_ms.checked_add(
                        u64::try_from(now.checked_duration_since(anchor.monotonic)?.as_millis())
                            .ok()?,
                    )?,
                    monotonic: now,
                })
            },
            super::MAX_REPLAY,
        )?;
        Ok(Self {
            verifier: Arc::new(verifier),
            time,
            monotonic,
            identity: Arc::new(()),
            serial: AtomicU64::new(0),
        })
    }

    pub fn verifier(&self) -> Arc<NativeTokenVerifier> {
        self.verifier.clone()
    }

    pub fn begin(&self) -> Result<Refresh, TokenRefused> {
        Ok(Refresh {
            verifier: Arc::downgrade(&self.verifier),
            owner: self.identity.clone(),
            serial: self.serial.fetch_add(1, Ordering::SeqCst),
            started: (self.monotonic)().ok_or(TokenRefused::Invalid)?,
            done: false,
        })
    }

    pub fn install(
        &self,
        mut refresh: Refresh,
        keys: Keyset,
        policy: NativePolicy,
        time: ReceiverTime,
    ) -> Result<(), TokenRefused> {
        refresh.done = true;
        let _ = (&refresh.owner, refresh.serial);
        *self.time.lock().map_err(|_| TokenRefused::Invalid)? = Some(time);
        self.verifier.replace_keys(keys)?;
        self.verifier.replace_authority(policy)
    }

    pub fn fail(&self, mut refresh: Refresh) -> bool {
        refresh.done = true;
        self.verifier.clear_authority();
        true
    }

    pub fn invalidate(&self) {
        self.verifier.clear_authority();
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        self.invalidate();
    }
}

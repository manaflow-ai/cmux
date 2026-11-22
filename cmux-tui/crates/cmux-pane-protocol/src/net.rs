//! TCP socket settings for every connection this crate accepts or dials
//! (spec "Latency"): `TCP_NODELAY`, so small calls are not held by Nagle,
//! and `TCP_NOTSENT_LOWAT` of 16 KiB where the OS has it, so a small call
//! does not queue behind megabytes of unsent bulk data in the kernel.

use std::future::Future;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream};

pub const NOTSENT_LOWAT: u32 = 16 * 1024;

#[cfg(any(target_os = "linux", target_os = "android"))]
const TCP_NOTSENT_LOWAT: libc::c_int = libc::TCP_NOTSENT_LOWAT;
/// `<netinet/tcp.h>` on Darwin; the libc crate does not export it there.
#[cfg(target_vendor = "apple")]
const TCP_NOTSENT_LOWAT: libc::c_int = 0x201;

/// Apply the latency settings. `TCP_NODELAY` failing is an error;
/// `TCP_NOTSENT_LOWAT` is best effort.
pub fn tune(stream: &TcpStream) -> std::io::Result<()> {
    stream.set_nodelay(true)?;
    set_notsent_lowat(stream, NOTSENT_LOWAT);
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
fn set_notsent_lowat(stream: &TcpStream, bytes: u32) {
    use std::os::fd::AsRawFd;
    let value = bytes as libc::c_int;
    // SAFETY: the fd is a live TCP socket owned by `stream` for the whole
    // call, and `value` outlives it with the size passed.
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_TCP,
            TCP_NOTSENT_LOWAT,
            (&value as *const libc::c_int).cast(),
            size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
fn set_notsent_lowat(_stream: &TcpStream, _bytes: u32) {}

/// Read back `TCP_NOTSENT_LOWAT` (tests).
#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
pub fn notsent_lowat(stream: &TcpStream) -> std::io::Result<u32> {
    use std::os::fd::AsRawFd;
    let mut value: libc::c_int = 0;
    let mut length = size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: `value` and `length` are valid for writes of the sizes given.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_TCP,
            TCP_NOTSENT_LOWAT,
            (&mut value as *mut libc::c_int).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(value as u32)
}

/// Delay between failed accepts: 10 ms, doubling to 1 s, reset by a
/// success. A burst of failures is reported once, at its first failure.
#[derive(Debug, Clone)]
pub struct Backoff {
    next: Duration,
    failing: bool,
}

impl Default for Backoff {
    fn default() -> Self {
        Self { next: Self::FIRST, failing: false }
    }
}

impl Backoff {
    pub const FIRST: Duration = Duration::from_millis(10);
    pub const MAX: Duration = Duration::from_secs(1);

    /// Record a failure: how long to wait, and whether it starts a burst.
    pub fn failure(&mut self) -> (Duration, bool) {
        let starts_burst = !self.failing;
        self.failing = true;
        let delay = self.next;
        self.next = (self.next * 2).min(Self::MAX);
        (delay, starts_burst)
    }

    pub fn success(&mut self) {
        *self = Self::default();
    }
}

/// Run an accept loop forever: hand each accepted value to `handle`; on an
/// error wait per [`Backoff`] and call `log` once per burst of errors.
pub async fn accept_loop<T, A, Fut, H, L>(mut accept: A, mut handle: H, mut log: L)
where
    A: FnMut() -> Fut,
    Fut: Future<Output = std::io::Result<T>>,
    H: FnMut(T),
    L: FnMut(&std::io::Error),
{
    let mut backoff = Backoff::default();
    loop {
        match accept().await {
            Ok(value) => {
                backoff.success();
                handle(value);
            }
            Err(error) => {
                let (delay, starts_burst) = backoff.failure();
                if starts_burst {
                    log(&error);
                }
                tokio::time::sleep(delay).await;
            }
        }
    }
}

/// The default accept-error log: one line on stderr per burst.
pub fn log_accept_error(listener: &'static str) -> impl FnMut(&std::io::Error) {
    move |error| {
        eprintln!("cmux-pane-protocol: {listener} accept failed: {error}; backing off up to 1 s");
    }
}

/// Accept one connection and tune it.
pub async fn accept(listener: &TcpListener) -> std::io::Result<(TcpStream, SocketAddr)> {
    let (stream, address) = listener.accept().await?;
    tune(&stream)?;
    Ok((stream, address))
}

/// Dial and tune.
pub async fn connect(address: SocketAddr) -> std::io::Result<TcpStream> {
    let stream = TcpStream::connect(address).await?;
    tune(&stream)?;
    Ok(stream)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn backoff_doubles_to_a_cap_and_resets() {
        let mut backoff = Backoff::default();
        let delays: Vec<u64> = (0..9).map(|_| backoff.failure().0.as_millis() as u64).collect();
        assert_eq!(delays, [10, 20, 40, 80, 160, 320, 640, 1000, 1000]);
        backoff.success();
        assert_eq!(backoff.failure(), (Backoff::FIRST, true));
        assert!(!backoff.failure().1);
    }

    /// An accept that keeps failing is retried with backoff and logged
    /// once per burst, not once per error.
    #[tokio::test]
    async fn a_failing_listener_backs_off_and_logs_once_per_burst() {
        let calls = Arc::new(AtomicUsize::new(0));
        let logged = Arc::new(AtomicUsize::new(0));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let started = std::time::Instant::now();
        let task = tokio::spawn({
            let (calls, logged, seen) = (calls.clone(), logged.clone(), logged.clone());
            accept_loop(
                move || {
                    let call = calls.fetch_add(1, Ordering::SeqCst) + 1;
                    async move {
                        match call {
                            1..=5 | 7..=8 => Err(std::io::Error::other("EMFILE")),
                            6 | 9 => Ok(call),
                            // Then no more connections, as a real listener.
                            _ => std::future::pending().await,
                        }
                    }
                },
                // Record how many bursts were logged when each accept lands.
                move |value| {
                    let _ = tx.send((value, seen.load(Ordering::SeqCst), started.elapsed()));
                },
                move |_| {
                    logged.fetch_add(1, Ordering::SeqCst);
                },
            )
        });
        let (value, bursts, elapsed) = rx.recv().await.unwrap();
        assert_eq!((value, bursts), (6, 1));
        assert!(elapsed >= Duration::from_millis(10 + 20 + 40 + 80 + 160));
        let (value, bursts, elapsed_again) = rx.recv().await.unwrap();
        assert_eq!((value, bursts), (9, 2));
        // The second burst starts again at 10 ms: 10 + 20 after the reset.
        assert!(elapsed_again - elapsed < Duration::from_millis(300));
        task.abort();
    }

    #[tokio::test]
    async fn accepted_and_dialed_sockets_are_tuned() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (dialed, accepted) = tokio::join!(connect(address), accept(&listener));
        let dialed = dialed.unwrap();
        let (accepted, _) = accepted.unwrap();
        assert!(dialed.nodelay().unwrap());
        assert!(accepted.nodelay().unwrap());
        #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
        {
            assert_eq!(notsent_lowat(&dialed).unwrap(), NOTSENT_LOWAT);
            assert_eq!(notsent_lowat(&accepted).unwrap(), NOTSENT_LOWAT);
        }
    }
}

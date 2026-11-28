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

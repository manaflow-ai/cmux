//! A bound on the bytes a tunnel stream holds ahead of the wire, the idea of
//! Linux's `TCP_NOTSENT_LOWAT`.
//!
//! Bytes handed to a TCP socket keep their order: a frame its owner wants
//! out first (a terminal's echo) waits behind every byte already in the
//! socket. A stream used to take writes until its 32-slot channel to the
//! driver and its socket's 256 KiB send buffer were full, so an echo could
//! queue behind most of a megabyte of another channel's output, seconds on a
//! slow relay. Now a write waits while the bytes the stream has queued but
//! TCP has not sent (in the channel, waiting for the socket, or in the
//! socket unsent) reach the low-water mark. The writer's own scheduler
//! (cmux-mobile-link's link writer, by priority and round robin) then
//! decides the order of everything else. Bytes in flight are not counted:
//! they are the congestion window's, and holding them back would cost
//! throughput.
//!
//! The mark is what the connection delivers in [`LOWAT_HORIZON`] at its
//! measured delivery rate (sampled once per SRTT), with a floor. Unsent
//! bytes only have to cover the window the ACKs open while the writer
//! refills the socket (a driver pass and a task wake), not a round trip:
//! the ACK clock sends them, and the congestion window already holds a
//! round trip in flight. A mark of one bandwidth-delay product was
//! measured too (`send_gate_tests`, 40 ms round trip): it doubled the
//! echo's wait (80 ms against 40 ms) and delivered less (25 Mbit/s
//! against 46 Mbit/s), because a full round trip of unsent bytes is one
//! more round trip every new frame waits for.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use tokio::time::Instant;

/// How long the unsent bytes may last at the delivery rate: the time a
/// fresh frame waits behind them. It covers the writer's refill (a driver
/// pass and a task wake, well under a millisecond) several times over, and
/// keeps the wait a small part of the 50 ms key-to-echo budget.
pub(crate) const LOWAT_HORIZON: Duration = Duration::from_millis(5);
/// The low-water mark's floor: one link data frame (cmux-mobile-link's
/// `DATA_CHUNK`), so a slow or idle connection still takes a whole frame
/// and holds the next one ready. At 10 Mbit/s it is 13 ms of data.
pub(crate) const MIN_LOWAT_BYTES: usize = 16 * 1024;
/// The ceiling: the send buffer this gate replaced as the bound (256 KiB),
/// 51 ms at 40 Mbit/s and still past [`LOWAT_HORIZON`] at 400 Mbit/s. A
/// larger window ([`crate::tcp_stack::DEFAULT_STREAM_WINDOW`]) adds bytes in
/// flight, not unsent bytes an echo waits behind.
pub(crate) const MAX_LOWAT_BYTES: usize = 256 * 1024;
/// The floor under a stream's send window cap: the fixed window every
/// stream had before the window was sized by the path (256 KiB). Loopback and
/// LAN paths never need more, and on them a larger flight was slower
/// (1,300 against 800 Mbit/s on loopback, the queue in front of each segment
/// growing with it).
pub(crate) const MIN_SEND_WINDOW: usize = 256 * 1024;
/// The send window cap is this many bandwidth-delay products: room for the
/// rate to double each round trip until the path, not the cap, limits it.
const SEND_WINDOW_BDPS: f64 = 2.0;
/// How long the smallest smoothed RTT stands for the path's own round trip
/// before a newer one replaces it (BBR's min_rtt filter): a roam to a longer
/// path is learned within this.
const MIN_RTT_WINDOW: Duration = Duration::from_secs(10);
/// The shortest delivery-rate sample: below it a sample is mostly the
/// granularity of ACKs.
const MIN_SAMPLE: Duration = Duration::from_millis(10);

/// What a stream and the driver share about the stream's unsent bytes.
#[derive(Debug)]
pub(crate) struct SendGate {
    /// Bytes the owner wrote that are not in the socket yet.
    queued: AtomicUsize,
    /// Bytes in the socket never sent, as of the driver's last pass (plus
    /// what it moved in since).
    unsent: AtomicUsize,
    /// The low-water mark.
    lowat: AtomicUsize,
    /// The connection is gone: writes go on to fail on the closed channel.
    closed: AtomicBool,
    /// The writer waiting for room.
    waker: Mutex<Option<Waker>>,
}

impl Default for SendGate {
    fn default() -> Self {
        Self {
            queued: AtomicUsize::new(0),
            unsent: AtomicUsize::new(0),
            lowat: AtomicUsize::new(MIN_LOWAT_BYTES),
            closed: AtomicBool::new(false),
            waker: Mutex::new(None),
        }
    }
}

impl SendGate {
    fn has_room(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
            || self.queued.load(Ordering::SeqCst) + self.unsent.load(Ordering::SeqCst)
                < self.lowat.load(Ordering::SeqCst)
    }

    /// Ready while the stream's unsent bytes are below the low-water mark;
    /// otherwise the driver wakes `cx` once they are.
    pub(crate) fn poll_room(&self, cx: &mut Context<'_>) -> Poll<()> {
        if self.has_room() {
            return Poll::Ready(());
        }
        *self.waker.lock().unwrap_or_else(PoisonError::into_inner) = Some(cx.waker().clone());
        // The driver may have made room between the check and the store.
        if self.has_room() { Poll::Ready(()) } else { Poll::Pending }
    }

    /// The owner is handing `bytes` to the driver. Called before the send, so
    /// the driver's `moved` for them never runs first.
    pub(crate) fn queued(&self, bytes: usize) {
        self.queued.fetch_add(bytes, Ordering::SeqCst);
    }

    /// The send after `queued(bytes)` failed: the driver never got them.
    pub(crate) fn unqueued(&self, bytes: usize) {
        let _ = self.queued.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |queued| {
            Some(queued.saturating_sub(bytes))
        });
    }

    /// The driver moved `bytes` from the stream into the socket.
    pub(crate) fn moved(&self, bytes: usize) {
        self.unsent.fetch_add(bytes, Ordering::SeqCst);
        let _ = self.queued.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |queued| {
            Some(queued.saturating_sub(bytes))
        });
    }

    /// The driver's view after a pass: the socket's unsent bytes and the
    /// current low-water mark. Wakes a waiting writer when there is room.
    pub(crate) fn update(&self, unsent: usize, lowat: usize) {
        self.unsent.store(unsent, Ordering::SeqCst);
        self.lowat.store(lowat, Ordering::SeqCst);
        if self.has_room() {
            self.wake();
        }
    }

    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.wake();
    }

    fn wake(&self) {
        let waker = self.waker.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

/// The driver's side of a connection's gate: it measures the delivery rate
/// and sets the low-water mark, and its drop (the connection is gone)
/// releases a waiting writer.
#[derive(Debug)]
pub(crate) struct SendPacer {
    pub(crate) gate: Arc<SendGate>,
    /// Bytes moved into the socket since the connection began.
    written: u64,
    /// The current rate sample: when it started and the bytes acknowledged by then.
    sample: Option<(Instant, u64)>,
    /// Delivery rate, bytes per second: the newest sample, or the previous
    /// estimate decayed by an eighth per sample if that is higher (a flow
    /// that pauses keeps its rate for a few round trips).
    rate: f64,
    /// The smallest smoothed RTT seen in the current [`MIN_RTT_WINDOW`], and
    /// when it was seen: the round trip without the queue this stream builds.
    min_rtt: Option<(Duration, Instant)>,
}

impl SendPacer {
    pub(crate) fn new(gate: Arc<SendGate>) -> Self {
        Self { gate, written: 0, sample: None, rate: 0.0, min_rtt: None }
    }

    /// The most bytes this stream should keep in flight: [`SEND_WINDOW_BDPS`]
    /// times its delivery rate times its round trip without queueing, from
    /// [`MIN_SEND_WINDOW`] up to `buffer` (the socket's send buffer). The
    /// round trip is the windowed minimum, not the smoothed RTT, which grows
    /// with the stream's own queue and would raise the cap without end.
    pub(crate) fn send_window(&self, buffer: usize) -> usize {
        let floor = MIN_SEND_WINDOW.min(buffer);
        let Some((rtt, _)) = self.min_rtt else {
            return floor;
        };
        let bytes = SEND_WINDOW_BDPS * self.rate * rtt.as_secs_f64();
        if bytes.is_finite() && bytes > 0.0 {
            (bytes as usize).clamp(floor, buffer.max(floor))
        } else {
            floor
        }
    }

    /// The driver moved `bytes` into the socket.
    pub(crate) fn moved(&mut self, bytes: usize) {
        self.written += bytes as u64;
        self.gate.moved(bytes);
    }

    /// After a pass: `send_queue` and `unsent` are the socket's (bytes in
    /// its buffer, and those never sent), `srtt` its smoothed round trip.
    pub(crate) fn update(
        &mut self,
        now: Instant,
        send_queue: usize,
        unsent: usize,
        srtt: Option<Duration>,
    ) {
        if let Some(srtt) = srtt {
            let stale = self.min_rtt.is_none_or(|(min, at)| {
                srtt <= min || now.saturating_duration_since(at) >= MIN_RTT_WINDOW
            });
            if stale {
                self.min_rtt = Some((srtt, now));
            }
        }
        let lowat = self.lowat(now, send_queue, srtt);
        self.gate.update(unsent, lowat);
    }

    /// The low-water mark from the delivery rate, sampled once per SRTT.
    fn lowat(&mut self, now: Instant, send_queue: usize, srtt: Option<Duration>) -> usize {
        let acked = self.written.saturating_sub(send_queue as u64);
        let Some(srtt) = srtt else {
            self.sample = Some((now, acked));
            return MIN_LOWAT_BYTES;
        };
        match self.sample {
            None => self.sample = Some((now, acked)),
            Some((start, at)) => {
                let elapsed = now.saturating_duration_since(start);
                if elapsed >= srtt.max(MIN_SAMPLE) {
                    let sample = acked.saturating_sub(at) as f64 / elapsed.as_secs_f64();
                    self.rate = sample.max(self.rate * 0.875);
                    self.sample = Some((now, acked));
                }
            }
        }
        lowat_for(self.rate)
    }
}

impl Drop for SendPacer {
    fn drop(&mut self) {
        self.gate.close();
    }
}

/// What `rate` (bytes per second) delivers in [`LOWAT_HORIZON`], within
/// [`MIN_LOWAT_BYTES`] and [`MAX_LOWAT_BYTES`].
pub(crate) fn lowat_for(rate: f64) -> usize {
    let bytes = rate * LOWAT_HORIZON.as_secs_f64();
    if bytes.is_finite() && bytes > 0.0 {
        (bytes as usize).clamp(MIN_LOWAT_BYTES, MAX_LOWAT_BYTES)
    } else {
        MIN_LOWAT_BYTES
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicUsize;
    use std::task::Wake;

    use super::*;

    #[derive(Default)]
    struct Count(AtomicUsize);

    impl Wake for Count {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn the_send_window_follows_rate_times_the_unqueued_round_trip() {
        let buffer = 4 << 20;
        let mut pacer = SendPacer::new(Arc::new(SendGate::default()));
        // No round trip measured: the old fixed window.
        assert_eq!(pacer.send_window(buffer), MIN_SEND_WINDOW);
        let start = Instant::now();
        pacer.update(start, 0, 0, Some(Duration::from_millis(100)));
        // 10 MB/s over 100 ms is 1 MB a round trip: twice that.
        pacer.rate = 10e6;
        assert_eq!(pacer.send_window(buffer), 2_000_000);
        // A queue that raises the smoothed RTT does not raise the cap.
        pacer.update(start + Duration::from_secs(1), 0, 0, Some(Duration::from_millis(400)));
        pacer.rate = 10e6;
        assert_eq!(pacer.send_window(buffer), 2_000_000);
        // Past the filter's window the longer path is taken as the path.
        pacer.update(start + Duration::from_secs(11), 0, 0, Some(Duration::from_millis(400)));
        pacer.rate = 10e6;
        assert_eq!(pacer.send_window(buffer), buffer);
        // Loopback: a tiny product stays at the floor.
        pacer.update(start + Duration::from_secs(12), 0, 0, Some(Duration::from_micros(100)));
        pacer.rate = 160e6;
        assert_eq!(pacer.send_window(buffer), MIN_SEND_WINDOW);
        // A buffer under the floor is the cap.
        assert_eq!(pacer.send_window(64 * 1024), 64 * 1024);
    }

    #[test]
    fn a_write_waits_at_the_low_water_mark_and_the_driver_wakes_it() {
        let gate = Arc::new(SendGate::default());
        let count = Arc::new(Count::default());
        let waker = Waker::from(Arc::clone(&count));
        let mut cx = Context::from_waker(&waker);
        assert!(gate.poll_room(&mut cx).is_ready());
        gate.queued(MIN_LOWAT_BYTES);
        assert!(gate.poll_room(&mut cx).is_pending());
        // Moving it into the socket unsent leaves the backlog as it was.
        let mut pacer = SendPacer::new(Arc::clone(&gate));
        pacer.moved(MIN_LOWAT_BYTES);
        assert!(gate.poll_room(&mut cx).is_pending());
        // TCP sent half of it: room, and the writer is woken.
        pacer.update(Instant::now(), MIN_LOWAT_BYTES, MIN_LOWAT_BYTES / 2, None);
        assert_eq!(count.0.load(Ordering::SeqCst), 1);
        assert!(gate.poll_room(&mut cx).is_ready());
    }

    #[test]
    fn bytes_the_driver_moved_or_never_got_leave_no_count_behind() {
        let gate = Arc::new(SendGate::default());
        let count = Arc::new(Count::default());
        let waker = Waker::from(Arc::clone(&count));
        let mut cx = Context::from_waker(&waker);
        let mut pacer = SendPacer::new(Arc::clone(&gate));
        // The stream counts a frame before the send, the driver moves it and
        // TCP sends it: nothing is left counted.
        gate.queued(MIN_LOWAT_BYTES);
        pacer.moved(MIN_LOWAT_BYTES);
        pacer.update(Instant::now(), 0, 0, None);
        assert!(gate.poll_room(&mut cx).is_ready());
        // A send that failed after the count gives it back.
        gate.queued(MIN_LOWAT_BYTES);
        assert!(gate.poll_room(&mut cx).is_pending());
        gate.unqueued(MIN_LOWAT_BYTES);
        assert!(gate.poll_room(&mut cx).is_ready());
    }

    #[test]
    fn a_closed_connection_releases_the_writer() {
        let gate = Arc::new(SendGate::default());
        let count = Arc::new(Count::default());
        let waker = Waker::from(Arc::clone(&count));
        let mut cx = Context::from_waker(&waker);
        gate.queued(MAX_LOWAT_BYTES);
        let pacer = SendPacer::new(Arc::clone(&gate));
        assert!(gate.poll_room(&mut cx).is_pending());
        drop(pacer);
        assert_eq!(count.0.load(Ordering::SeqCst), 1);
        assert!(gate.poll_room(&mut cx).is_ready());
    }

    #[test]
    fn the_low_water_mark_follows_the_measured_delivery_rate() {
        assert_eq!(lowat_for(0.0), MIN_LOWAT_BYTES);
        // 10 Mbit/s: 6 KB in 5 ms, under the floor.
        assert_eq!(lowat_for(1_250_000.0), MIN_LOWAT_BYTES);
        // 200 Mbit/s: 125 KB in 5 ms.
        assert_eq!(lowat_for(25_000_000.0), 125_000);
        assert_eq!(lowat_for(1e12), MAX_LOWAT_BYTES);

        let start = Instant::now();
        let mut pacer = SendPacer::new(Arc::new(SendGate::default()));
        let srtt = Some(Duration::from_millis(40));
        pacer.moved(10_000_000);
        assert_eq!(pacer.lowat(start, 10_000_000, srtt), MIN_LOWAT_BYTES);
        // Nothing is sampled before one SRTT has passed.
        assert_eq!(
            pacer.lowat(start + Duration::from_millis(20), 9_000_000, srtt),
            MIN_LOWAT_BYTES
        );
        // 1 MB acknowledged in 40 ms: 25 MB/s, 125 KB in 5 ms.
        let lowat = pacer.lowat(start + Duration::from_millis(40), 9_000_000, srtt);
        assert!((124_000..=126_000).contains(&lowat), "{lowat}");
        // The flow goes quiet: the mark decays back to the floor.
        let mut at = start + Duration::from_millis(40);
        for _ in 0..40 {
            at += Duration::from_millis(40);
            pacer.lowat(at, 9_000_000, srtt);
        }
        assert_eq!(pacer.lowat(at, 9_000_000, srtt), MIN_LOWAT_BYTES);
    }
}

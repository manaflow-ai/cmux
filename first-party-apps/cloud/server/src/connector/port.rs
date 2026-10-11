//! The carrier side of a frame link: one stream connection to the link's
//! carrier socket. The serve loop never waits on it: it asks for one read
//! of at most N bytes (the pump's budget) and hands over bytes to write;
//! the results come back as [`PortEvent`]s and wake the loop. A read is
//! only ever asked inside the out credit, so a slow host stops the carrier
//! read instead of growing a buffer.

use crate::link::LinkWake;
use std::io::{ErrorKind, Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};

/// What a carrier port did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PortEvent {
    /// Bytes from one read; empty at end of stream.
    Read(Vec<u8>),
    /// The carrier took this many bytes of the writes, in order.
    Wrote(usize),
    /// The stream failed; nothing more comes.
    Closed(String),
}

/// One carrier connection, driven by the serve loop.
pub trait CarrierPort: Send {
    /// Reads at most `max` bytes once; a [`PortEvent::Read`] follows. The
    /// caller asks again only after that event.
    fn read(&mut self, max: usize);
    /// Writes `bytes` after the earlier writes; a [`PortEvent::Wrote`] follows.
    fn write(&mut self, bytes: Vec<u8>);
    /// The events since the last call, in order.
    fn take_events(&mut self) -> Vec<PortEvent>;
    /// Ends the connection both ways; a read or write that waits returns.
    fn shutdown(&mut self);
}

/// Opens carrier ports (tests give a fake).
pub trait PortOpener: Send {
    /// Connects to the carrier socket at `socket`; each event calls `wake`.
    fn open(
        &mut self,
        socket: &Path,
        wake: Option<LinkWake>,
    ) -> std::io::Result<Box<dyn CarrierPort>>;
}

/// The real opener: a local stream socket.
pub struct UnixPortOpener;

impl PortOpener for UnixPortOpener {
    fn open(
        &mut self,
        socket: &Path,
        wake: Option<LinkWake>,
    ) -> std::io::Result<Box<dyn CarrierPort>> {
        UnixPort::connect(socket, wake).map(|port| Box::new(port) as Box<dyn CarrierPort>)
    }
}

type Events = Arc<Mutex<Vec<PortEvent>>>;

fn post(events: &Events, wake: Option<&LinkWake>, event: PortEvent) {
    events.lock().unwrap_or_else(PoisonError::into_inner).push(event);
    if let Some(wake) = wake {
        wake();
    }
}

/// One reader and one writer thread on a local stream socket. Each thread
/// blocks on its own request channel or socket call, never on a timer.
struct UnixPort {
    stream: UnixStream,
    reads: Option<Sender<usize>>,
    writes: Option<Sender<Vec<u8>>>,
    events: Events,
}

impl UnixPort {
    fn connect(socket: &Path, wake: Option<LinkWake>) -> std::io::Result<Self> {
        let stream = UnixStream::connect(socket)?;
        let events = Events::default();
        let (reads, read_asks) = channel();
        let (writes, write_asks) = channel();
        let reader = stream.try_clone()?;
        let writer = stream.try_clone()?;
        let (read_events, read_wake) = (Arc::clone(&events), wake.clone());
        std::thread::Builder::new()
            .name("cmux-cloud-pump-read".into())
            .spawn(move || read_loop(reader, &read_asks, &read_events, read_wake.as_ref()))?;
        let write_events = Arc::clone(&events);
        std::thread::Builder::new()
            .name("cmux-cloud-pump-write".into())
            .spawn(move || write_loop(writer, &write_asks, &write_events, wake.as_ref()))?;
        Ok(Self { stream, reads: Some(reads), writes: Some(writes), events })
    }
}

fn read_loop(
    mut stream: UnixStream,
    asks: &Receiver<usize>,
    events: &Events,
    wake: Option<&LinkWake>,
) {
    while let Ok(max) = asks.recv() {
        let mut buffer = vec![0; max];
        let event = loop {
            match stream.read(&mut buffer) {
                Ok(n) => {
                    buffer.truncate(n);
                    break PortEvent::Read(buffer);
                }
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) => break PortEvent::Closed(format!("the carrier read failed: {e}")),
            }
        };
        let last = !matches!(&event, PortEvent::Read(bytes) if !bytes.is_empty());
        post(events, wake, event);
        if last {
            return;
        }
    }
}

fn write_loop(
    mut stream: UnixStream,
    asks: &Receiver<Vec<u8>>,
    events: &Events,
    wake: Option<&LinkWake>,
) {
    while let Ok(bytes) = asks.recv() {
        let event = match stream.write_all(&bytes).and_then(|()| stream.flush()) {
            Ok(()) => PortEvent::Wrote(bytes.len()),
            Err(e) => PortEvent::Closed(format!("the carrier write failed: {e}")),
        };
        let failed = matches!(event, PortEvent::Closed(_));
        post(events, wake, event);
        if failed {
            return;
        }
    }
}

impl CarrierPort for UnixPort {
    fn read(&mut self, max: usize) {
        if let Some(reads) = &self.reads {
            // A reader that ended already posted its last event.
            let _ = reads.send(max);
        }
    }

    fn write(&mut self, bytes: Vec<u8>) {
        if let Some(writes) = &self.writes {
            let _ = writes.send(bytes);
        }
    }

    fn take_events(&mut self) -> Vec<PortEvent> {
        std::mem::take(&mut *self.events.lock().unwrap_or_else(PoisonError::into_inner))
    }

    fn shutdown(&mut self) {
        // Closing the request channels ends each thread after its current
        // call; the socket shutdown makes a waiting call return now.
        self.reads = None;
        self.writes = None;
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }
}

impl Drop for UnixPort {
    fn drop(&mut self) {
        self.shutdown();
    }
}

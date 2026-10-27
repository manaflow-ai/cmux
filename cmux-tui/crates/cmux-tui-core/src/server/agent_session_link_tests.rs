//! A link's owner hears its close once, however the watch ends: the
//! socket's end, or the reader dropped first (the readers stopped, or it
//! panicked).

use super::*;
use std::sync::mpsc::{Receiver, channel};

/// A reader on one end of a socket pair, the other end, and the reasons of
/// the closes its owner heard.
fn reader() -> (LinkReader<impl FnMut(Inbound) + Send + 'static>, UnixStream, Receiver<&'static str>)
{
    let (peer, stream) = UnixStream::pair().unwrap();
    let (closes, heard) = channel();
    let reader = LinkReader {
        stream,
        line: Vec::new(),
        pending: Arc::default(),
        closed: Arc::new(AtomicBool::new(false)),
        on_inbound: move |inbound| {
            if let Inbound::Closed(reason) = inbound {
                let _ = closes.send(reason);
            }
        },
        ended: false,
    };
    (reader, peer, heard)
}

#[test]
fn a_reader_dropped_before_its_socket_ended_delivers_the_close() {
    let (reader, _peer, heard) = reader();
    let closed = reader.closed.clone();
    drop(reader);
    assert_eq!(heard.try_recv(), Ok("acpmux_closed"));
    assert!(heard.try_recv().is_err(), "the close is delivered once");
    assert!(closed.load(Ordering::Acquire), "the link is closed");
}

#[test]
fn a_reader_whose_socket_ended_delivers_the_close_once() {
    let (mut reader, peer, heard) = reader();
    drop(peer);
    assert!(!reader.readable(), "an end of file ends the watch");
    drop(reader);
    assert_eq!(heard.try_recv(), Ok("acpmux_closed"));
    assert!(heard.try_recv().is_err(), "the close is delivered once");
}

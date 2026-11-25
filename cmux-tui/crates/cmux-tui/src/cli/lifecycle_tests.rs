use std::io::{self, Cursor, Read, Write};
use std::net::Shutdown;
use std::sync::{Arc, Mutex};

use super::*;

#[test]
fn rejects_invalid_session_names_before_socket_resolution() {
    assert!(!valid_session_name(""));
    assert!(!valid_session_name("bad name"));
    assert!(!valid_session_name("bad\nname"));
    assert!(!valid_session_name(&"x".repeat(65)));
}

#[test]
fn accepts_session_names_for_explicit_and_default_socket_routes() {
    assert!(valid_session_name("main"));
    assert!(valid_session_name("agent-1"));
}

struct UnreadableStream;

impl Read for UnreadableStream {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        panic!("an expired lifecycle deadline must fail before reading")
    }
}

impl Write for UnreadableStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl transport::Stream for UnreadableStream {
    fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self))
    }

    fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn shutdown(&self, _: Shutdown) -> io::Result<()> {
        Ok(())
    }
}

struct TimeoutRecordingStream {
    read_timeout: Arc<Mutex<Option<Duration>>>,
    write_timeout: Arc<Mutex<Option<Duration>>>,
}

impl Read for TimeoutRecordingStream {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        Ok(0)
    }
}

impl Write for TimeoutRecordingStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl transport::Stream for TimeoutRecordingStream {
    fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self {
            read_timeout: self.read_timeout.clone(),
            write_timeout: self.write_timeout.clone(),
        }))
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        *self.read_timeout.lock().unwrap() = timeout;
        Ok(())
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        *self.write_timeout.lock().unwrap() = timeout;
        Ok(())
    }

    fn shutdown(&self, _: Shutdown) -> io::Result<()> {
        Ok(())
    }
}

struct TransportCloseStream;

impl Read for TransportCloseStream {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::other("transport closed after shutdown acknowledgement"))
    }
}

impl Write for TransportCloseStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl transport::Stream for TransportCloseStream {
    fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self))
    }

    fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn shutdown(&self, _: Shutdown) -> io::Result<()> {
        Ok(())
    }
}

struct RejectedStream {
    response: Cursor<Vec<u8>>,
}

impl Read for RejectedStream {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.response.read(bytes)
    }
}

impl Write for RejectedStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl transport::Stream for RejectedStream {
    fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(Self { response: self.response.clone() }))
    }

    fn set_read_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn set_write_timeout(&self, _: Option<Duration>) -> io::Result<()> {
        Ok(())
    }

    fn shutdown(&self, _: Shutdown) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn expired_deadline_fails_before_reading_another_frame() {
    let stream: Box<dyn transport::Stream> = Box::new(UnreadableStream);
    let mut connection = BufReader::new(stream);
    let expired = Instant::now() - Duration::from_millis(1);

    assert_eq!(read_response(&mut connection, expired), Err(ExchangeError::Timeout));
}

#[test]
fn lifecycle_deadline_bounds_reads_and_writes() {
    let read_timeout = Arc::new(Mutex::new(None));
    let write_timeout = Arc::new(Mutex::new(None));
    let stream: Box<dyn transport::Stream> = Box::new(TimeoutRecordingStream {
        read_timeout: read_timeout.clone(),
        write_timeout: write_timeout.clone(),
    });
    let mut connection = BufReader::new(stream);
    let requested = Duration::from_secs(1);

    require_time_remaining(&mut connection, Instant::now() + requested).unwrap();

    let read_timeout = read_timeout.lock().unwrap().unwrap();
    let write_timeout = write_timeout.lock().unwrap().unwrap();
    assert!(!read_timeout.is_zero());
    assert!(read_timeout <= requested);
    assert!(!write_timeout.is_zero());
    assert!(write_timeout <= requested);
}

#[test]
fn stop_accepts_transport_close_after_shutdown_acknowledgement() {
    let stream: Box<dyn transport::Stream> = Box::new(TransportCloseStream);
    let mut connection = BufReader::new(stream);

    assert!(wait_for_close(&mut connection, Instant::now() + Duration::from_secs(1)).is_ok());
}

#[test]
fn exchange_preserves_daemon_rejection_details() {
    let rejection = json!({
        "id": 2,
        "ok": false,
        "error": "trusted local connection required",
    });
    let stream: Box<dyn transport::Stream> =
        Box::new(RejectedStream { response: Cursor::new(format!("{rejection}\n").into_bytes()) });
    let mut connection = BufReader::new(stream);
    let error = exchange(
        &mut connection,
        json!({"id":2,"cmd":"server-stats"}),
        Instant::now() + Duration::from_secs(1),
    )
    .expect_err("rejected response");
    assert_eq!(error, ExchangeError::Rejected("trusted local connection required".into()));
}

#[test]
fn lifecycle_io_errors_preserve_timeout_classification() {
    assert_eq!(exchange_io_error(io::Error::from(io::ErrorKind::TimedOut)), ExchangeError::Timeout);
    assert_eq!(
        exchange_io_error(io::Error::from(io::ErrorKind::WouldBlock)),
        ExchangeError::Timeout
    );
    assert_eq!(
        exchange_io_error(io::Error::from(io::ErrorKind::BrokenPipe)),
        ExchangeError::Closed
    );
    assert_eq!(
        exchange_io_error(io::Error::from(io::ErrorKind::ConnectionReset)),
        ExchangeError::Closed
    );
    assert_eq!(
        exchange_io_error(io::Error::from(io::ErrorKind::NotConnected)),
        ExchangeError::Closed
    );
    assert_eq!(exchange_io_error(io::Error::from(io::ErrorKind::Other)), ExchangeError::Transport);
}

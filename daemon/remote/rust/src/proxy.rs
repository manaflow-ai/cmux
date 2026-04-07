use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Mutex;
use std::time::Duration;

#[derive(Debug)]
pub enum ProxyError {
    NotFound,
    Io(std::io::Error),
}

impl std::fmt::Display for ProxyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProxyError::NotFound => write!(f, "stream not found"),
            ProxyError::Io(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for ProxyError {}

pub struct ProxyReadResult {
    pub data: Vec<u8>,
    pub eof: bool,
}

pub struct ProxyManager {
    next_id: Mutex<u64>,
    streams: Mutex<BTreeMap<String, TcpStream>>,
}

impl ProxyManager {
    pub fn new() -> Self {
        Self {
            next_id: Mutex::new(1),
            streams: Mutex::new(BTreeMap::new()),
        }
    }

    pub fn open(&self, host: &str, port: u16, timeout_ms: u64) -> Result<String, ProxyError> {
        let addr = (host, port)
            .to_socket_addrs()
            .map_err(ProxyError::Io)?
            .next()
            .ok_or_else(|| {
                ProxyError::Io(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "address not found",
                ))
            })?;
        let stream = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms))
            .map_err(ProxyError::Io)?;
        let stream_id = {
            let mut next = self.next_id.lock().unwrap();
            let value = format!("stream-{next}");
            *next += 1;
            value
        };
        self.streams
            .lock()
            .unwrap()
            .insert(stream_id.clone(), stream);
        Ok(stream_id)
    }

    pub fn close(&self, stream_id: &str) -> Result<(), ProxyError> {
        self.streams
            .lock()
            .unwrap()
            .remove(stream_id)
            .map(|_| ())
            .ok_or(ProxyError::NotFound)
    }

    pub fn write(&self, stream_id: &str, data: &[u8]) -> Result<usize, ProxyError> {
        let mut stream = self.clone_stream(stream_id)?;
        stream.write_all(data).map_err(ProxyError::Io)?;
        Ok(data.len())
    }

    pub fn read(
        &self,
        stream_id: &str,
        max_bytes: usize,
        timeout_ms: i32,
    ) -> Result<ProxyReadResult, ProxyError> {
        let mut stream = self.clone_stream(stream_id)?;
        if timeout_ms >= 0 {
            stream
                .set_read_timeout(Some(Duration::from_millis(timeout_ms as u64)))
                .map_err(ProxyError::Io)?;
        } else {
            stream.set_read_timeout(None).map_err(ProxyError::Io)?;
        }

        let mut buf = vec![0_u8; max_bytes];
        match stream.read(&mut buf) {
            Ok(0) => Ok(ProxyReadResult {
                data: Vec::new(),
                eof: true,
            }),
            Ok(len) => {
                buf.truncate(len);
                Ok(ProxyReadResult {
                    data: buf,
                    eof: false,
                })
            }
            Err(err)
                if err.kind() == std::io::ErrorKind::WouldBlock
                    || err.kind() == std::io::ErrorKind::TimedOut =>
            {
                Ok(ProxyReadResult {
                    data: Vec::new(),
                    eof: false,
                })
            }
            Err(err) => Err(ProxyError::Io(err)),
        }
    }

    fn clone_stream(&self, stream_id: &str) -> Result<TcpStream, ProxyError> {
        let streams = self.streams.lock().unwrap();
        let stream = streams.get(stream_id).ok_or(ProxyError::NotFound)?;
        stream.try_clone().map_err(ProxyError::Io)
    }
}

//! A scripted [`CloudBackend`] for tests: HTTP replies are queued per path,
//! every request is recorded, and each upstream connection plays a queue of
//! frames while recording what the daemon sent.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::Value;

use super::{
    CloudBackend, CloudEvent, CloudWire, ConnectError, HttpReply, PutBody, RangeReply,
    TransportError, WireRecv,
};

/// One request the daemon sent. `bearer` is empty when no Authorization
/// header went out (a self-hosted Tailscale lease).
#[derive(Debug, Clone)]
pub struct Posted {
    pub url: String,
    pub bearer: String,
    pub client_version: Option<String>,
    pub body: Value,
}

#[derive(Debug, Clone)]
pub struct Connected {
    pub url: String,
    pub bearer: String,
}

/// One scripted upstream connection.
#[derive(Clone, Default)]
pub struct ScriptedWire {
    pub incoming: Arc<Mutex<VecDeque<WireRecv>>>,
    pub sent: Arc<Mutex<Vec<String>>>,
}

impl ScriptedWire {
    pub fn push_text(&self, text: impl Into<String>) {
        self.incoming
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back(WireRecv::Text(text.into()));
    }

    pub fn push_close(&self, code: Option<u16>) {
        self.incoming
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back(WireRecv::Closed { code });
    }

    pub fn sent(&self) -> Vec<String> {
        self.sent.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl CloudWire for ScriptedWire {
    fn send(&mut self, text: &str) -> Result<(), TransportError> {
        self.sent.lock().unwrap_or_else(PoisonError::into_inner).push(text.to_string());
        Ok(())
    }

    fn recv(&mut self, timeout: Duration) -> WireRecv {
        if let Some(next) = self.incoming.lock().unwrap_or_else(PoisonError::into_inner).pop_front()
        {
            return next;
        }
        std::thread::sleep(timeout.min(Duration::from_millis(2)));
        WireRecv::Idle
    }
}

#[derive(Default)]
pub struct FakeBackend {
    pub replies: Mutex<HashMap<String, VecDeque<Result<HttpReply, TransportError>>>>,
    pub posted: Mutex<Vec<Posted>>,
    pub patched: Mutex<Vec<Posted>>,
    pub wires: Mutex<VecDeque<Result<ScriptedWire, ConnectError>>>,
    pub connected: Mutex<Vec<Connected>>,
    /// `GET` requests (body `Null`); replies come from `replies` by path.
    pub got: Mutex<Vec<Posted>>,
    /// `PUT` requests: url and byte count; replies come from `replies` by path.
    pub put: Mutex<Vec<(String, usize)>>,
    /// Objects a ranged read serves, by path without the query: (mime, bytes).
    pub objects: Mutex<HashMap<String, (String, Vec<u8>)>>,
}

fn path_of(url: &str) -> String {
    url.find("/v1/").map_or(url, |at| &url[at..]).to_string()
}

impl FakeBackend {
    pub fn reply(&self, path: &str, status: u16, body: Value) {
        self.replies
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(path.to_string())
            .or_default()
            .push_back(Ok(HttpReply { status, body }));
    }

    pub fn fail(&self, path: &str, detail: &str) {
        self.replies
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(path.to_string())
            .or_default()
            .push_back(Err(TransportError(detail.to_string())));
    }

    pub fn wire(&self) -> ScriptedWire {
        let wire = ScriptedWire::default();
        self.wires.lock().unwrap_or_else(PoisonError::into_inner).push_back(Ok(wire.clone()));
        wire
    }

    pub fn refuse(&self, error: ConnectError) {
        self.wires.lock().unwrap_or_else(PoisonError::into_inner).push_back(Err(error));
    }

    pub fn posted(&self) -> Vec<Posted> {
        self.posted.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn connected(&self) -> Vec<Connected> {
        self.connected.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn got(&self) -> Vec<Posted> {
        self.got.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    pub fn put_requests(&self) -> Vec<(String, usize)> {
        self.put.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Serves `bytes` for ranged reads of `path` (without its query).
    pub fn object(&self, path: &str, mime: &str, bytes: Vec<u8>) {
        self.objects
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(path.to_string(), (mime.to_string(), bytes));
    }

    fn scripted(&self, path: &str) -> Result<HttpReply, TransportError> {
        self.replies
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(path)
            .and_then(VecDeque::pop_front)
            .unwrap_or_else(|| Err(TransportError(format!("no scripted reply for {path}"))))
    }
}

impl CloudBackend for FakeBackend {
    fn post(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        self.posted.lock().unwrap_or_else(PoisonError::into_inner).push(Posted {
            url: url.to_string(),
            bearer: bearer.unwrap_or_default().to_string(),
            client_version: client_version.map(str::to_string),
            body: body.clone(),
        });
        self.scripted(&path_of(url))
    }

    fn platform(
        &self,
        method: &str,
        url: &str,
        bearer: &str,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        let requests = match method {
            "GET" => &self.got,
            "POST" => &self.posted,
            "PATCH" => &self.patched,
            _ => return Err(TransportError("unsupported platform method".into())),
        };
        requests.lock().unwrap_or_else(PoisonError::into_inner).push(Posted {
            url: url.to_string(),
            bearer: bearer.to_string(),
            client_version: None,
            body: body.clone(),
        });
        self.scripted(&path_of(url))
    }

    fn get(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
    ) -> Result<HttpReply, TransportError> {
        self.got.lock().unwrap_or_else(PoisonError::into_inner).push(Posted {
            url: url.to_string(),
            bearer: bearer.unwrap_or_default().to_string(),
            client_version: client_version.map(str::to_string),
            body: Value::Null,
        });
        self.scripted(&path_of(url))
    }

    fn put(
        &self,
        url: &str,
        _headers: &[(String, String)],
        body: PutBody,
    ) -> Result<HttpReply, TransportError> {
        let len = usize::try_from(body.len()).unwrap_or(usize::MAX);
        self.put.lock().unwrap_or_else(PoisonError::into_inner).push((url.to_string(), len));
        self.scripted(&path_of(url))
    }

    fn get_range(&self, url: &str, offset: u64, length: u64) -> Result<RangeReply, TransportError> {
        let path = path_of(url);
        let path = path.split('?').next().unwrap_or_default().to_string();
        let objects = self.objects.lock().unwrap_or_else(PoisonError::into_inner);
        let Some((mime, bytes)) = objects.get(&path) else {
            return Ok(RangeReply { status: 404, content_type: None, total: None, body: vec![] });
        };
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
        let end =
            start.saturating_add(usize::try_from(length).unwrap_or(usize::MAX)).min(bytes.len());
        Ok(RangeReply {
            status: 206,
            content_type: Some(mime.clone()),
            total: Some(bytes.len() as u64),
            body: bytes[start..end].to_vec(),
        })
    }

    fn connect(
        &self,
        url: &str,
        bearer: Option<&str>,
        _client_version: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        self.connected.lock().unwrap_or_else(PoisonError::into_inner).push(Connected {
            url: url.to_string(),
            bearer: bearer.unwrap_or_default().to_string(),
        });
        match self.wires.lock().unwrap_or_else(PoisonError::into_inner).pop_front() {
            Some(Ok(wire)) => Ok(Box::new(wire)),
            Some(Err(error)) => Err(error),
            None => Err(ConnectError::Unavailable("no scripted connection".into())),
        }
    }
}

/// Collects emitted events.
#[derive(Clone, Default)]
pub struct Events(pub Arc<Mutex<Vec<CloudEvent>>>);

impl Events {
    pub fn sink(&self) -> super::EventSink {
        let events = self.0.clone();
        Arc::new(move |event| events.lock().unwrap_or_else(PoisonError::into_inner).push(event))
    }

    pub fn take(&self) -> Vec<CloudEvent> {
        std::mem::take(&mut *self.0.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// Waits (test-only polling) until `predicate` holds for the events seen
    /// so far, and returns them.
    pub fn wait_for(&self, predicate: impl Fn(&[CloudEvent]) -> bool) -> Vec<CloudEvent> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let seen = self.0.lock().unwrap_or_else(PoisonError::into_inner).clone();
            if predicate(&seen) {
                return seen;
            }
            assert!(Instant::now() < deadline, "timed out waiting for events: {seen:#?}");
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

/// Waits (test-only polling) until `condition` holds.
pub fn wait_until(what: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

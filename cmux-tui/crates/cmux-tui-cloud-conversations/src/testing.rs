//! A scripted [`CloudBackend`] for tests: HTTP replies are queued per path,
//! every request is recorded, and each upstream connection plays a queue of
//! frames while recording what the daemon sent.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::Value;

use super::{
    CloudBackend, CloudEvent, CloudWire, ConnectError, HttpReply, TransportError, WireRecv,
};

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
    pub wires: Mutex<VecDeque<Result<ScriptedWire, ConnectError>>>,
    pub connected: Mutex<Vec<Connected>>,
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
}

impl CloudBackend for FakeBackend {
    fn post(
        &self,
        url: &str,
        bearer: &str,
        client_version: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        self.posted.lock().unwrap_or_else(PoisonError::into_inner).push(Posted {
            url: url.to_string(),
            bearer: bearer.to_string(),
            client_version: client_version.map(str::to_string),
            body: body.clone(),
        });
        let path = url.find("/v1/").map_or(url, |at| &url[at..]).to_string();
        self.replies
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&path)
            .and_then(VecDeque::pop_front)
            .unwrap_or_else(|| Err(TransportError(format!("no scripted reply for {path}"))))
    }

    fn connect(
        &self,
        url: &str,
        bearer: &str,
        _client_version: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError> {
        self.connected
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(Connected { url: url.to_string(), bearer: bearer.to_string() });
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

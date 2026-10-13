//! uniffi bindings of cnx-link for the cnx-ios app (Swift).
//!
//! Every async function runs on one shared Tokio runtime owned by this
//! library, so Swift may await them from any executor.

use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use cnx_link::api::ApiClient;
use cnx_link::link::{ChannelReceiver, ChannelSender};
use cnx_link::{ChannelEvent, DialError, DialOptions, LinkConfig, SignalingClient};
use tokio::runtime::Runtime;

uniffi::setup_scaffolding!();

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("cnx-ffi")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// Run `future` on the library runtime and await it from any executor.
async fn on_runtime<F, T>(future: F) -> T
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    match runtime().spawn(future).await {
        Ok(value) => value,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

/// Settings → Connection → Transport.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Transport {
    WebRtc,
    WireGuard,
}

impl From<Transport> for cnx_link::TransportKind {
    fn from(value: Transport) -> Self {
        match value {
            Transport::WebRtc => Self::WebRtc,
            Transport::WireGuard => Self::WireGuard,
        }
    }
}

/// How the link's bytes travel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkPath {
    Direct,
    Relay,
    Turn,
}

impl From<cnx_link::LinkPath> for LinkPath {
    fn from(value: cnx_link::LinkPath) -> Self {
        match value {
            cnx_link::LinkPath::Direct => Self::Direct,
            cnx_link::LinkPath::Relay => Self::Relay,
            cnx_link::LinkPath::Turn => Self::Turn,
        }
    }
}

/// Link state events, in order: `Connecting`, then `Connected` (or
/// `Disconnected` when the dial fails), then any number of `PathChanged` and
/// `Rtt`, then one `Disconnected`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LinkEvent {
    Connecting { transport: Transport },
    Connected { transport: Transport, path: LinkPath },
    PathChanged { path: LinkPath },
    Rtt { millis: u32 },
    Disconnected { reason: String },
}

/// Receives link state events on a library thread.
#[uniffi::export(with_foreign)]
pub trait LinkObserver: Send + Sync {
    fn on_event(&self, event: LinkEvent);
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CnxError {
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
    #[error("signaling: {message}")]
    Signaling { message: String },
    #[error("refused: {code}: {message}")]
    Refused { code: String, message: String },
    #[error("timed out")]
    Timeout,
    #[error("transport: {message}")]
    Transport { message: String },
    #[error("closed: {message}")]
    Closed { message: String },
}

impl From<DialError> for CnxError {
    fn from(error: DialError) -> Self {
        match error {
            DialError::Signaling(message) => Self::Signaling { message },
            DialError::Refused { code, message } => Self::Refused { code, message },
            DialError::Bye(reason) => Self::Refused { code: "bye".into(), message: reason },
            DialError::Timeout => Self::Timeout,
            DialError::Transport(message) | DialError::Unexpected(message) => Self::Transport { message },
        }
    }
}

impl From<cnx_link::LinkError> for CnxError {
    fn from(error: cnx_link::LinkError) -> Self {
        Self::Closed { message: error.to_string() }
    }
}

/// One message from a channel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ChannelMessage {
    Data {
        bytes: Vec<u8>,
    },
    /// The channel is closed; every later `recv` returns this again.
    Closed {
        code: String,
        reason: String,
    },
}

/// A connected link to one Mac.
#[derive(uniffi::Object)]
pub struct LinkHandle {
    link: cnx_link::Link,
    signaling: SignalingClient,
    transport: Transport,
    path: tokio::sync::watch::Receiver<cnx_link::LinkPath>,
    watcher: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for LinkHandle {
    fn drop(&mut self) {
        self.link.close("handle dropped");
        self.signaling.close();
        if let Some(task) = self.watcher.lock().unwrap_or_else(PoisonError::into_inner).take() {
            task.abort();
        }
    }
}

#[uniffi::export]
impl LinkHandle {
    /// Open a channel to `service` (`echo`, `daemon`, `acpmux`, `file`) with
    /// `args_json`, a JSON object (empty string means `{}`). A refusal
    /// arrives as the first `recv`: `Closed { code: "unknown_service" … }`.
    pub async fn open_channel(
        &self,
        service: String,
        args_json: String,
    ) -> Result<Arc<ChannelHandle>, CnxError> {
        let args: serde_json::Value = if args_json.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&args_json)
                .map_err(|e| CnxError::InvalidArgument { message: format!("args_json: {e}") })?
        };
        if !args.is_object() {
            return Err(CnxError::InvalidArgument { message: "args_json must be a JSON object".into() });
        }
        let link = self.link.clone();
        let channel = on_runtime(async move { link.open(&service, args).await }).await?;
        let id = channel.id();
        let (sender, receiver) = channel.split();
        Ok(Arc::new(ChannelHandle {
            id,
            sender: Arc::new(sender),
            receiver: Arc::new(tokio::sync::Mutex::new(receiver)),
            closed: Arc::new(Mutex::new(None)),
        }))
    }

    /// Round-trip one ping; milliseconds.
    pub async fn ping(&self) -> Result<u32, CnxError> {
        let link = self.link.clone();
        let rtt = on_runtime(async move { link.ping().await }).await?;
        Ok(u32::try_from(rtt.as_millis()).unwrap_or(u32::MAX))
    }

    pub fn transport(&self) -> Transport {
        self.transport
    }

    pub fn path(&self) -> LinkPath {
        (*self.path.borrow()).into()
    }

    pub fn is_closed(&self) -> bool {
        self.link.is_closed()
    }

    /// Close the link, its transport and its signaling socket.
    pub fn close(&self) {
        self.link.close("closed by the app");
        self.signaling.close();
    }
}

/// One multiplexed channel.
#[derive(uniffi::Object)]
pub struct ChannelHandle {
    id: u32,
    sender: Arc<ChannelSender>,
    receiver: Arc<tokio::sync::Mutex<ChannelReceiver>>,
    closed: Arc<Mutex<Option<(String, String)>>>,
}

#[uniffi::export]
impl ChannelHandle {
    pub fn id(&self) -> u32 {
        self.id
    }

    pub async fn send(&self, data: Vec<u8>) -> Result<(), CnxError> {
        let sender = Arc::clone(&self.sender);
        on_runtime(async move { sender.send(data.into()).await }).await?;
        Ok(())
    }

    /// The next message. Calls are serialized; after `Closed` every call
    /// returns the same `Closed`.
    pub async fn recv(&self) -> ChannelMessage {
        if let Some((code, reason)) = self.closed.lock().unwrap_or_else(PoisonError::into_inner).clone() {
            return ChannelMessage::Closed { code, reason };
        }
        let receiver = Arc::clone(&self.receiver);
        let closed = Arc::clone(&self.closed);
        on_runtime(async move {
            let event = receiver.lock().await.recv().await;
            match event {
                Some(ChannelEvent::Data(bytes)) => ChannelMessage::Data { bytes: bytes.to_vec() },
                Some(ChannelEvent::Closed(info)) => {
                    *closed.lock().unwrap_or_else(PoisonError::into_inner) =
                        Some((info.code.clone(), info.reason.clone()));
                    ChannelMessage::Closed { code: info.code, reason: info.reason }
                }
                None => {
                    let stored = closed.lock().unwrap_or_else(PoisonError::into_inner).clone();
                    let (code, reason) = stored.unwrap_or_else(|| ("closed".into(), String::new()));
                    ChannelMessage::Closed { code, reason }
                }
            }
        })
        .await
    }

    pub async fn close(&self, code: String, reason: String) {
        let sender = Arc::clone(&self.sender);
        on_runtime(async move { sender.close(&code, &reason).await }).await;
    }
}

/// Dial options beyond the transport. Every field has a default, so
/// `ConnectOptions()` in Swift is the plain dial.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ConnectOptions {
    /// Debug "simulate distant network": skip every direct path. WebRTC
    /// uses ICE transport policy `relay` with the service's TURN servers
    /// (path `Turn`; no TURN server fails the dial), WireGuard uses only the
    /// backend relay frames (path `Relay`).
    #[uniffi(default = false)]
    pub relay_only: bool,
}

/// Dial `mac_device_id` from this phone (`device_id`) over `transport`.
/// `base_url` is the backend (`https://cnx-ios-api-…workers.dev`), `token`
/// a Stack access token, `team_id` the team whose signaling hub to use.
/// Same as `connect_with_options` with default options.
#[uniffi::export]
pub async fn connect(
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
    mac_device_id: String,
    transport: Transport,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CnxError> {
    connect_with_options(
        base_url,
        token,
        team_id,
        device_id,
        mac_device_id,
        transport,
        ConnectOptions::default(),
        observer,
    )
    .await
}

/// `connect` with `options` (relay only).
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub async fn connect_with_options(
    base_url: String,
    token: String,
    team_id: String,
    device_id: String,
    mac_device_id: String,
    transport: Transport,
    options: ConnectOptions,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CnxError> {
    let request = ConnectRequest {
        base_url,
        token,
        team_id,
        device_id,
        mac_device_id,
        transport,
        include_loopback: false,
        relay_only: options.relay_only,
    };
    on_runtime(connect_inner(request, observer)).await
}

/// The library version.
#[uniffi::export]
pub fn cnx_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[doc(hidden)]
pub struct ConnectRequest {
    pub base_url: String,
    pub token: String,
    pub team_id: String,
    pub device_id: String,
    pub mac_device_id: String,
    pub transport: Transport,
    pub include_loopback: bool,
    pub relay_only: bool,
}

fn emit(observer: &Option<Arc<dyn LinkObserver>>, event: LinkEvent) {
    if let Some(observer) = observer {
        observer.on_event(event);
    }
}

#[doc(hidden)]
pub async fn connect_inner(
    request: ConnectRequest,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<LinkHandle>, CnxError> {
    let transport = request.transport;
    emit(&observer, LinkEvent::Connecting { transport });
    let result = dial(&request).await;
    let (connected, signaling) = match result {
        Ok(ok) => ok,
        Err(error) => {
            emit(&observer, LinkEvent::Disconnected { reason: error.to_string() });
            return Err(error);
        }
    };
    let mut path = connected.path.clone();
    emit(&observer, LinkEvent::Connected { transport, path: (*path.borrow()).into() });
    let link = connected.link.clone();
    let watcher = tokio::spawn(async move {
        let mut rtt = link.rtt();
        let mut closed = link.closed_state();
        loop {
            tokio::select! {
                changed = path.changed() => {
                    if changed.is_err() { break; }
                    emit(&observer, LinkEvent::PathChanged { path: (*path.borrow_and_update()).into() });
                }
                changed = rtt.changed() => {
                    if changed.is_err() { break; }
                    let value = *rtt.borrow_and_update();
                    if let Some(value) = value {
                        emit(&observer, LinkEvent::Rtt { millis: u32::try_from(value.as_millis()).unwrap_or(u32::MAX) });
                    }
                }
                reason = closed.wait_for(Option::is_some) => {
                    let reason = reason.map(|r| r.clone().unwrap_or_default()).unwrap_or_default();
                    emit(&observer, LinkEvent::Disconnected { reason });
                    return;
                }
            }
        }
        let reason = link.closed().await;
        emit(&observer, LinkEvent::Disconnected { reason });
    });
    // Measure once right away so the app shows an RTT immediately.
    let first_ping = connected.link.clone();
    tokio::spawn(async move {
        let _ = first_ping.ping().await;
    });
    Ok(Arc::new(LinkHandle {
        link: connected.link,
        signaling,
        transport,
        path: connected.path,
        watcher: Mutex::new(Some(watcher)),
    }))
}

async fn dial(request: &ConnectRequest) -> Result<(cnx_link::Connected, SignalingClient), CnxError> {
    for (name, value) in [
        ("base_url", &request.base_url),
        ("team_id", &request.team_id),
        ("device_id", &request.device_id),
        ("mac_device_id", &request.mac_device_id),
    ] {
        if value.trim().is_empty() {
            return Err(CnxError::InvalidArgument { message: format!("{name} is empty") });
        }
    }
    let api = ApiClient::new(&request.base_url, &request.token);
    let ice = tokio::time::timeout(Duration::from_secs(8), api.ice()).await;
    let ice_servers = match ice {
        Ok(Ok(config)) => config.ice_servers,
        _ => Vec::new(),
    };
    let signaling =
        SignalingClient::connect(&request.base_url, &request.token, &request.team_id, &request.device_id)
            .await
            .map_err(|e| CnxError::Signaling { message: e.to_string() })?;
    let options = DialOptions {
        ice_servers,
        include_loopback: request.include_loopback,
        relay_only: request.relay_only,
        ..DialOptions::default()
    };
    match cnx_link::dial::connect(
        &signaling,
        &request.mac_device_id,
        request.transport.into(),
        &options,
        LinkConfig::default(),
    )
    .await
    {
        Ok(connected) => Ok((connected, signaling)),
        Err(error) => {
            signaling.close();
            Err(error.into())
        }
    }
}

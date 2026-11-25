//! The pushed state of the Cloud machines the app shows, held by the daemon (Leo, 2026-11-05: "yes"
//! to a per-machine state object so the app stops polling). One WebSocket per watched machine,
//! `GET /v1/cloud/machines/{id}/state` on the platform Worker (cmux-platform `MachineState`,
//! protocol `cmux.machine-state/1`), opened with the person's lease bearer, the cmux team and the
//! build space. What a frame means, which machines get a socket and how long a closed one waits are
//! cmux-cloud-machine's `push`; this file only holds the sockets.
//!
//! The app names the machines to watch (`apps-machine-state-watch`, the list it shows). Each state
//! frame goes as it came to the first-party Cloud server (`Supervisor::team_event`, the call
//! `apps-team-event` makes), which applies it to its machine projection; the record it carries, the
//! machine going live (a frame reached the Cloud server) and going lost (its socket closed, or a
//! hand-off failed) go to the app as `apps-cloud-machine` events.
//!
//! A socket that closes (the platform ends one at its token's expiry, an hour at most, or the
//! network dropped) is opened again with a fresh bearer after a capped backoff: a reconnect, not a
//! poll. Nothing here logs a token or a frame. A redirect is refused (the upgrade is never
//! followed), so the bearer cannot be carried elsewhere.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;

use cmux_cloud_machine::push::{self, Frame};
use cmux_cloud_machine::record::Machine;
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::task::AbortHandle;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use zeroize::Zeroizing;

use crate::mux::Mux;

/// The event the app hears: `{machine, kind: "record" | "live" | "lost", record?}`.
pub(crate) const EVENT: &str = "apps-cloud-machine";
/// A frame is at most this many bytes (the platform's are a record; URLSession's own default).
const MAX_FRAME_BYTES: usize = 1024 * 1024;

/// Where an event for the app goes (the connection's writer); false once it is gone.
pub(crate) type Sink = Arc<dyn Fn(&Value) -> bool + Send + Sync>;

/// What the sockets need from the daemon.
pub(crate) trait Host: Send + Sync + 'static {
    /// The person's bearer and its lease generation; Err when signed out or the lease is not
    /// usable (an expiring or expired one also asks the app for a new one).
    fn bearer(&self) -> Result<(Zeroizing<String>, u64), ()>;
    /// An upgrade was refused (401) on lease `generation`: the app renews the lease.
    fn unauthenticated(&self, generation: u64);
    /// Passes a frame to the Cloud app server; whether one took it (`push::handed_off`).
    fn forward(&self, data: &Value) -> bool;
    /// Whether lease `generation` is still the daemon's: a sign-out, another account or a renewal
    /// replaces it, and a socket opened on an older one delivers nothing more.
    fn current(&self, generation: u64) -> bool;
}

/// The waits; tests shorten them.
#[derive(Clone, Debug)]
pub(crate) struct Timing {
    /// An open socket sends the protocol's ping this often.
    pub(crate) keepalive: Duration,
    /// One socket upgrade or write.
    pub(crate) handshake: Duration,
    /// The reconnect waits (`push::backoff`) are divided by this.
    pub(crate) speedup: u32,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            keepalive: Duration::from_millis(push::KEEPALIVE_MS),
            handshake: Duration::from_secs(15),
            speedup: 1,
        }
    }
}

/// What the app asked to watch.
pub(crate) struct Watch {
    /// The list's records: a listed record is the last one known until a frame brings a newer one.
    pub(crate) machines: Vec<Machine>,
    /// The platform origin (https, or http on a loopback host).
    pub(crate) platform: String,
    pub(crate) team: Option<String>,
}

struct Entry {
    /// This watch's id: a task whose entry was replaced or removed finds a different one.
    watch: u64,
    /// The open socket's id, larger than every one before it.
    socket: u64,
    open: bool,
    /// A frame of the open socket reached the Cloud app server.
    live: bool,
    last: Option<Machine>,
    task: AbortHandle,
}

struct Client {
    sink: Sink,
    host: Arc<dyn Host>,
    platform: String,
    team: Option<String>,
    machines: HashMap<String, Entry>,
}

impl Client {
    fn end(&mut self, machine: &str) {
        if let Some(entry) = self.machines.remove(machine) {
            entry.task.abort();
        }
    }

    fn emit(&self, machine: &str, kind: &str, record: Option<&Machine>) {
        let mut event = json!({ "event": EVENT, "machine": machine, "kind": kind });
        if let Some(record) = record {
            if let Some(map) = event.as_object_mut() {
                map.insert("record".into(), serde_json::to_value(record).unwrap_or(Value::Null));
            }
        }
        (self.sink)(&event);
    }
}

#[derive(Default)]
struct Inner {
    clients: HashMap<u64, Client>,
}

struct Shared {
    inner: Mutex<Inner>,
    timing: Timing,
    next: AtomicU64,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// The sockets of every connection that watches machines, and the runtime they run on.
pub(crate) struct MachineStatePush {
    runtime: OnceLock<Option<tokio::runtime::Runtime>>,
    shared: Arc<Shared>,
}

impl Default for MachineStatePush {
    fn default() -> Self {
        Self::with_timing(Timing::default())
    }
}

impl Drop for MachineStatePush {
    fn drop(&mut self) {
        // Never blocks, so the last daemon reference may go on a runtime thread.
        if let Some(Some(runtime)) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

/// `scheme://host[:port]` of `raw`: https, or http on a loopback host; no path, query or user.
pub(crate) fn platform_origin(raw: &str) -> Option<String> {
    let url = url::Url::parse(raw.trim()).ok()?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return None;
    }
    let loopback = match url.host()? {
        url::Host::Domain(domain) => domain.eq_ignore_ascii_case("localhost"),
        url::Host::Ipv4(ip) => ip.is_loopback(),
        url::Host::Ipv6(ip) => ip.is_loopback(),
    };
    match url.scheme() {
        "https" => {}
        "http" if loopback => {}
        _ => return None,
    }
    Some(url.origin().ascii_serialization())
}

impl MachineStatePush {
    pub(crate) fn with_timing(timing: Timing) -> Self {
        Self {
            runtime: OnceLock::new(),
            shared: Arc::new(Shared {
                inner: Mutex::new(Inner::default()),
                timing,
                next: AtomicU64::new(0),
            }),
        }
    }

    fn runtime(&self) -> Option<&tokio::runtime::Runtime> {
        self.runtime
            .get_or_init(|| {
                let _ = rustls::crypto::ring::default_provider().install_default();
                let mut builder = tokio::runtime::Builder::new_multi_thread();
                builder.worker_threads(1).thread_name("mux-machine-state").enable_all().build().ok()
            })
            .as_ref()
    }

    /// Watches exactly `request.machines` for `client`: opens a socket for each new one and closes
    /// the ones no longer listed. An empty list closes every socket of this client.
    pub(crate) fn watch(
        &self,
        client: u64,
        sink: Sink,
        host: Arc<dyn Host>,
        request: Watch,
    ) -> Result<(), &'static str> {
        if request.machines.is_empty() {
            self.stop(client);
            return Ok(());
        }
        let platform =
            platform_origin(&request.platform).ok_or("the platform origin must be https")?;
        let runtime = self.runtime().ok_or("no runtime for the state sockets")?;
        let mut inner = self.shared.lock();
        // A different platform is a different set of sockets (a bearer goes only where it was named).
        if inner.clients.get(&client).is_some_and(|c| c.platform != platform) {
            self.end_client(&mut inner, client);
        }
        let entry = inner.clients.entry(client).or_insert_with(|| Client {
            sink: sink.clone(),
            host: host.clone(),
            platform: platform.clone(),
            team: None,
            machines: HashMap::new(),
        });
        entry.sink = sink;
        entry.host = host;
        entry.team = request.team;
        let shown: std::collections::HashSet<&str> =
            request.machines.iter().map(|m| m.id.as_str()).collect();
        let gone: Vec<String> =
            entry.machines.keys().filter(|id| !shown.contains(id.as_str())).cloned().collect();
        for id in gone {
            entry.end(&id);
        }
        for machine in request.machines {
            if push::state_url(&platform, &machine.id).is_none() {
                continue;
            }
            let id = machine.id.clone();
            if let Some(held) = entry.machines.get_mut(&id) {
                if push::keeps_listed(held.last.as_ref(), &machine) {
                    held.last = Some(machine);
                }
                continue;
            }
            let watch = self.shared.next.fetch_add(1, Ordering::Relaxed) + 1;
            let task = runtime.spawn(run(self.shared.clone(), client, id.clone(), watch));
            entry.machines.insert(
                id,
                Entry {
                    watch,
                    socket: 0,
                    open: false,
                    live: false,
                    last: Some(machine),
                    task: task.abort_handle(),
                },
            );
        }
        Ok(())
    }

    /// Closes every socket of `client` (its connection closed, sign-out, a team switch).
    pub(crate) fn stop(&self, client: u64) {
        let mut inner = self.shared.lock();
        self.end_client(&mut inner, client);
    }

    fn end_client(&self, inner: &mut Inner, client: u64) {
        if let Some(gone) = inner.clients.remove(&client) {
            for entry in gone.machines.into_values() {
                entry.task.abort();
            }
        }
    }

    /// How many machines `client` holds a watch for.
    #[cfg(test)]
    pub(crate) fn watching(&self, client: u64) -> usize {
        self.shared.lock().clients.get(&client).map_or(0, |c| c.machines.len())
    }
}

/// The daemon behind the sockets: the lease the app gave it, and the Cloud app server.
pub(crate) struct MuxHost(pub(crate) Weak<Mux>);

impl Host for MuxHost {
    fn bearer(&self) -> Result<(Zeroizing<String>, u64), ()> {
        let mux = self.0.upgrade().ok_or(())?;
        let bearer = mux.cloud_conversations().ok_or(())?.lease_bearer().map_err(|_| ())?;
        Ok((bearer.token, bearer.generation))
    }

    fn unauthenticated(&self, generation: u64) {
        if let Some(cloud) = self.0.upgrade().and_then(|mux| mux.cloud_conversations().cloned()) {
            cloud.report_unauthenticated(generation);
        }
    }

    fn forward(&self, data: &Value) -> bool {
        let Some(mux) = self.0.upgrade() else { return false };
        let supervisor = mux.control_clients.apps.get_or_init(&mux);
        push::handed_off(supervisor.team_event("cloud.machine.state", data).ok().as_ref())
    }

    fn current(&self, generation: u64) -> bool {
        self.0.upgrade().is_some_and(|mux| {
            mux.cloud_conversations().is_some_and(|cloud| cloud.lease_generation() == generation)
        })
    }
}

/// One machine's life: a socket, then a capped backoff, until its watch ends.
async fn run(shared: Arc<Shared>, client: u64, machine: String, watch: u64) {
    let mut next = push::FIRST_BACKOFF_MS;
    loop {
        let Some((host, platform, team)) = shared.context(client, &machine, watch) else { return };
        let opened = connect(&shared, &*host, &platform, team, client, &machine, watch).await;
        let Some(was_live) = shared.closed(client, &machine, watch) else { return };
        let _ = was_live;
        // A socket that delivered frames closed (a token expiry, a deploy): the next waits the
        // first backoff; one that never delivered doubles it. Every close waits, so a socket that
        // opens and closes cannot spin.
        let (wait, after) = push::backoff(next, opened);
        next = after;
        tokio::time::sleep(Duration::from_millis(wait) / shared.timing.speedup.max(1)).await;
    }
}

impl Shared {
    fn context(
        &self,
        client: u64,
        machine: &str,
        watch: u64,
    ) -> Option<(Arc<dyn Host>, String, Option<String>)> {
        let inner = self.lock();
        let c = inner.clients.get(&client)?;
        c.machines.get(machine).filter(|e| e.watch == watch)?;
        Some((c.host.clone(), c.platform.clone(), c.team.clone()))
    }

    /// The socket closed: until one delivers again the machine is not pushed. None when the watch
    /// is gone. Pushes stopped for a live one, so the app hears `lost`.
    fn closed(&self, client: u64, machine: &str, watch: u64) -> Option<bool> {
        let mut inner = self.lock();
        let c = inner.clients.get_mut(&client)?;
        let entry = c.machines.get_mut(machine).filter(|e| e.watch == watch)?;
        let was_live = std::mem::take(&mut entry.live);
        entry.open = false;
        if was_live {
            c.emit(machine, "lost", None);
        }
        Some(was_live)
    }

    /// The socket opened: its id, None when the watch is gone.
    fn opened(&self, client: u64, machine: &str, watch: u64) -> Option<u64> {
        let mut inner = self.lock();
        let entry = inner
            .clients
            .get_mut(&client)?
            .machines
            .get_mut(machine)
            .filter(|e| e.watch == watch)?;
        entry.socket += 1;
        entry.open = true;
        Some(entry.socket)
    }

    /// One frame: to the app server first (so an op waiting on the machine runs as the record
    /// shows), then its record, then whether the machine is live. All under the lock, so a frame
    /// received before a stop or a replaced watch is never delivered after it. A frame on a socket
    /// whose lease `generation` was replaced (a sign-out, an account switch) is dropped: the old
    /// account's records never reach the new one, and the socket reopens on the current lease.
    /// False ends the socket.
    fn frame(
        &self,
        client: u64,
        machine: &str,
        watch: u64,
        socket: u64,
        generation: u64,
        text: &str,
    ) -> bool {
        let mut inner = self.lock();
        let Some(c) = inner.clients.get_mut(&client) else { return false };
        let host = c.host.clone();
        let Some(entry) = c
            .machines
            .get_mut(machine)
            .filter(|e| e.watch == watch && e.open && e.socket == socket)
        else {
            return false;
        };
        if !host.current(generation) {
            return false;
        }
        match push::frame(machine, text, entry.last.as_ref()) {
            Frame::Ignore => true,
            Frame::State { forward, record } => {
                let ok = host.forward(&forward);
                entry.last = Some(record.clone());
                let changed = entry.live != ok;
                entry.live = ok;
                c.emit(machine, "record", Some(&record));
                if changed {
                    c.emit(machine, if ok { "live" } else { "lost" }, None);
                }
                true
            }
            Frame::Removed { forward, record } => {
                host.forward(&forward);
                // The machine is gone for good: its socket closes now, not at the next list.
                c.end(machine);
                if let Some(gone) = record {
                    c.emit(machine, "record", Some(&gone));
                }
                false
            }
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// One socket's life; true when it delivered at least one frame.
async fn connect(
    shared: &Shared,
    host: &dyn Host,
    platform: &str,
    team: Option<String>,
    client: u64,
    machine: &str,
    watch: u64,
) -> bool {
    let timing = &shared.timing;
    let Some(url) = push::state_url(platform, machine) else { return false };
    let Ok((token, generation)) = host.bearer() else { return false };
    let Ok(mut request) = url.into_client_request() else { return false };
    let Ok(bearer) = HeaderValue::from_str(&format!("Bearer {}", token.as_str())) else {
        return false;
    };
    request.headers_mut().insert("authorization", bearer);
    if let Some(team) = team {
        let Ok(team) = HeaderValue::from_str(&team) else { return false };
        request.headers_mut().insert("x-cmux-team", team);
    }
    // A misconfigured dev build opens no socket (its refusal is cmux_build_space's).
    if cmux_build_space::insert(request.headers_mut()).is_err() {
        return false;
    }
    drop(token);
    let config = tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let attempt = tokio_tungstenite::connect_async_with_config(request, Some(config), false);
    let socket: Ws = match tokio::time::timeout(timing.handshake, attempt).await {
        Ok(Ok((socket, _))) => socket,
        Ok(Err(tungstenite::Error::Http(reply))) => {
            // The platform refused the bearer (a redirect is an `Http` error too, never followed).
            if reply.status().as_u16() == 401 {
                host.unauthenticated(generation);
            }
            return false;
        }
        _ => return false,
    };
    let Some(id) = shared.opened(client, machine, watch) else { return false };
    let (mut sink, mut stream) = socket.split();
    let mut delivered = false;
    let mut ping = tokio::time::Instant::now() + timing.keepalive;
    loop {
        tokio::select! {
            () = tokio::time::sleep_until(ping) => {
                ping = tokio::time::Instant::now() + timing.keepalive;
                let sent = tokio::time::timeout(timing.handshake, sink.send(Message::text(push::PING)));
                if !sent.await.is_ok_and(|sent| sent.is_ok()) {
                    break;
                }
            }
            message = stream.next() => {
                let text = match message {
                    Some(Ok(Message::Text(text))) => text.as_str().to_owned(),
                    Some(Ok(Message::Binary(bytes))) => String::from_utf8_lossy(&bytes).into_owned(),
                    Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => continue,
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                };
                delivered = true;
                if !shared.frame(client, machine, watch, id, generation, &text) {
                    break;
                }
            }
        }
    }
    let _ = tokio::time::timeout(timing.handshake, sink.close()).await;
    delivered
}

#[cfg(test)]
#[path = "machine_state_push_tests.rs"]
mod tests;

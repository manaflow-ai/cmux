//! The heartbeat: probe the live link on an interval and redial when it stops answering.

use super::*;

pub(super) async fn run_heartbeat(
    weak: Weak<ClientConnection>,
    interval: Duration,
    timeout: Duration,
) {
    let Some(initial) = weak.upgrade() else { return };
    let mut close_state = initial.close_state.subscribe();
    // A new watch receiver considers the current value seen. The atomic flag
    // closes the gap when shutdown started immediately before subscription.
    if initial.closed.load(Ordering::Acquire) {
        return;
    }
    // A network change probes at once instead of at the next interval.
    let mut network = initial.network.subscribe();
    network.borrow_and_update();
    drop(initial);
    let mut route = RouteSource::default();
    let fast_fallback = fast_fallback_enabled();
    loop {
        // Where the link's route leaves from, read before the wait: a change that kills the
        // address is compared with the address as it was.
        if let Some(connection) = weak.upgrade() {
            route.refresh(&connection).await;
        }
        let network_moved = tokio::select! {
            biased;
            _ = close_state.changed() => return,
            _ = network.changed() => true,
            _ = tokio::time::sleep(interval) => false,
        };
        let Some(connection) = weak.upgrade() else { return };
        if connection.closed.load(Ordering::Acquire) || connection.session_unavailable() {
            return;
        }
        if connection
            .deferred_receive
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
        {
            // The consumer must drain its deferred frame before another probe
            // can be observed without expanding local buffering.
            continue;
        }
        let observed = connection.last_received();
        let generation = connection.session.read().await.generation();
        if route.is_gone() {
            // The address this link was dialed from is no longer ours: the kernel drops what it
            // sends, so no probe could be answered. Redial now instead of waiting one out.
            route.forget();
            let _ = connection.recover(generation).await;
            continue;
        }
        // After a network change the old route may be gone with a write stuck on it: the
        // probe queues behind that write and never goes out. Waiting the full answer window
        // for it held a blocked link up to 4 s past the change; give it the short one.
        let change_window = network_change_window(route.direct, fast_fallback);
        let timeout = if network_moved { timeout.min(change_window) } else { timeout };
        let mut deadline = tokio::time::Instant::now() + timeout;
        let send = connection.send_in_generation(
            Some(generation),
            Lane::Control,
            0,
            Bytes::new(),
            FrameFlags::HEARTBEAT_REQUEST,
        );
        let Ok(send_result) =
            probe_by(send, &mut deadline, change_window, &mut network, &mut close_state, &|| {
                route.is_gone()
            })
            .await
        else {
            return;
        };
        match send_result {
            Some(Ok(_)) => {}
            Some(Err(_)) => continue,
            None => {
                route.forget_if_gone();
                let _ = connection.recover(generation).await;
                continue;
            }
        }
        let answer = connection.probe_liveness(generation, observed);
        let Ok(live) =
            probe_by(answer, &mut deadline, change_window, &mut network, &mut close_state, &|| {
                route.is_gone()
            })
            .await
        else {
            return;
        };
        let live = live.unwrap_or(false);
        if connection.closed.load(Ordering::Acquire)
            || connection.session.read().await.generation() != generation
        {
            continue;
        }
        if !live && connection.last_received() <= observed {
            route.forget_if_gone();
            let _ = connection.recover(generation).await;
        }
    }
}

/// The local address the link's route leaves from, as the heartbeat last saw it.
#[derive(Default)]
struct RouteSource {
    /// The route's host and what it resolved to: resolved once per host, not per beat.
    remote: Option<(String, Option<std::net::IpAddr>)>,
    source: Option<std::net::IpAddr>,
    /// The selected path is direct (not a relay): a network change gets the fast fallback's
    /// window when it is on.
    direct: bool,
}

impl RouteSource {
    async fn refresh(&mut self, connection: &ClientConnection) {
        if self.is_gone() {
            // Keep the address that went away until the heartbeat has acted on it.
            return;
        }
        let group = connection.group.read().await.clone();
        let selected = group.transport_snapshot().await.selected_path;
        self.direct = selected
            .as_ref()
            .is_some_and(|path| path.kind == crate::observability::TransportPathKind::Direct);
        let host = selected.and_then(|path| path.remote);
        let Some(host) = host else {
            self.source = None;
            return;
        };
        let address = match &self.remote {
            Some((known, address)) if *known == host => *address,
            _ => {
                let address = crate::route_source::resolve_host(&host).await;
                self.remote = Some((host, address));
                address
            }
        };
        self.source = address.and_then(crate::route_source::source_toward);
    }

    fn forget(&mut self) {
        self.source = None;
    }

    /// The probe failed: a source that is gone is acted on by this redial, so it is not kept.
    fn forget_if_gone(&mut self) {
        if self.is_gone() {
            self.forget();
        }
    }

    fn is_gone(&self) -> bool {
        self.source.is_some_and(crate::route_source::address_is_gone)
    }
}

/// Await one phase of a heartbeat probe until `deadline`: `Ok(None)` when it passes, `Err` when
/// the connection closes. A network change meanwhile pulls `deadline` in to
/// `change_window` from the change ([`network_change_window`]), so a probe already stuck behind a write
/// on the route that went away does not wait out the full answer window.
async fn probe_by<T>(
    phase: impl Future<Output = T>,
    deadline: &mut tokio::time::Instant,
    change_window: Duration,
    network: &mut watch::Receiver<u64>,
    close_state: &mut watch::Receiver<CloseState>,
    route_gone: &(dyn Fn() -> bool + Sync),
) -> Result<Option<T>, ()> {
    tokio::pin!(phase);
    loop {
        tokio::select! {
            biased;
            result = tokio::time::timeout_at(*deadline, phase.as_mut()) => return Ok(result.ok()),
            _ = close_state.changed() => return Err(()),
            Ok(()) = network.changed() => {
                // A route whose address is gone cannot answer: end the probe now.
                let wait = if route_gone() { Duration::ZERO } else { change_window };
                let short = tokio::time::Instant::now() + wait;
                *deadline = (*deadline).min(short);
            }
        }
    }
}

#[cfg(test)]
#[path = "route_source_tests.rs"]
mod route_source_tests;

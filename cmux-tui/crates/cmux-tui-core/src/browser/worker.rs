//! The surface's CDP event handler (served on the shared event lanes), the
//! per-surface command worker loop, pointer and lifecycle deadlines, and
//! status/dirty/failure notifications.

use super::event_lanes::LaneFlow;
use super::event_registry::{RegistryWork, run_registry_work};
use super::*;
use crate::serial_lanes::{Lane, LaneNext};
use std::sync::OnceLock;
use std::sync::mpsc::TryRecvError;

/// Serves the surface's CDP events in order on the shared event-lane pool
/// (`browser-events-<n>`); a surface has no event thread of its own.
pub(super) fn start_surface_thread(
    surface: Arc<Surface>,
    events: Arc<SurfaceRoute>,
    mux: Weak<Mux>,
    runtime: Weak<BrowserRuntime>,
    route_session_id: String,
) -> anyhow::Result<()> {
    let id = surface.id;
    // tab-attention-v1: the page URL this lane last asked about, so repeated
    // events on one page read nothing. Whether a mark goes is decided against
    // the page the mark recorded, not this, so the first event (even one
    // after the URL already moved) still clears it.
    let mut seen_url: Option<String> = None;
    let route = Arc::downgrade(&events);
    events.attach_handler(Box::new(move |event| {
        let Surface::Browser(browser) = surface.as_ref() else { return LaneFlow::End };
        let seen_url = &mut seen_url;
        match event {
            CdpEvent::ScreencastFrame(frame) => {
                let frame_epoch = frame.frame_epoch;
                let frame = BrowserFrame {
                    session_id: frame.session_id,
                    data_b64: frame.data_b64,
                    css_width: frame.css_width,
                    css_height: frame.css_height,
                    image_width: frame.image_width,
                    image_height: frame.image_height,
                    seq: 0,
                };
                let visible_state_changed = browser.store_frame_for_epoch(frame, frame_epoch);
                if visible_state_changed
                    && !browser.dirty.swap(true, Ordering::AcqRel)
                    && let Some(mux) = mux.upgrade()
                {
                    mux.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            CdpEvent::ScreencastFrameCaptureRequested {
                session_id,
                frame_id,
                loader_id,
                request_id,
                frame_epoch,
                navigation_epoch,
            } => {
                let reservation_id = request_id;
                if !browser.reserve_screencast_capture(
                    reservation_id,
                    frame_epoch,
                    navigation_epoch,
                ) {
                    if let Some(runtime) = runtime.upgrade() {
                        let _ = runtime.client.cancel_timestampless_screencast_capture(
                            &session_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        );
                    }
                    return LaneFlow::Continue;
                }
                if browser
                    .enqueue_latest_authority(BrowserCommand::AuthorizeScreencastCapture {
                        session_id: session_id.clone(),
                        frame_id,
                        loader_id,
                        reservation_id,
                        frame_epoch,
                        navigation_epoch,
                    })
                    .is_err()
                {
                    browser.cancel_screencast_capture(reservation_id);
                    if let Some(runtime) = runtime.upgrade() {
                        let _ = runtime.client.cancel_timestampless_screencast_capture(
                            &session_id,
                            reservation_id,
                            frame_epoch,
                            navigation_epoch,
                        );
                    }
                }
            }
            CdpEvent::TargetCreated(created) => {
                handle_target_created(browser, &created, &mux, &runtime, &route);
            }
            CdpEvent::TargetInfoChanged(info) => {
                let title = if info.title.is_empty() { info.url.clone() } else { info.title };
                let url_changed =
                    if info.url.is_empty() { false } else { browser.set_url(info.url) };
                let title_changed = browser.set_title(title);
                clear_attention_if_page_changed(seen_url, browser, |url| {
                    let _ = browser
                        .defer_registry_work(&route, RegistryWork::ClearAttention(url.into()));
                });
                if (url_changed || title_changed)
                    && let Some(mux) = mux.upgrade()
                {
                    mux.emit(MuxEvent::TitleChanged { surface: id, title: browser.title().into() });
                }
            }
            CdpEvent::FrameNavigated { params, frame_epoch, .. } => {
                handle_frame_navigated(browser, params, frame_epoch);
                clear_attention_if_page_changed(seen_url, browser, |url| {
                    let _ = browser
                        .defer_registry_work(&route, RegistryWork::ClearAttention(url.into()));
                });
                if let Some(mux) = mux.upgrade() {
                    mux.emit(MuxEvent::TitleChanged { surface: id, title: browser.title().into() });
                    mux.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            CdpEvent::DocumentPainted { session_id, frame_id, loader_id, navigation_epoch }
                if browser.needs_document_paint(navigation_epoch) =>
            {
                let _ = browser.enqueue_latest_authority(BrowserCommand::AuthorizeDocumentPaint {
                    session_id,
                    frame_id,
                    loader_id,
                    navigation_epoch,
                });
            }
            CdpEvent::NavigatedWithinDocument {
                params,
                session_id,
                frame_id,
                loader_id,
                frame_epoch,
            } => {
                let _ = handle_same_document_navigated(browser, &params, frame_epoch);
                clear_attention_if_page_changed(seen_url, browser, |url| {
                    let _ = browser
                        .defer_registry_work(&route, RegistryWork::ClearAttention(url.into()));
                });
                if browser.needs_same_document_paint() {
                    let _ = browser.enqueue_latest_authority(
                        BrowserCommand::AuthorizeSameDocumentPaint {
                            session_id,
                            frame_id,
                            loader_id,
                        },
                    );
                }
                if let Some(mux) = mux.upgrade() {
                    mux.emit(MuxEvent::TitleChanged { surface: id, title: browser.title().into() });
                    mux.emit(MuxEvent::SurfaceOutput(id));
                }
            }
            CdpEvent::Other { method, params, .. } if method == "Page.javascriptDialogOpening" => {
                let (accept, message) = dialog_response(&params);
                let _ = browser.handle_javascript_dialog(accept);
                if let Some(mux) = mux.upgrade() {
                    mux.emit(MuxEvent::Status(message));
                }
            }
            CdpEvent::Closed(reason) => {
                if let Some(runtime) =
                    runtime.upgrade().filter(|runtime| runtime.source() == BrowserSource::Provider)
                {
                    // Route closure is session-scoped. A replacement can
                    // attach to the same browser-level WebSocket before
                    // this old event thread drains its close marker; never
                    // let that stale marker tear down the new session.
                    if browser.prepare_provider_reconnect(&runtime, &route_session_id)
                        && let Some(mux) = mux.upgrade()
                    {
                        mux.emit(MuxEvent::Status(format!(
                            "cmux-browser provider disconnected: {reason}; waiting to reconnect"
                        )));
                        mux.emit(MuxEvent::SurfaceOutput(id));
                        let _ = browser.defer_registry_work(&route, RegistryWork::RestartProvider);
                    }
                } else if !browser.is_dead() {
                    // Retain the durable exit before kill closes admission.
                    let _ = browser.defer_registry_work(&route, RegistryWork::SurfaceExited);
                    browser.kill();
                }
                return LaneFlow::End;
            }
            _ => {}
        }
        LaneFlow::Continue
    }))
}

/// The sending side of a browser surface's command queue. Each send kicks
/// the surface's worker lane (`serial_lanes.rs`), which replaced the
/// `browser-surface-<id>-worker` thread (perf100 tui lane: 353 such threads,
/// each parked for good, in one Chief daemon). Dropping the last sender
/// kicks too, so the lane sees the queue disconnect.
pub(crate) struct BrowserCommandTx {
    /// `None` only inside `drop`.
    tx: Option<SyncSender<SequencedBrowserCommand>>,
    lane: Arc<OnceLock<Lane>>,
    /// One per sender; `Arc::into_inner` names the last one to drop.
    live: Option<Arc<()>>,
}

impl BrowserCommandTx {
    pub(super) fn channel(
        capacity: usize,
    ) -> (Self, (Receiver<SequencedBrowserCommand>, Arc<OnceLock<Lane>>)) {
        let (tx, rx) = sync_channel(capacity);
        let lane = Arc::new(OnceLock::new());
        (Self { tx: Some(tx), lane: lane.clone(), live: Some(Arc::new(())) }, (rx, lane))
    }

    /// Same contract as `SyncSender::try_send`, whose error carries the
    /// command back.
    #[allow(clippy::result_large_err)]
    pub(super) fn try_send(
        &self,
        command: SequencedBrowserCommand,
    ) -> Result<(), TrySendError<SequencedBrowserCommand>> {
        // `tx` is None only inside `drop`.
        let Some(tx) = self.tx.as_ref() else { return Err(TrySendError::Disconnected(command)) };
        let sent = tx.try_send(command);
        // A full queue still wakes the worker, which drains it.
        if !matches!(sent, Err(TrySendError::Disconnected(_)))
            && let Some(lane) = self.lane.get()
        {
            lane.kick();
        }
        sent
    }
}

impl Clone for BrowserCommandTx {
    fn clone(&self) -> Self {
        Self { tx: self.tx.clone(), lane: self.lane.clone(), live: self.live.clone() }
    }
}

impl Drop for BrowserCommandTx {
    fn drop(&mut self) {
        // Disconnect first: the kicked lane must see the queue closed.
        drop(self.tx.take());
        let last = self.live.take().is_some_and(|live| Arc::into_inner(live).is_some());
        if last && let Some(lane) = self.lane.get() {
            lane.kick();
        }
    }
}

/// tab-attention-v1: the tab is on `browser.url()`; `clear` drops a "needs
/// you" mark set on another page (the marked page is gone). `seen_url` only
/// skips the call for a page this thread already asked about.
pub(super) fn clear_attention_if_page_changed(
    seen_url: &mut Option<String>,
    browser: &BrowserSurface,
    clear: impl FnOnce(&str),
) {
    let url = browser.url();
    if url.is_empty() || seen_url.as_deref() == Some(url.as_str()) {
        return;
    }
    clear(&url);
    *seen_url = Some(url);
}

pub(super) fn start_browser_worker(
    surface: Arc<Surface>,
    (rx, lane_slot): (Receiver<SequencedBrowserCommand>, Arc<OnceLock<Lane>>),
    command_order: Arc<Mutex<BrowserCommandOrder>>,
    latest_nav: Arc<Mutex<Option<SequencedBrowserCommand>>>,
    latest_authority: Arc<Mutex<Option<SequencedBrowserCommand>>>,
    mux: Weak<Mux>,
    mut done_tx: Option<Sender<()>>,
) {
    let id = surface.id;
    let mut failures = BrowserWorkerErrorState::default();
    // The lane holds the surface strongly, as the worker thread did; the
    // queue's senders hold the lane, so the surface lives until its queue
    // is closed and drained (`close_command_sender`).
    let next = |surface: &Surface, failures: &BrowserWorkerErrorState| {
        match next_browser_lifecycle_deadline(surface, failures) {
            Some(deadline) => LaneNext::At(deadline),
            None => LaneNext::Idle,
        }
    };
    let lane = Lane::new("browser-surface-worker", move || {
        // Drain until the queue is empty or closed: a close that happened
        // while the lane was already queued kicks nothing new, so only
        // reading on to `Disconnected` sees it.
        loop {
            let first = match rx.try_recv() {
                Ok(first) => first,
                Err(TryRecvError::Empty) => {
                    // A deadline or a sender's drop, not a command.
                    if next_browser_lifecycle_deadline(&surface, &failures)
                        .is_some_and(|deadline| deadline <= Instant::now())
                    {
                        service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
                    }
                    return next(&surface, &failures);
                }
                Err(TryRecvError::Disconnected) => {
                    if let Some(done_tx) = done_tx.take() {
                        let _ = done_tx.send(());
                    }
                    return LaneNext::Close;
                }
            };
            let mut batch = vec![first];
            let mut order = command_order.lock().unwrap();
            while let Ok(next) = rx.try_recv() {
                batch.push(next);
            }
            batch.extend(order.retained_releases.drain(..));
            batch.extend(order.registry_work.drain(..));
            batch.extend(order.registry_exit.take());
            if let Some(command) = take_latest_worker_commands(&latest_nav) {
                batch.push(command);
            }
            if let Some(command) = take_latest_worker_commands(&latest_authority) {
                batch.push(command);
            }
            drop(order);
            batch.sort_unstable_by_key(|queued| queued.sequence);
            service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
            batch.retain(|queued| !matches!(&queued.command, BrowserCommand::WakeLatest));
            coalesce_worker_mouse_moves(&mut batch);
            for queued in batch {
                service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
                run_browser_worker_command(&surface, queued, &mux, id, &mut failures);
            }
        }
    });
    if lane_slot.set(lane.clone()).is_ok() {
        // Commands sent before the lane existed.
        lane.kick();
    }
}

pub(super) fn next_browser_lifecycle_deadline(
    surface: &Surface,
    failures: &BrowserWorkerErrorState,
) -> Option<Instant> {
    [
        next_pointer_lifecycle_deadline(failures),
        surface.as_browser().and_then(BrowserSurface::pending_authority_deadline),
        surface.as_browser().and_then(BrowserSurface::frame_demand_retry_at),
    ]
    .into_iter()
    .flatten()
    .min()
}

pub(super) fn next_pointer_lifecycle_deadline(
    failures: &BrowserWorkerErrorState,
) -> Option<Instant> {
    failures
        .active_pointer_presses
        .values()
        .filter_map(|press| press.release_retry_at.or(press.compatibility_expires_at))
        .min()
}

pub(super) fn service_due_browser_lifecycles(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    release_due_pointer_presses(surface, mux, id, failures);
    if let Some(browser) = surface.as_browser() {
        browser.reconcile_frame_demand();
    }
    if let Some(message) =
        surface.as_browser().and_then(|browser| browser.expire_navigation_authority(Instant::now()))
    {
        emit_browser_failure(mux, id, message);
    }
}

pub(super) fn release_due_pointer_presses(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    loop {
        release_abandoned_pointer_presses(surface, mux, id, failures, Instant::now());
        let now = Instant::now();
        if next_pointer_lifecycle_deadline(failures).is_none_or(|deadline| deadline > now) {
            break;
        }
    }
}

pub(super) fn release_abandoned_pointer_presses(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
    now: Instant,
) {
    let active_clients = mux.upgrade();
    let expired = failures
        .active_pointer_presses
        .iter()
        .filter(|(_, press)| {
            if let Some(retry_at) = press.release_retry_at {
                return retry_at <= now;
            }
            let compatibility_lease_expired =
                press.compatibility_expires_at.is_some_and(|deadline| deadline <= now);
            match press.input_owner {
                BrowserPointerOwner::Local | BrowserPointerOwner::Legacy => {
                    compatibility_lease_expired
                }
                BrowserPointerOwner::Client(client) => {
                    active_clients.as_ref().is_none_or(|mux| !mux.control_clients.contains(client))
                }
            }
        })
        .map(|(button, _)| button)
        .cloned()
        .collect::<Vec<_>>();
    for button in expired {
        let Some(press) = failures.active_pointer_presses.remove(&button) else {
            continue;
        };
        let result =
            surface.as_browser().map_or(Ok(BrowserWorkerSuccess::LocallySettled), |browser| {
                browser.release_abandoned_pointer_press_blocking(&button, press)
            });
        if press.release_retry_at.is_none()
            && result.as_ref().is_err_and(|error| is_cdp_timeout_error(&error.to_string()))
        {
            let mut retry = press;
            // Delivery is ambiguous after a CDP timeout. Preserve ownership
            // for exactly one balancing retry, but yield the worker before a
            // second potentially long CDP call.
            retry.release_retry_at = Some(Instant::now() + POINTER_RELEASE_RETRY_DELAY);
            failures.active_pointer_presses.insert(button, retry);
        }
        record_browser_worker_result(surface, mux, id, true, result, failures);
    }
}

pub(super) fn take_latest_worker_commands(
    latest_nav: &Arc<Mutex<Option<SequencedBrowserCommand>>>,
) -> Option<SequencedBrowserCommand> {
    latest_nav.lock().unwrap().take()
}

pub(super) fn coalesce_worker_mouse_moves(batch: &mut Vec<SequencedBrowserCommand>) {
    let mut index = 0;
    while index + 1 < batch.len() {
        if batch[index].command.mouse_move_owner().is_some()
            && batch[index].command.mouse_move_owner()
                == batch[index + 1].command.mouse_move_owner()
        {
            batch.remove(index);
        } else {
            index += 1;
        }
    }
}

pub(super) fn run_browser_worker_command(
    surface: &Surface,
    queued: SequencedBrowserCommand,
    mux: &Weak<Mux>,
    id: SurfaceId,
    failures: &mut BrowserWorkerErrorState,
) {
    let (mut command, confirmed) = match queued.command {
        BrowserCommand::Confirmed { command, completion } => (*command, Some(completion)),
        command => (command, None),
    };
    let completion =
        if let BrowserCommand::Reconfigure { queued, report, completion } = &mut command {
            if let Some(report) = report.take() {
                report(Some(queued.id));
            }
            completion.take()
        } else {
            None
        };
    let is_input = command.is_input();
    let is_reconfigure = matches!(command, BrowserCommand::Reconfigure { .. });
    let reconfigure = match &command {
        BrowserCommand::Reconfigure { queued, .. } => Some(*queued),
        _ => None,
    };
    let disconnected_pointer_client = match &command {
        BrowserCommand::Mouse { input_owner: BrowserPointerOwner::Client(client), .. }
        | BrowserCommand::Wheel { input_owner: BrowserPointerOwner::Client(client), .. } => {
            mux.upgrade().is_none_or(|mux| !mux.control_clients.contains(*client))
        }
        _ => false,
    };
    if disconnected_pointer_client {
        return;
    }
    let result = {
        let Some(browser) = surface.as_browser() else {
            return;
        };
        match command {
            BrowserCommand::WakeLatest => Ok(BrowserWorkerSuccess::LocallySettled),
            BrowserCommand::EventRegistry(deferred) => {
                run_registry_work(browser, *deferred, mux, id);
                Ok(BrowserWorkerSuccess::LocallySettled)
            }
            BrowserCommand::Mouse {
                input_owner,
                event_type,
                x,
                y,
                button,
                click_count,
                frame_seq,
                pointer_admission,
            } => browser.mouse_event_blocking_with_admission(
                BrowserMouseDispatch {
                    input_owner,
                    event_type: &event_type,
                    x,
                    y,
                    button: button.as_deref(),
                    click_count,
                    frame_seq,
                },
                pointer_admission,
                &mut failures.active_pointer_presses,
            ),
            BrowserCommand::Wheel {
                input_owner,
                x,
                y,
                delta_x,
                delta_y,
                frame_seq,
                pointer_admission,
            } => browser.wheel_blocking(
                BrowserWheelDispatch { input_owner, x, y, delta_x, delta_y, frame_seq },
                pointer_admission,
            ),
            BrowserCommand::Key {
                event_type,
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            } => browser
                .key_event_blocking(
                    &event_type,
                    &key,
                    &code,
                    windows_virtual_key_code,
                    modifiers,
                    text.as_deref(),
                )
                .map(|_| BrowserWorkerSuccess::BrowserResponded),
            BrowserCommand::KeyPress { key, code, windows_virtual_key_code, modifiers, text } => {
                browser
                    .key_press_blocking(
                        &key,
                        &code,
                        windows_virtual_key_code,
                        modifiers,
                        text.as_deref(),
                    )
                    .map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::InsertText(text) => {
                browser.insert_text_blocking(&text).map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Navigate(url) => {
                browser.run_navigation(queued.sequence, &url, confirmed.is_some())
            }
            BrowserCommand::Back => {
                browser.back_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Forward => {
                browser.forward_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Reload => {
                browser.reload_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Activate => {
                browser.activate_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::AuthorizeDocumentPaint {
                session_id,
                frame_id,
                loader_id,
                navigation_epoch,
            } => browser.authorize_document_paint_blocking(
                &session_id,
                &frame_id,
                &loader_id,
                navigation_epoch,
            ),
            BrowserCommand::AuthorizeSameDocumentPaint { session_id, frame_id, loader_id } => {
                browser.authorize_same_document_paint_blocking(&session_id, &frame_id, &loader_id)
            }
            BrowserCommand::AuthorizeScreencastCapture {
                session_id,
                frame_id,
                loader_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            } => browser.authorize_screencast_capture_blocking(
                &session_id,
                &frame_id,
                &loader_id,
                reservation_id,
                frame_epoch,
                navigation_epoch,
            ),
            BrowserCommand::Close => {
                browser.close_blocking().map(|_| BrowserWorkerSuccess::BrowserResponded)
            }
            BrowserCommand::Confirmed { .. } => {
                unreachable!("confirmed wrappers are removed before execution")
            }
            BrowserCommand::Reconfigure { queued, .. } => {
                browser.reconfigure_reserved_blocking(queued)
            }
            #[cfg(test)]
            BrowserCommand::Hold { entered, release } => {
                let _ = entered.send(());
                release
                    .recv()
                    .map(|_| BrowserWorkerSuccess::LocallySettled)
                    .map_err(anyhow::Error::msg)
            }
        }
    };
    if let Some(completion) = confirmed {
        let outcome = result.as_ref().map(|_| ()).map_err(|error| Arc::from(error.to_string()));
        let _ = completion.send(outcome);
    }
    if is_reconfigure
        && result.is_ok()
        && let Some(mux) = mux.upgrade()
        && let Some(queued) = reconfigure
    {
        let (cols, rows) = queued.geometry.size;
        mux.emit(MuxEvent::SurfaceResized {
            surface: id,
            cols,
            rows,
            reservation_id: Some(queued.id),
        });
    }
    if let Some(queued) = reconfigure
        && let Err(error) = &result
        && let Some(browser) = surface.as_browser()
        && let Some((_, retry_delay)) = browser.fail_reconfigure(queued)
        && let Some(mux) = mux.upgrade()
    {
        let (cols, rows) = queued.geometry.size;
        mux.emit(MuxEvent::SurfaceResizeFailed {
            surface: id,
            cols,
            rows,
            error: Arc::<str>::from(error.to_string()),
            retry_after_ms: retry_delay.map(|delay| delay.as_millis() as u64),
            reservation_id: Some(queued.id),
        });
    }
    if let Some(completion) = completion {
        let outcome = result.as_ref().map(|_| ()).map_err(|error| Arc::from(error.to_string()));
        let _ = completion.send(outcome);
    }
    if let Some(queued) = reconfigure
        && let Some(browser) = surface.as_browser()
    {
        let outcome = result.as_ref().map(|_| ()).map_err(|error| Arc::from(error.to_string()));
        browser.complete_reconfigure_waiters(queued.id, outcome);
    }
    record_browser_worker_result(surface, mux, id, is_input, result, failures);
}

pub(super) fn record_browser_worker_result(
    surface: &Surface,
    mux: &Weak<Mux>,
    id: SurfaceId,
    is_input: bool,
    result: BrowserWorkerResult,
    failures: &mut BrowserWorkerErrorState,
) {
    match result {
        Ok(success) => {
            // Superseded and stale work is intentionally successful at the
            // queue boundary, but it carries no evidence that CDP recovered.
            if success == BrowserWorkerSuccess::BrowserResponded {
                failures.consecutive_timeouts = 0;
            }
            if !is_input {
                emit_browser_dirty(mux, id);
            }
        }
        Err(err) => {
            let message = err.to_string();
            let timeout = is_cdp_timeout_error(&message);
            if timeout {
                failures.consecutive_timeouts = failures.consecutive_timeouts.saturating_add(1);
                if failures.consecutive_timeouts >= 2 {
                    let should_report = surface
                        .as_browser()
                        .is_some_and(BrowserSurface::claim_not_responding_report);
                    if should_report {
                        if let Some(browser) = surface.as_browser() {
                            browser.mark_not_responding();
                        }
                        emit_browser_failure(mux, id, BROWSER_NOT_RESPONDING_MESSAGE.to_string());
                    }
                }
            } else {
                failures.consecutive_timeouts = 0;
            }
            if !(is_input || timeout && failures.consecutive_timeouts >= 2) {
                emit_browser_status(mux, message);
                emit_browser_dirty(mux, id);
            }
        }
    }
}

pub(super) fn is_cdp_timeout_error(message: &str) -> bool {
    message.contains("CDP call ") && message.contains(" timed out")
}

pub(super) fn emit_browser_status(mux: &Weak<Mux>, message: String) {
    if let Some(mux) = mux.upgrade() {
        mux.emit(MuxEvent::Status(message));
    }
}

pub(super) fn emit_browser_dirty(mux: &Weak<Mux>, id: SurfaceId) {
    if let Some(mux) = mux.upgrade() {
        let title = mux.surface(id).map(|surface| surface.title()).unwrap_or_default();
        mux.emit(MuxEvent::TitleChanged { surface: id, title: title.into() });
        mux.emit(MuxEvent::SurfaceOutput(id));
    }
}

pub(super) fn emit_browser_failure(mux: &Weak<Mux>, id: SurfaceId, message: String) {
    if let Some(mux) = mux.upgrade() {
        mux.emit(MuxEvent::Status(message));
        let title = mux.surface(id).map(|surface| surface.title()).unwrap_or_default();
        mux.emit(MuxEvent::TitleChanged { surface: id, title: title.into() });
        mux.emit(MuxEvent::SurfaceOutput(id));
    }
}

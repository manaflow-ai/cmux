//! Per-surface threads: the surface event thread, the command worker loop,
//! pointer and lifecycle deadlines, and status/dirty/failure notifications.

use super::*;
use crate::lock_rank::rank;

pub(super) fn start_surface_thread(
    surface: Arc<Surface>,
    events: Arc<SurfaceRoute>,
    mux: Weak<Mux>,
    runtime: Weak<BrowserRuntime>,
    route_session_id: String,
) -> anyhow::Result<()> {
    let id = surface.id;
    std::thread::Builder::new().name(format!("browser-surface-{id}-events")).spawn(move || {
        while let Some(event) = events.recv() {
            let Surface::Browser(browser) = surface.as_ref() else { break };
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
                        continue;
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
                    handle_target_created(browser, &created, &mux, &runtime, id);
                }
                CdpEvent::TargetInfoChanged(info) => {
                    let title = if info.title.is_empty() { info.url.clone() } else { info.title };
                    let url_changed =
                        if info.url.is_empty() { false } else { browser.set_url(info.url) };
                    let title_changed = browser.set_title(title);
                    if (url_changed || title_changed)
                        && let Some(mux) = mux.upgrade()
                    {
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: browser.title().into(),
                        });
                    }
                }
                CdpEvent::FrameNavigated { params, frame_epoch, .. } => {
                    handle_frame_navigated(browser, params, frame_epoch);
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: browser.title().into(),
                        });
                        mux.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
                CdpEvent::DocumentPainted { session_id, frame_id, loader_id, navigation_epoch }
                    if browser.needs_document_paint(navigation_epoch) =>
                {
                    let _ =
                        browser.enqueue_latest_authority(BrowserCommand::AuthorizeDocumentPaint {
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
                        mux.emit(MuxEvent::TitleChanged {
                            surface: id,
                            title: browser.title().into(),
                        });
                        mux.emit(MuxEvent::SurfaceOutput(id));
                    }
                }
                CdpEvent::Other { method, params, .. }
                    if method == "Page.javascriptDialogOpening" =>
                {
                    let (accept, message) = dialog_response(&params);
                    let _ = browser.handle_javascript_dialog(accept);
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::Status(message));
                    }
                }
                CdpEvent::Closed(reason) => {
                    if let Some(runtime) = runtime
                        .upgrade()
                        .filter(|runtime| runtime.source() == BrowserSource::Provider)
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
                            mux.restart_provider_browser_surface(surface.clone());
                        }
                    } else if !browser.is_dead() {
                        browser.kill();
                        if let Some(mux) = mux.upgrade() {
                            mux.surface_exited(id);
                        }
                    }
                    break;
                }
                _ => {}
            }
        }
    })?;
    Ok(())
}

pub(super) fn start_browser_worker(
    surface: Arc<Surface>,
    rx: Receiver<SequencedBrowserCommand>,
    command_order: Arc<RankedMutex<BrowserCommandOrder, { rank::BROWSER_COMMAND_ORDER }>>,
    latest_nav: Arc<RankedMutex<Option<SequencedBrowserCommand>, { rank::LEAF }>>,
    latest_authority: Arc<RankedMutex<Option<SequencedBrowserCommand>, { rank::LEAF }>>,
    mux: Weak<Mux>,
    done_tx: Option<Sender<()>>,
) {
    let id = surface.id;
    let _ =
        std::thread::Builder::new().name(format!("browser-surface-{id}-worker")).spawn(move || {
            let mut failures = BrowserWorkerErrorState::default();
            loop {
                let first = match next_browser_lifecycle_deadline(&surface, &failures) {
                    Some(deadline) => {
                        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                            Ok(first) => first,
                            Err(RecvTimeoutError::Timeout) => {
                                service_due_browser_lifecycles(&surface, &mux, id, &mut failures);
                                continue;
                            }
                            Err(RecvTimeoutError::Disconnected) => break,
                        }
                    }
                    None => match rx.recv() {
                        Ok(first) => first,
                        Err(_) => break,
                    },
                };
                let mut batch = vec![first];
                let mut order = command_order.lock().unwrap();
                while let Ok(next) = rx.try_recv() {
                    batch.push(next);
                }
                batch.extend(order.retained_releases.drain(..));
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
            if let Some(done_tx) = done_tx {
                let _ = done_tx.send(());
            }
        });
}

pub(super) fn next_browser_lifecycle_deadline(
    surface: &Surface,
    failures: &BrowserWorkerErrorState,
) -> Option<Instant> {
    [
        next_pointer_lifecycle_deadline(failures),
        surface.as_browser().and_then(BrowserSurface::pending_authority_deadline),
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

pub(super) fn take_latest_worker_commands<const R: u16>(
    latest_nav: &Arc<RankedMutex<Option<SequencedBrowserCommand>, R>>,
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

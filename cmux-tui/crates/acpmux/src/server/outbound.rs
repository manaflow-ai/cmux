//! A connection's outbound queue: replies and requests to the client are never dropped, a
//! notification is when its reader falls behind, and a gap marker tells the reader to read again
//! (moved out of `server/mod.rs`, which is over its size budget).

use super::*;

/// Keep two queue slots available for replies and one for the gap marker that
/// tells a reader to replay from its last cursor.
pub(super) const OUTBOUND_CONTROL_RESERVE: usize = 3;

pub(super) fn enqueue_outbound(
    out: &mpsc::Sender<String>,
    line: String,
    control: bool,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
    pending_controls: &Arc<AtomicUsize>,
) {
    let _guard = outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
    enqueue_outbound_locked(
        out,
        line,
        control,
        dropped,
        gap_pending,
        outbound_lock,
        pending_controls,
    );
}

/// [`enqueue_outbound`] of a control line that must go out after every control queued before
/// it: queued only if none of those still waits for room in a full queue (each such waits in a
/// task of its own, which a line queued now would pass). False, with nothing queued, if one does
/// or the queue's reader is gone.
pub(super) fn enqueue_after_controls(
    out: &mpsc::Sender<String>,
    line: String,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
    pending_controls: &Arc<AtomicUsize>,
) -> bool {
    let _guard = outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
    if out.is_closed() || pending_controls.load(Ordering::Acquire) != 0 {
        return false;
    }
    enqueue_outbound_locked(out, line, true, dropped, gap_pending, outbound_lock, pending_controls);
    true
}

/// [`enqueue_outbound`] with `outbound_lock` held.
pub(super) fn enqueue_outbound_locked(
    out: &mpsc::Sender<String>,
    line: String,
    control: bool,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
    pending_controls: &Arc<AtomicUsize>,
) {
    // Notifications are lossy by design when the reader is too slow, but the
    // The final three permits are reserved for two response/control messages
    // and the recovery marker.
    let reserved = OUTBOUND_CONTROL_RESERVE + pending_controls.load(Ordering::Acquire);
    if !control && out.capacity() <= reserved {
        report_outbound_loss_locked(out, dropped, gap_pending, outbound_lock);
        return;
    }
    match out.try_send(line) {
        Ok(()) => {
            // Let a later queue-pressure episode produce a fresh marker once
            // the previous marker and backlog have drained.
            if gap_pending.load(Ordering::Acquire)
                && pending_controls.load(Ordering::Acquire) == 0
                && out.capacity() > OUTBOUND_CONTROL_RESERVE + 1
            {
                gap_pending.store(false, Ordering::Release);
            }
        }
        Err(mpsc::error::TrySendError::Full(line)) if control => {
            let out = out.clone();
            pending_controls.fetch_add(1, Ordering::AcqRel);
            let pending_controls = Arc::clone(pending_controls);
            tokio::spawn(async move {
                let _ = out.send(line).await;
                pending_controls.fetch_sub(1, Ordering::AcqRel);
            });
        }
        Err(mpsc::error::TrySendError::Full(_)) => {
            report_outbound_loss_locked(out, dropped, gap_pending, outbound_lock)
        }
        Err(mpsc::error::TrySendError::Closed(_)) => {}
    }
}

pub(super) fn report_outbound_loss_locked(
    out: &mpsc::Sender<String>,
    dropped: &Arc<AtomicU64>,
    gap_pending: &Arc<AtomicBool>,
    outbound_lock: &Arc<StdMutex<()>>,
) {
    let total = dropped.fetch_add(1, Ordering::Relaxed) + 1;
    if gap_pending.swap(true, Ordering::AcqRel) {
        return;
    }
    let marker = Message::notification(
        "_acpmux/lagged",
        json!({"dropped": total, "reason": "output_queue_full"}),
    )
    .to_line();
    if out.try_send(marker).is_err() {
        // Keep the marker pending even when the queue is currently full. The
        // waiter owns the next available slot, so a quiet connection still
        // receives the replay signal after its reader catches up.
        let out = out.clone();
        let dropped = Arc::clone(dropped);
        let gap_pending = Arc::clone(gap_pending);
        let outbound_lock = Arc::clone(outbound_lock);
        tokio::spawn(async move {
            let permit = out.reserve().await;
            let Ok(permit) = permit else {
                gap_pending.store(false, Ordering::Release);
                return;
            };
            let _guard = outbound_lock.lock().unwrap_or_else(|e| e.into_inner());
            let total = dropped.load(Ordering::Relaxed);
            permit.send(
                Message::notification(
                    "_acpmux/lagged",
                    json!({"dropped": total, "reason": "output_queue_full"}),
                )
                .to_line(),
            );
            gap_pending.store(false, Ordering::Release);
        });
    }
}

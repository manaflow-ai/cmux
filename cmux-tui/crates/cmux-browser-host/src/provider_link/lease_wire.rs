//! Automation lease frames on the provider link.

use super::*;

pub(super) type Leases = Arc<Mutex<crate::lease::LeaseTable>>;

pub(super) fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// Applies a lease operation and sends a `lease` frame for every target
/// whose rendered lease changed.
pub(super) fn apply_lease(
    leases: &Leases,
    writer: &SharedWriter,
    op: &crate::lease::LeaseOp,
    caller: &crate::lease::LeaseCaller,
) -> Result<(), crate::lease::LeaseError> {
    // The table stays locked until the frames are written, so two changes
    // reach the app in the order the table applied them.
    let mut table = leases.lock().unwrap_or_else(PoisonError::into_inner);
    let frames = table.apply(op, caller, now_ms())?;
    let mut writer = writer.lock().unwrap_or_else(PoisonError::into_inner);
    for frame in frames {
        let _ = write_frame(
            &mut *writer,
            &Frame::Lease { target_id: frame.target, lease: frame.lease },
        );
    }
    Ok(())
}

/// A person's lease action from the app (`lease.user`), origin `user`.
pub(super) fn user_lease_op(
    op: &str,
    target_id: Option<String>,
    actor: Option<String>,
) -> Option<crate::lease::LeaseOp> {
    use crate::lease::LeaseOp;
    Some(match (op, target_id, actor) {
        ("take_over", Some(target), _) => LeaseOp::TakeOver { target },
        ("hand_back", Some(target), _) => LeaseOp::HandBack { target },
        ("stop", Some(target), _) => LeaseOp::Stop { target },
        ("allow", _, Some(actor)) => LeaseOp::Allow { actor },
        _ => return None,
    })
}

//! The screen session's reconnect policy and what its connecting card says.

/// How long a run of reconnects keeps trying before it gives up (seconds).
pub const RECONNECT_DEADLINE: f64 = 45.0;
/// A reconnect without a picture says so only after this long (seconds).
pub const RECONNECT_NOTICE_DELAY: f64 = 10.0;
/// A first connect says so only after this long (seconds).
pub const CONNECT_NOTICE_DELAY: f64 = RECONNECT_NOTICE_DELAY;

/// Whether reconnecting stops: after `limit` tries, or once it has tried
/// for [`RECONNECT_DEADLINE`] seconds.
pub fn gives_up(attempts: i64, limit: i64, elapsed: f64) -> bool {
    attempts >= limit || elapsed > RECONNECT_DEADLINE
}

/// One attempt's open timeout: what is left of the deadline, 1 to 30 seconds.
pub fn attempt_timeout(elapsed: f64) -> f64 {
    (RECONNECT_DEADLINE - elapsed).clamp(1.0, 30.0)
}

/// The wait before reconnect attempt `attempt` (1-based): none for the
/// first, then 1, 2, 4, 8, 8... seconds.
pub fn backoff_delay(attempt: i64) -> f64 {
    if attempt <= 1 {
        return 0.0;
    }
    2f64.powi((attempt - 2).min(16) as i32).min(8.0)
}

/// The session's phase, as far as its card cares.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPhase {
    Idle = 0,
    Connecting = 1,
    Connected = 2,
    Failed = 3,
    Ended = 4,
}

/// Whether the connecting card says anything yet: a reconnect only past
/// [`RECONNECT_NOTICE_DELAY`], a first connect only past
/// [`CONNECT_NOTICE_DELAY`]. A failure is its own phase and never held.
pub fn connecting_notice_shown(
    phase: SessionPhase,
    reconnecting: bool,
    reconnect_notice_due: bool,
    connect_notice_due: bool,
) -> bool {
    phase == SessionPhase::Connecting
        && if reconnecting { reconnect_notice_due } else { connect_notice_due }
}

/// Connected, or reconnecting: the toolbar, shortcuts and trackpad keep
/// their places so the screen does not jump while it comes back.
pub fn keeps_live_layout(phase: SessionPhase, reconnecting: bool) -> bool {
    phase == SessionPhase::Connected || reconnecting
}

/// A VNC rectangle encoding's name for the stats overlay.
pub fn encoding_name(raw: i32) -> String {
    match raw {
        0 => "Raw".to_owned(),
        1 => "CopyRect".to_owned(),
        2 => "RRE".to_owned(),
        5 => "Hextile".to_owned(),
        6 => "Zlib".to_owned(),
        16 => "ZRLE".to_owned(),
        _ => format!("#{raw}"),
    }
}

#[cfg(test)]
#[path = "reconnect_tests.rs"]
mod tests;

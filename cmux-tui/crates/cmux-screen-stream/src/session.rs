//! The screen session's pure rules: how long a dropped stream keeps reconnecting, and the names
//! of the RFB encodings it reports.

/// How long a dropped stream keeps trying to reconnect, in seconds.
pub const RECONNECT_DEADLINE: f64 = 45.0;

/// One reconnect attempt's timeout after `elapsed` seconds of trying: what is left of the
/// deadline, within 1...30 s.
pub fn attempt_timeout(elapsed: f64) -> f64 {
    (RECONNECT_DEADLINE - elapsed).clamp(1.0, 30.0)
}

/// Whether reconnecting stops: after `limit` tries, or once it has tried for the deadline.
pub fn gives_up(attempts: i64, limit: i64, elapsed: f64) -> bool {
    attempts >= limit || elapsed > RECONNECT_DEADLINE
}

/// An RFB encoding's name; an unknown one as `#<number>`.
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
mod tests {
    use super::*;

    #[test]
    fn attempts_shrink_to_the_deadline() {
        assert_eq!(attempt_timeout(0.0), 30.0);
        assert_eq!(attempt_timeout(20.0), 25.0);
        assert_eq!(attempt_timeout(44.5), 1.0);
        assert_eq!(attempt_timeout(100.0), 1.0);
        assert!(gives_up(3, 3, 0.0));
        assert!(!gives_up(2, 3, 45.0));
        assert!(gives_up(0, 3, 45.1));
    }

    #[test]
    fn encodings_have_names() {
        assert_eq!(encoding_name(16), "ZRLE");
        assert_eq!(encoding_name(-239), "#-239");
    }
}

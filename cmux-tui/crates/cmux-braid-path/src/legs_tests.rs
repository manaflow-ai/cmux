use super::*;

#[test]
fn failures_are_named_by_kind_or_text() {
    assert_eq!(Outcome::of(&io::Error::from(io::ErrorKind::TimedOut)), Outcome::Timeout);
    assert_eq!(Outcome::of(&io::Error::from(io::ErrorKind::ConnectionRefused)), Outcome::Refused);
    assert_eq!(Outcome::of(&io::Error::from(io::ErrorKind::HostUnreachable)), Outcome::Unreachable);
    assert_eq!(Outcome::of(&io::Error::other("invalid peer certificate")), Outcome::Tls);
    assert_eq!(Outcome::of_text("quic: no answer within 3000 ms"), Outcome::Timeout);
    assert_eq!(Outcome::of_text("something odd"), Outcome::Other);
}

#[test]
fn counts_render_one_line_per_leg() {
    let mut snapshot = Snapshot::new();
    snapshot.insert(("d".into(), "v4".into(), Outcome::Won), 3);
    snapshot.insert(("d".into(), "v6".into(), Outcome::Timeout), 2);
    snapshot.insert(("d".into(), "v6".into(), Outcome::Outrun), 1);
    assert_eq!(render(&snapshot), "d v4 won=3\nd v6 outrun=1 timeout=2");
}

use super::*;

fn authority() -> TicketAuthority {
    TicketAuthority::hmac(vec![7; 32]).unwrap()
}

#[test]
fn a_minted_ticket_verifies_to_its_session() {
    let t = authority().issue("sess-1", unix_now().unwrap() + 60).unwrap();
    assert_eq!(authority().verify(t.as_bytes()).unwrap(), b"sess-1");
}

#[test]
fn tampered_expired_and_foreign_tickets_fail() {
    let a = authority();
    let now = unix_now().unwrap();
    let t = a.issue("sess-1", now + 60).unwrap();
    let forged = t.replacen("sess-1", "sess-2", 1);
    assert_eq!(a.verify(forged.as_bytes()), Err(TicketError::BadSignature));
    let old = a.issue("sess-1", now - 1).unwrap();
    assert_eq!(a.verify(old.as_bytes()), Err(TicketError::Expired));
    let other = TicketAuthority::hmac(vec![8; 32]).unwrap();
    assert_eq!(other.verify(t.as_bytes()), Err(TicketError::BadSignature));
    assert_eq!(a.verify(b""), Err(TicketError::Malformed));
    assert_eq!(a.verify(b"hop1.x"), Err(TicketError::Malformed));
    assert!(TicketAuthority::hmac(vec![1; 8]).is_err());
}

#[test]
fn open_mode_takes_any_ticket_as_its_session() {
    assert_eq!(TicketAuthority::open().verify(b"lab").unwrap(), b"lab");
    assert!(TicketAuthority::open().verify(&[0; 600]).is_err());
}

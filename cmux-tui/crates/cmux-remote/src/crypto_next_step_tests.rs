use super::*;

#[test]
fn a_refused_device_is_told_what_to_do_next() {
    for message in [
        "device has been revoked",
        "invitation is expired",
        "invitation was already claimed by another device",
    ] {
        let text = CryptoError::Unauthorized(message.into()).to_string();
        assert!(text.starts_with(&format!("authorization failed: {message}; ")), "{text}");
        assert!(text.contains("cmux remote enroll create"), "{text}");
        assert!(text.contains("cmux remote connect --invite-file"), "{text}");
    }
    let other = CryptoError::Unauthorized("no such invitation".into()).to_string();
    assert_eq!(other, "authorization failed: no such invitation");
}

/// A pipelined link whose daemon ends it after the Noise handshake, before
/// its welcome (a register refusal, which sends no word): the first receive
/// names that step (`no_welcome`) instead of a plain end.
#[tokio::test]
async fn a_link_ended_before_its_welcome_names_the_step() {
    let params: NoiseParams = "Noise_NN_25519_ChaChaPoly_SHA256".parse().unwrap();
    let mut initiator = snow::Builder::new(params.clone()).build_initiator().unwrap();
    let mut responder = snow::Builder::new(params).build_responder().unwrap();
    let (mut first, mut second, mut scratch) = ([0_u8; 128], [0_u8; 128], [0_u8; 128]);
    let size = initiator.write_message(&[], &mut first).unwrap();
    responder.read_message(&first[..size], &mut scratch).unwrap();
    let size = responder.write_message(&[], &mut second).unwrap();
    initiator.read_message(&second[..size], &mut scratch).unwrap();
    let transport = initiator.into_stateless_transport_mode().unwrap();

    let (ours, theirs) = tokio::io::duplex(4096);
    drop(theirs);
    let (reader, writer) = tokio::io::split(ours);
    let inner = crate::provider::LengthDelimitedLink::new("memory://test", 4096, reader, writer);
    let secure = secure_link(Box::new(inner), transport, [0; 32], Pattern::Xx).unwrap();
    secure.welcome_pending.store(true, Ordering::Release);

    match secure.receive().await {
        Err(LinkError::Transport(detail)) => {
            assert_eq!(detail, "the daemon closed the link before its welcome");
        }
        other => panic!("{other:?}"),
    }
}

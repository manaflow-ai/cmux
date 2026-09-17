use cmux_v3_ffi::{LaneDescriptor, NativeEndpoint, NativeError, Operation};
use cmux_v3_grants::{Grant, GrantSigner, LeasePolicy, Scope};
use ed25519_dalek::SigningKey;
use std::{
    collections::HashMap,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

#[tokio::test]
async fn native_owner_supports_full_duplex_cancellation_and_revocation() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let signer = SigningKey::from_bytes(&[71; 32]);
        let keys = HashMap::from([("test".into(), signer.verifying_key().to_bytes().to_vec())]);
        let a = NativeEndpoint::create(vec![72; 32], "a".into(), keys.clone())
            .await
            .unwrap();
        let b = NativeEndpoint::create(vec![73; 32], "a".into(), keys)
            .await
            .unwrap();
        let addr = b
            .listen("/ip4/127.0.0.1/udp/0/quic-v1".into(), Operation::new())
            .await
            .unwrap();
        assert!(b.addresses(Operation::new()).await.unwrap().contains(&addr));
        let grant = Grant::new(
            Scope {
                team: "a",
                source: a.peer_id().parse().unwrap(),
                destination: b.peer_id().parse().unwrap(),
                action: "connect",
            },
            1,
            LeasePolicy::default(),
            now(),
            now(),
        )
        .unwrap();
        let token = GrantSigner::new("test".into(), &signer)
            .unwrap()
            .sign(&grant, now())
            .unwrap();
        let descriptor = LaneDescriptor {
            kind: 0,
            resource: None,
            cursor: None,
        };
        let (sending, accepted) = tokio::join!(
            a.open(
                b.peer_id(),
                format!("{addr}/p2p/{}", b.peer_id()),
                token.clone(),
                None,
                descriptor,
                Operation::new()
            ),
            b.accept(Operation::new())
        );
        let sending = sending.unwrap();
        let accepted = accepted.unwrap();
        assert_eq!(accepted.peer_id, a.peer_id());
        let receiving = accepted.stream;
        let read_op = Operation::new();
        // Keep a read pending while a concurrent write goes through the same native handle.
        let read = sending.receive(read_op.clone());
        let write = async {
            sending
                .send(b"request".to_vec(), Operation::new())
                .await
                .unwrap();
            assert_eq!(
                receiving.receive(Operation::new()).await.unwrap(),
                b"request"
            );
            receiving
                .send(b"reply".to_vec(), Operation::new())
                .await
                .unwrap();
        };
        let (result, ()) = tokio::join!(read, write);
        assert_eq!(result.unwrap(), b"reply");
        let cancel = Operation::new();
        let read = receiving.receive(cancel.clone());
        cancel.cancel();
        assert_eq!(read.await, Err(NativeError::Cancelled));
        sending.renew(token, Operation::new()).await.unwrap();
        sending
            .send(b"after cancel".to_vec(), Operation::new())
            .await
            .unwrap();
        assert_eq!(
            receiving.receive(Operation::new()).await.unwrap(),
            b"after cancel"
        );
        let left = vec![1; 128 * 1024];
        let right = vec![2; 128 * 1024];
        let writes = async { tokio::try_join!(sending.send(left.clone(), Operation::new()), sending.send(right.clone(), Operation::new())).unwrap(); };
        let reads = async {
            let mut bytes = Vec::new();
            while bytes.len() < left.len() + right.len() { bytes.extend(receiving.receive(Operation::new()).await.unwrap()); }
            assert!(bytes == [left.as_slice(), right.as_slice()].concat() || bytes == [right.as_slice(), left.as_slice()].concat());
        };
        tokio::join!(writes, reads);
        b.update_revocations(2, vec![]).unwrap();
        assert_eq!(
            receiving.receive(Operation::new()).await,
            Err(NativeError::Revoked)
        );
        b.close();
        assert_eq!(
            receiving.receive(Operation::new()).await,
            Err(NativeError::Closed)
        );
        a.close();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn closed_endpoint_and_cancelled_accept_do_not_hang() {
    let signer = SigningKey::from_bytes(&[74; 32]);
    let endpoint = NativeEndpoint::create(
        vec![75; 32],
        "a".into(),
        HashMap::from([("test".into(), signer.verifying_key().to_bytes().to_vec())]),
    )
    .await
    .unwrap();
    let op = Operation::new();
    op.cancel();
    assert!(matches!(
        endpoint.accept(op).await,
        Err(NativeError::Cancelled)
    ));
    let waiting = endpoint.accept(Operation::new());
    endpoint.close();
    assert!(matches!(waiting.await, Err(NativeError::Closed)));
    assert!(matches!(
        endpoint.addresses(Operation::new()).await,
        Err(NativeError::Closed)
    ));
}

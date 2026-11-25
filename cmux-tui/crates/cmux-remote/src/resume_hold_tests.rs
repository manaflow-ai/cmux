use super::*;
use std::sync::Mutex as StdMutex;
use tokio::io::DuplexStream;
use tokio::task::JoinHandle;

const BOUND: Duration = Duration::from_secs(20);

fn pattern(seed: u64, len: usize) -> Vec<u8> {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
    (0..len)
        .map(|_| {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (x >> 33) as u8
        })
        .collect()
}

/// An application on one end: writes `send`, ends its writes, returns what it read.
fn app(mut io: DuplexStream, send: Vec<u8>) -> JoinHandle<Vec<u8>> {
    tokio::spawn(async move {
        let (mut read, mut write) = tokio::io::split(&mut io);
        let writing = async {
            for piece in send.chunks(5_003) {
                write.write_all(piece).await.unwrap();
            }
            write.shutdown().await.unwrap();
        };
        let reading = async {
            let mut got = Vec::new();
            read.read_to_end(&mut got).await.unwrap();
            got
        };
        tokio::join!(writing, reading).1
    })
}

/// The carrier between the client and the far machine: each `connect` makes one transport
/// (its copy task can be cut) and serves the far end of it from `parking`.
struct Carrier {
    parking: Arc<Parking<DuplexStream>>,
    /// The far side's local io, taken by the one connect that opens the pipe.
    far_local: StdMutex<Option<DuplexStream>>,
    copies: StdMutex<Vec<JoinHandle<()>>>,
    owner: &'static str,
}

impl Carrier {
    fn connect(self: &Arc<Self>) -> impl Future<Output = Result<DuplexStream, String>> + use<> {
        let carrier = self.clone();
        async move {
            let (near, mut near_far) = tokio::io::duplex(32 * 1024);
            let (far, mut far_near) = tokio::io::duplex(32 * 1024);
            let copy = tokio::spawn(async move {
                let _ = tokio::io::copy_bidirectional(&mut near_far, &mut far_near).await;
            });
            carrier.copies.lock().unwrap().push(copy);
            let parking = carrier.parking.clone();
            let (local, owner) = (carrier.clone(), carrier.owner);
            tokio::spawn(async move {
                let open = || async move {
                    local.far_local.lock().unwrap().take().ok_or("the far side was opened twice")
                };
                parking.serve(far, owner, open).await;
            });
            Ok(near)
        }
    }

    fn cut(&self) {
        if let Some(copy) = self.copies.lock().unwrap().last() {
            copy.abort();
        }
    }
}

fn carrier(grace: Duration, far_local: DuplexStream, owner: &'static str) -> Arc<Carrier> {
    Arc::new(Carrier {
        parking: Parking::new(grace),
        far_local: StdMutex::new(Some(far_local)),
        copies: StdMutex::new(Vec::new()),
        owner,
    })
}

#[tokio::test]
async fn a_held_pipe_comes_through_cuts_whole() {
    let (near_app, near_local) = tokio::io::duplex(8 * 1024);
    let (far_app, far_local) = tokio::io::duplex(8 * 1024);
    let to_far = pattern(5, 6 << 20);
    let to_near = pattern(6, 1 << 20);
    let (near_got, far_got) = (app(near_app, to_far.clone()), app(far_app, to_near.clone()));
    let carrier = carrier(RESUME_GRACE, far_local, "peer");
    let cutter = {
        let carrier = carrier.clone();
        tokio::spawn(async move {
            for i in 0..5u64 {
                tokio::time::sleep(Duration::from_millis(5 + 9 * i)).await;
                carrier.cut();
            }
        })
    };
    let held = tokio::time::timeout(BOUND, hold(near_local, || carrier.connect(), RESUME_GRACE))
        .await
        .expect("the held pipe did not end");
    assert_eq!(held, Held::Finished);
    cutter.await.unwrap();
    assert_eq!(near_got.await.unwrap(), to_near);
    assert_eq!(far_got.await.unwrap(), to_far);
    assert!(carrier.copies.lock().unwrap().len() > 1, "no cut landed inside the transfer");
    // The far side lets go of a finished pipe.
    tokio::time::timeout(BOUND, async {
        while !carrier.parking.is_empty() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the far side kept a finished pipe");
}

#[tokio::test]
async fn a_pipe_past_its_grace_is_gone_and_the_hold_says_so() {
    let (_near_app, near_local) = tokio::io::duplex(1024);
    let (_far_app, far_local) = tokio::io::duplex(1024);
    let grace = Duration::from_millis(100);
    let carrier = carrier(grace, far_local, "peer");
    let mut connects = 0;
    let held = tokio::time::timeout(
        BOUND,
        hold(
            near_local,
            || {
                connects += 1;
                let carrier = carrier.clone();
                let first = connects == 1;
                async move {
                    if first {
                        let transport = carrier.connect().await;
                        let cutting = carrier.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(Duration::from_millis(30)).await;
                            cutting.cut();
                        });
                        transport
                    } else {
                        // The far side's pipe expires before any transport comes back.
                        tokio::time::sleep(Duration::from_millis(250)).await;
                        carrier.connect().await
                    }
                }
            },
            Duration::from_secs(5),
        ),
    )
    .await
    .expect("the hold did not end");
    assert_eq!(held, Held::Failed("the far end no longer holds this pipe".into()));
    assert!(carrier.parking.is_empty());
}

#[tokio::test]
async fn only_the_peer_that_opened_a_pipe_resumes_it() {
    let (_app, far_local) = tokio::io::duplex(1024);
    let parking: Arc<Parking<DuplexStream>> = Parking::new(RESUME_GRACE);
    // Open one as "a" and leave it parked.
    let (mut near, far) = tokio::io::duplex(1024);
    let serving = {
        let parking = parking.clone();
        tokio::spawn(async move {
            parking.serve(far, "a", || async { Ok::<_, String>(far_local) }).await
        })
    };
    write_handshake(&mut near, NONE, 0).await.unwrap();
    let (token, _) = read_handshake(&mut near).await.unwrap();
    assert_ne!(token, NONE);
    drop(near);
    // The broken run waits out its grace for a resume; the pipe stays parked meanwhile.
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!serving.is_finished());
    assert_eq!(parking.len(), 1);
    // "b" naming a's token is told there is no such pipe.
    let (mut near, far) = tokio::io::duplex(1024);
    let serving = {
        let parking = parking.clone();
        tokio::spawn(async move {
            parking.serve(far, "b", || async { Err::<DuplexStream, _>("unused") }).await
        })
    };
    write_handshake(&mut near, token, 0).await.unwrap();
    assert_eq!(read_handshake(&mut near).await.unwrap().0, NONE);
    assert!(matches!(serving.await.unwrap(), Ran::Failed(_)));
    assert_eq!(parking.len(), 1, "a refused resume left the owner's pipe parked");
}

#[tokio::test]
async fn a_far_side_with_no_local_service_opens_nothing() {
    let parking: Arc<Parking<DuplexStream>> = Parking::new(RESUME_GRACE);
    let (near_local, _app) = tokio::io::duplex(1024);
    let held = hold(
        near_local,
        || {
            let parking = parking.clone();
            async move {
                let (near, far) = tokio::io::duplex(1024);
                tokio::spawn(async move {
                    parking
                        .serve(far, "a", || async { Err::<DuplexStream, _>("sshd is down") })
                        .await
                });
                Ok::<_, String>(near)
            }
        },
        RESUME_GRACE,
    )
    .await;
    assert_eq!(held, Held::Failed("the far end did not open the pipe".into()));
    assert!(parking.is_empty());
}

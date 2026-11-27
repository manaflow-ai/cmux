use super::*;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

const BOUND: Duration = Duration::from_secs(20);

#[test]
fn the_log_drops_what_was_acked_and_replays_the_rest() {
    let mut log = SendLog::default();
    log.push(Bytes::from_static(b"hello "));
    log.push(Bytes::from_static(b"world"));
    assert_eq!(log.end(), 11);
    log.ack(3).unwrap();
    assert_eq!((log.base(), log.unacked()), (3, 8));
    let replay: Vec<u8> = log.replay(8).unwrap().concat();
    assert_eq!(replay, b"rld");
    assert_eq!(log.replay(3).unwrap().concat(), b"lo world");
    // A stale ack is no news; one past the end, or a replay outside what was kept, is refused.
    log.ack(1).unwrap();
    assert_eq!(log.base(), 3);
    assert!(log.ack(12).is_err());
    assert!(log.replay(2).is_err());
    assert!(log.replay(12).is_err());
    log.ack(11).unwrap();
    assert_eq!((log.unacked(), log.replay(11).unwrap().len()), (0, 0));
}

#[test]
fn frames_parse_only_when_whole() {
    let mut buf = BytesMut::new();
    let one = frame(DATA, b"abc");
    buf.extend_from_slice(&one[..4]);
    assert_eq!(next_frame(&mut buf).unwrap(), None);
    buf.extend_from_slice(&one[4..]);
    buf.extend_from_slice(&frame(ACK, &7u64.to_be_bytes()));
    assert_eq!(next_frame(&mut buf).unwrap(), Some((DATA, Bytes::from_static(b"abc"))));
    assert_eq!(next_frame(&mut buf).unwrap().unwrap().0, ACK);
    assert!(buf.is_empty());
    let mut huge = BytesMut::new();
    huge.put_u8(DATA);
    huge.put_u32(MAX_PAYLOAD as u32 + 1);
    assert!(next_frame(&mut huge).is_err());
}

/// The two ends' transport, which the test can cut: each end's side of it, and the task copying
/// between them (aborting it closes both sides).
fn transport() -> (DuplexStream, DuplexStream, tokio::task::JoinHandle<()>) {
    let (a, mut a_far) = tokio::io::duplex(64 * 1024);
    let (b, mut b_far) = tokio::io::duplex(64 * 1024);
    let copy = tokio::spawn(async move {
        let _ = tokio::io::copy_bidirectional(&mut a_far, &mut b_far).await;
    });
    (a, b, copy)
}

fn pattern(seed: u64, len: usize) -> Vec<u8> {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
    (0..len)
        .map(|_| {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (x >> 33) as u8
        })
        .collect()
}

/// One end's application side: writes `send`, then ends its writes; returns what it read (what
/// the other end's application sent).
fn app(mut io: DuplexStream, send: Vec<u8>) -> tokio::task::JoinHandle<Vec<u8>> {
    tokio::spawn(async move {
        let (mut read, mut write) = tokio::io::split(&mut io);
        let writing = async {
            for piece in send.chunks(7_001) {
                write.write_all(piece).await.unwrap();
            }
            write.shutdown().await.unwrap();
        };
        let reading = async {
            let mut got = Vec::new();
            read.read_to_end(&mut got).await.unwrap();
            got
        };
        let ((), got) = tokio::join!(writing, reading);
        got
    })
}

async fn run_both(
    a: &Arc<ResumablePipe<DuplexStream>>,
    b: &Arc<ResumablePipe<DuplexStream>>,
    cut_after: Option<Duration>,
) -> (Ran, Ran) {
    let (ta, tb, copy) = transport();
    let (claim_a, claim_b) = (a.claim().await, b.claim().await);
    let (a_has, b_has) = (claim_a.received(), claim_b.received());
    let cutting = async {
        if let Some(after) = cut_after {
            tokio::time::sleep(after).await;
            copy.abort();
        }
        std::future::pending::<()>().await;
    };
    let both = async { tokio::join!(claim_a.run(ta, b_has), claim_b.run(tb, a_has)) };
    tokio::select! {
        ran = both => ran,
        () = cutting => unreachable!(),
    }
}

#[tokio::test]
async fn a_pipe_carries_both_ways_and_finishes() {
    let (app_a, local_a) = tokio::io::duplex(64 * 1024);
    let (app_b, local_b) = tokio::io::duplex(64 * 1024);
    let a = Arc::new(ResumablePipe::new(local_a));
    let b = Arc::new(ResumablePipe::new(local_b));
    let (to_b, to_a) = (pattern(1, 1 << 20), pattern(2, 300_000));
    let (got_a, got_b) = (app(app_a, to_b.clone()), app(app_b, to_a.clone()));
    let ran = tokio::time::timeout(BOUND, run_both(&a, &b, None)).await.unwrap();
    assert_eq!(ran, (Ran::Finished, Ran::Finished));
    assert_eq!(got_a.await.unwrap(), to_a);
    assert_eq!(got_b.await.unwrap(), to_b);
}

#[tokio::test]
async fn cut_after_cut_loses_and_doubles_no_byte() {
    let (app_a, local_a) = tokio::io::duplex(8 * 1024);
    let (app_b, local_b) = tokio::io::duplex(8 * 1024);
    let a = Arc::new(ResumablePipe::new(local_a));
    let b = Arc::new(ResumablePipe::new(local_b));
    // More than the unacked bound, so the local reads wait on acks across the cuts too.
    let (to_b, to_a) = (pattern(3, 3 * MAX_UNACKED), pattern(4, 2 << 20));
    let (got_a, got_b) = (app(app_a, to_b.clone()), app(app_b, to_a.clone()));
    let mut cuts = 0;
    let ran = tokio::time::timeout(BOUND, async {
        loop {
            // A few cuts at once-in-a-while times, then a transport that stays.
            let cut = (cuts < 6).then(|| Duration::from_millis(3 + 7 * cuts));
            match run_both(&a, &b, cut).await {
                (Ran::Broken(_), Ran::Broken(_)) => cuts += 1,
                (Ran::Finished, Ran::Finished) => return,
                // One end saw the cut, the other finished first: the next transport ends it.
                (Ran::Finished, Ran::Broken(_)) | (Ran::Broken(_), Ran::Finished) => cuts += 1,
                other => panic!("a run ended {other:?}"),
            }
        }
    })
    .await;
    assert!(ran.is_ok(), "the pipe did not finish within {BOUND:?} ({cuts} cuts)");
    assert!(cuts >= 1, "no cut landed inside the transfer");
    assert_eq!(got_a.await.unwrap(), to_a);
    assert_eq!(got_b.await.unwrap(), to_b);
}

#[tokio::test]
async fn a_newer_claim_takes_the_pipe_from_a_live_transport() {
    let (_app, local) = tokio::io::duplex(1024);
    let pipe = ResumablePipe::new(local);
    let (ta, _tb, _copy) = transport();
    let run = async { pipe.claim().await.run(ta, 0).await };
    let second = async {
        tokio::time::sleep(Duration::from_millis(20)).await;
        pipe.claim().await.received()
    };
    let (ran, received) = tokio::time::timeout(BOUND, async { tokio::join!(run, second) })
        .await
        .expect("the newer claim waited forever");
    assert!(matches!(ran, Ran::Broken(_)), "{ran:?}");
    assert_eq!(received, 0);
}

#[tokio::test]
async fn a_peer_claiming_bytes_never_sent_fails_the_pipe() {
    let (_app, local) = tokio::io::duplex(1024);
    let pipe = ResumablePipe::new(local);
    let (ta, _tb, _copy) = transport();
    let ran = pipe.claim().await.run(ta, 5).await;
    assert!(matches!(ran, Ran::Failed(_)), "{ran:?}");
}

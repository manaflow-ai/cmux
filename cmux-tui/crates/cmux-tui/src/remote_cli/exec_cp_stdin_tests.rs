use std::cell::RefCell;
use std::rc::Rc;

use tokio::sync::{mpsc, oneshot};

use super::{StdinAck, StdinChunk, forward_stdin_chunks};

type Sent = Rc<RefCell<Vec<(u64, Vec<u8>, bool)>>>;
type Acks = Rc<RefCell<Vec<oneshot::Sender<bool>>>>;

/// A fake daemon: records each write in send order and holds its
/// acknowledgement until the test releases it.
fn fake_send(
    sent: Sent,
    acks: Acks,
) -> impl FnMut(u64, Vec<u8>, bool) -> std::pin::Pin<Box<dyn Future<Output = Option<StdinAck<'static>>>>>
{
    move |write_id, data, eof| {
        sent.borrow_mut().push((write_id, data, eof));
        let (ack, acked) = oneshot::channel();
        acks.borrow_mut().push(ack);
        Box::pin(async move {
            Some(Box::pin(async move { acked.await.unwrap_or(false) }) as StdinAck<'static>)
        })
    }
}

async fn settle() {
    for _ in 0..16 {
        tokio::task::yield_now().await;
    }
}

#[tokio::test(flavor = "current_thread")]
async fn several_stdin_writes_are_in_flight_before_the_first_ack() {
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let (input, chunks) = mpsc::channel(16);
            for byte in 0..6_u8 {
                input.send(StdinChunk::Data(vec![byte])).await.unwrap();
            }
            input.send(StdinChunk::End).await.unwrap();
            drop(input);
            let sent: Sent = Rc::default();
            let acks: Acks = Rc::default();
            let forward = tokio::task::spawn_local(forward_stdin_chunks(
                chunks,
                false,
                4,
                fake_send(sent.clone(), acks.clone()),
            ));
            settle().await;
            // No write is acknowledged yet, and four are on the wire: the
            // old loop sent one and waited a round trip for it.
            assert_eq!(sent.borrow().len(), 4);
            let ids: Vec<u64> = sent.borrow().iter().map(|(id, _, _)| *id).collect();
            assert_eq!(ids, vec![1, 2, 3, 4]);

            acks.borrow_mut().remove(0).send(true).unwrap();
            settle().await;
            assert_eq!(sent.borrow().len(), 5, "one ack frees one slot");

            while !forward.is_finished() {
                let pending: Vec<_> = acks.borrow_mut().drain(..).collect();
                for ack in pending {
                    let _ = ack.send(true);
                }
                settle().await;
            }
            forward.await.unwrap();
            let sent = sent.borrow();
            let order: Vec<(u64, Vec<u8>, bool)> = sent.clone();
            assert_eq!(order.len(), 7, "six data writes and one EOF");
            for (index, (write_id, data, eof)) in order.iter().enumerate() {
                assert_eq!(*write_id, index as u64 + 1, "write ids stay in order");
                if index < 6 {
                    assert_eq!(data, &vec![index as u8], "data stays in order");
                    assert!(!eof);
                } else {
                    assert!(data.is_empty() && *eof, "EOF goes last");
                }
            }
        })
        .await;
}

#[tokio::test(flavor = "current_thread")]
async fn a_refused_stdin_write_stops_forwarding() {
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let (input, chunks) = mpsc::channel(16);
            input.send(StdinChunk::Data(b"a".to_vec())).await.unwrap();
            let sent: Sent = Rc::default();
            let acks: Acks = Rc::default();
            let forward = tokio::task::spawn_local(forward_stdin_chunks(
                chunks,
                false,
                4,
                fake_send(sent.clone(), acks.clone()),
            ));
            settle().await;
            assert_eq!(sent.borrow().len(), 1);
            // The command closed stdin: forwarding ends without waiting for
            // more local input, as it did with one write at a time.
            acks.borrow_mut().remove(0).send(false).unwrap();
            settle().await;
            assert!(forward.is_finished(), "a refused write ends forwarding");
            drop(input);
        })
        .await;
}

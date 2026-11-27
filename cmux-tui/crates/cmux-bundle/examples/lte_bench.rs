//! Before and after for the ultra-connectivity scoreboard's data-class rows, through cmux-fault's
//! deterministic link shaper (a TCP proxy playing a phone's link, `link-profiles.json`).
//!
//! `cargo run -p cmux-bundle --example lte_bench --release -- [profile] [seed] [MiB]`
//!
//! Rows, each as "today" (the bytes sent whole, as the link's `upload`/`file` services do) against
//! "bundle" (offer, want, only the lacking chunks):
//! - re-sent attachment: the far end already holds it;
//! - attachment open: the phone already holds the attachment's chunks (it sent it, or opened it before);
//! - history page: a page re-read after a few new events were appended (bytes the reader lacks: the tail);
//! - first send: nothing on the far end (bundle must not be slower).
//!
//! Each message on the wire is `[u32 BE length][bytes]`; the "Mac" answers each request message with one
//! reply message, and the timer runs from the first byte written to the last reply read.

use cmux_bundle::store::MemStore;
use cmux_bundle::sync::{BATCH_BYTES, Receiver, Sender};
use cmux_bundle::{Kind, PairKey};
use cmux_fault::shaper::{ProfileFile, Shaper};
use cmux_fault::trace::Trace;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

async fn write_msg(s: &mut TcpStream, b: &[u8]) {
    s.write_all(&(b.len() as u32).to_be_bytes()).await.unwrap();
    s.write_all(b).await.unwrap();
}

async fn read_msg(s: &mut TcpStream) -> Option<Vec<u8>> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len).await.ok()?;
    let mut b = vec![0u8; u32::from_be_bytes(len) as usize];
    s.read_exact(&mut b).await.ok()?;
    Some(b)
}

/// The far end. Requests: `R<bytes>` raw upload (reply `ok`); `O<offer>` (reply want); `C<chunks>` (reply
/// `ok`); `G<n>` raw download of the stored blob n (reply bytes); `M<n>` the offer for blob n (reply
/// offer), then `W<want>` (reply chunks messages, then an empty message).
struct Far {
    key: PairKey,
    store: MemStore,
    blobs: Vec<Vec<u8>>,
    rx: Option<Receiver>,
    tx: Option<Sender>,
}

async fn serve(far: Arc<Mutex<Far>>, mut s: TcpStream) {
    s.set_nodelay(true).ok();
    while let Some(msg) = read_msg(&mut s).await {
        let mut f = far.lock().await;
        let f = &mut *f;
        let (tag, body) = (msg[0], &msg[1..]);
        match tag {
            b'R' => write_msg(&mut s, b"ok").await,
            b'O' => {
                let r = Receiver::on_offer(&f.key, body).unwrap();
                let want = r.want(&f.store);
                f.rx = Some(r);
                write_msg(&mut s, &want).await;
            }
            b'C' => {
                f.rx.as_ref().unwrap().on_chunks(body, &mut f.store).unwrap();
                write_msg(&mut s, b"ok").await;
            }
            b'G' => {
                let blob = f.blobs[usize::from(body[0])].clone();
                write_msg(&mut s, &blob).await;
            }
            b'M' => {
                let blob = f.blobs[usize::from(body[0])].clone();
                let tx = Sender::new(&f.key, Kind::Attachment, &blob, &mut f.store).unwrap();
                write_msg(&mut s, &tx.offer()).await;
                f.tx = Some(tx);
            }
            b'W' => {
                let msgs = f.tx.as_ref().unwrap().on_want(body, &f.store, BATCH_BYTES).unwrap();
                for m in msgs {
                    write_msg(&mut s, &m).await;
                }
                write_msg(&mut s, b"").await;
            }
            _ => break,
        }
    }
}

fn tagged(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(body.len() + 1);
    v.push(tag);
    v.extend_from_slice(body);
    v
}

/// Phone uploads `data` raw. Returns the time.
async fn raw_up(s: &mut TcpStream, data: &[u8]) -> Duration {
    let t = Instant::now();
    write_msg(s, &tagged(b'R', data)).await;
    read_msg(s).await.unwrap();
    t.elapsed()
}

/// Phone sends `data` as a bundle. Returns (time, bytes sent up).
async fn bundle_up(
    s: &mut TcpStream,
    key: &PairKey,
    store: &mut MemStore,
    data: &[u8],
) -> (Duration, usize) {
    let t = Instant::now();
    let tx = Sender::new(key, Kind::Attachment, data, store).unwrap();
    let offer = tagged(b'O', &tx.offer());
    let mut sent = offer.len();
    write_msg(s, &offer).await;
    let want = read_msg(s).await.unwrap();
    // Chunk messages stream back to back (no ack per batch); the acks are read after the last one.
    let msgs = tx.on_want(&want, store, BATCH_BYTES).unwrap();
    for m in &msgs {
        let m = tagged(b'C', m);
        sent += m.len();
        write_msg(s, &m).await;
    }
    for _ in &msgs {
        read_msg(s).await.unwrap();
    }
    (t.elapsed(), sent)
}

/// Phone downloads blob `n` raw.
async fn raw_down(s: &mut TcpStream, n: u8) -> (Duration, usize) {
    let t = Instant::now();
    write_msg(s, &[b'G', n]).await;
    let b = read_msg(s).await.unwrap();
    (t.elapsed(), b.len())
}

/// Phone opens blob `n` as a bundle against its own store.
async fn bundle_down(
    s: &mut TcpStream,
    key: &PairKey,
    store: &mut MemStore,
    n: u8,
) -> (Duration, usize, Vec<u8>) {
    let t = Instant::now();
    write_msg(s, &[b'M', n]).await;
    let offer = read_msg(s).await.unwrap();
    let r = Receiver::on_offer(key, &offer).unwrap();
    let mut got = offer.len();
    write_msg(s, &tagged(b'W', &r.want(store))).await;
    loop {
        let m = read_msg(s).await.unwrap();
        if m.is_empty() {
            break;
        }
        got += m.len();
        r.on_chunks(&m, store).unwrap();
    }
    let bytes = r.assemble(store).unwrap();
    (t.elapsed(), got, bytes)
}

fn noise(len: usize, seed: u64) -> Vec<u8> {
    let mut s = seed | 1;
    (0..len)
        .map(|_| {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s as u8
        })
        .collect()
}

/// A JSONL history page: `n` events of agent chat (text compresses like a real transcript, not noise).
fn history(n: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for i in 0..n {
        out.extend_from_slice(
            format!(
                "{{\"seq\":{i},\"kind\":\"agent_message_chunk\",\"text\":\"Reading crates/cmux-wg/src/pacing.rs line {} to see how the class queue orders datagram {} behind the input lane\"}}\n",
                i * 7 % 900,
                i * 13 % 4096
            )
            .as_bytes(),
        );
    }
    out
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let profile_name = args.get(1).map_or("lte", String::as_str);
    let seed: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1);
    let mib: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(4);
    let profile =
        ProfileFile::builtin().get(profile_name).expect("a profile in link-profiles.json").clone();
    let label = format!("{}@{}", profile.name, profile.version);

    let key = PairKey::derive(&[0x42; 32]);
    let attachment = noise(mib << 20, seed);
    let page_before = history(20_000);
    let mut page_after = page_before.clone();
    page_after.extend_from_slice(&history(20_040)[page_before.len()..]);
    let far = Arc::new(Mutex::new(Far {
        key: key.clone(),
        store: MemStore::default(),
        blobs: vec![attachment.clone(), page_after.clone()],
        rx: None,
        tx: None,
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream = listener.local_addr().unwrap();
    {
        let far = far.clone();
        tokio::spawn(async move {
            while let Ok((s, _)) = listener.accept().await {
                tokio::spawn(serve(far.clone(), s));
            }
        });
    }
    let trace = Trace::default();
    let shaper = Shaper::start(upstream, profile, seed, &trace).await.unwrap();
    let mut s = TcpStream::connect(shaper.addr()).await.unwrap();
    s.set_nodelay(true).ok();
    let mut phone = MemStore::default();

    // First send.
    let raw_first = raw_up(&mut s, &attachment).await;
    let (bundle_first, first_bytes) = bundle_up(&mut s, &key, &mut phone, &attachment).await;
    // Re-sent attachment (the far end has it now).
    let raw_resend = raw_up(&mut s, &attachment).await;
    let (bundle_resend, resend_bytes) = bundle_up(&mut s, &key, &mut phone, &attachment).await;
    // Attachment open: the phone holds the chunks (it sent it).
    let (raw_open, raw_open_bytes) = raw_down(&mut s, 0).await;
    let (bundle_open, open_bytes, opened) = bundle_down(&mut s, &key, &mut phone, 0).await;
    assert_eq!(opened, attachment);
    // History page: the phone read the page before 40 events were appended.
    let mut tmp = MemStore::default();
    let _ = Sender::new(&key, Kind::HistoryPage, &page_before, &mut tmp).unwrap();
    for id in tmp_ids(&key, &page_before) {
        phone_put(&mut phone, &tmp, &id);
    }
    let (raw_page, raw_page_bytes) = raw_down(&mut s, 1).await;
    let (bundle_page, page_bytes, page) = bundle_down(&mut s, &key, &mut phone, 1).await;
    assert_eq!(page, page_after);

    let row = |name: &str, before: Duration, before_b: usize, after: Duration, after_b: usize| {
        println!(
            "{{\"profile\":\"{label}\",\"seed\":{seed},\"row\":\"{name}\",\"today_ms\":{:.0},\"today_bytes\":{before_b},\"bundle_ms\":{:.0},\"bundle_bytes\":{after_b}}}",
            ms(before),
            ms(after)
        );
    };
    row("first send", raw_first, attachment.len(), bundle_first, first_bytes);
    row("re-sent attachment", raw_resend, attachment.len(), bundle_resend, resend_bytes);
    row("attachment open (phone holds it)", raw_open, raw_open_bytes, bundle_open, open_bytes);
    row("history page after +40 events", raw_page, raw_page_bytes, bundle_page, page_bytes);
    // The link deflates today; the page's compressed size is the floor a whole resend could reach.
    let z = zstd::bulk::compress(&page_after, 3).unwrap().len();
    println!(
        "{{\"profile\":\"{label}\",\"row\":\"history page compressed whole (zstd 3)\",\"bytes\":{z}}}"
    );
}

fn tmp_ids(key: &PairKey, data: &[u8]) -> Vec<cmux_bundle::ChunkId> {
    cmux_bundle::cdc::chunks(data).map(|c| key.chunk_id(c)).collect()
}

fn phone_put(phone: &mut MemStore, from: &MemStore, id: &cmux_bundle::ChunkId) {
    use cmux_bundle::store::Store as _;
    let sealed = from.get(id).unwrap().unwrap();
    phone.put(id, &sealed).unwrap();
}

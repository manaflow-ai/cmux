//! RFD 0166 F1: a second machine fetches an artifact's chunks from a fleet neighbour, and only
//! what no honest, reachable peer gave from the floor.

use cmux_session_pack::peer::{self, FetchStats};
use cmux_session_pack::{Id, Store, chunk_id, encode_chunk};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

/// A store holding `n` chunks of `size` pseudo-random (incompressible) bytes; their ids.
fn filled(dir: &std::path::Path, n: usize, size: usize) -> (Store, Vec<Id>) {
    let store = Store::new(dir);
    let mut x = 0x2545_f491_4f6c_dd1du64;
    let mut ids = Vec::new();
    for i in 0..n {
        let bytes: Vec<u8> = (0..size)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 24) as u8 ^ i as u8
            })
            .collect();
        let id = chunk_id(b'B', &bytes);
        store.put_stored(&id, &encode_chunk(b'B', &bytes, 1).unwrap()).unwrap();
        ids.push(id);
    }
    (store, ids)
}

fn serve(store: &Store) -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let store = store.clone();
    std::thread::spawn(move || peer::serve(store, l));
    addr
}

/// A floor that reads from `origin` and counts what it served.
fn floor(origin: &Store) -> impl FnMut(&Id) -> cmux_session_pack::Result<Vec<u8>> + '_ {
    move |id| origin.stored(id)
}

const T: Duration = Duration::from_secs(5);

#[test]
fn a_neighbour_holding_everything_means_zero_floor_bytes() {
    let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (origin, ids) = filled(a.path(), 40, 256 << 10);
    let addr = serve(&origin);
    let fresh = Store::new(b.path());
    let start = Instant::now();
    let s = peer::fetch(&fresh, &ids, &[addr], T, &mut floor(&origin)).unwrap();
    let secs = start.elapsed().as_secs_f64();
    assert_eq!(s.peer_chunks, 40, "{s:?}");
    assert_eq!((s.floor_chunks, s.floor_bytes), (0, 0), "{s:?}");
    assert!(s.dropped.is_empty(), "{s:?}");
    for id in &ids {
        assert!(fresh.verified(id).unwrap());
    }
    eprintln!(
        "F1 lan: {} MB from the peer, 0 floor bytes, {:.0} MB/s",
        s.peer_bytes >> 20,
        s.peer_bytes as f64 / secs / 1e6
    );
    // Again: everything held, nothing asked.
    let s = peer::fetch(&fresh, &ids, &[addr], T, &mut floor(&origin)).unwrap();
    assert_eq!((s.held, s.peer_chunks, s.floor_chunks), (40, 0, 0));
}

#[test]
fn a_partial_peer_gives_what_it_holds_and_the_floor_the_rest() {
    let (a, b, c) =
        (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (origin, ids) = filled(a.path(), 20, 64 << 10);
    let half = Store::new(c.path());
    for id in &ids[..10] {
        half.receive(id, &origin.stored(id).unwrap()).unwrap();
    }
    let addr = serve(&half);
    let fresh = Store::new(b.path());
    let s = peer::fetch(&fresh, &ids, &[addr], T, &mut floor(&origin)).unwrap();
    assert_eq!((s.peer_chunks, s.floor_chunks), (10, 10), "{s:?}");
}

#[test]
fn an_unreachable_peer_costs_its_timeout_and_the_floor_finishes() {
    let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (origin, ids) = filled(a.path(), 8, 32 << 10);
    // A port nothing listens on.
    let dead = {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap()
    };
    let fresh = Store::new(b.path());
    let s = peer::fetch(&fresh, &ids, &[dead], T, &mut floor(&origin)).unwrap();
    assert_eq!((s.peer_chunks, s.floor_chunks), (0, 8), "{s:?}");
    assert_eq!(s.dropped.len(), 1);
}

/// A peer that answers every request with the right ids but wrong bytes.
fn liar(origin: &Store, ids: Vec<Id>) -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    let origin = origin.clone();
    std::thread::spawn(move || {
        for mut c in l.incoming().flatten() {
            let mut head = [0u8; 10];
            if c.read_exact(&mut head).is_err() {
                continue;
            }
            let n = u32::from_le_bytes(head[6..10].try_into().unwrap()) as usize;
            let mut want = vec![0u8; 32 * n];
            let _ = c.read_exact(&mut want);
            for id in &ids {
                let mut file = origin.stored(id).unwrap();
                let last = file.len() - 1;
                file[last] ^= 0xff;
                let _ = c.write_all(id);
                let _ = c.write_all(&(file.len() as u32).to_le_bytes());
                let _ = c.write_all(&file);
            }
        }
    });
    addr
}

#[test]
fn a_lying_peer_is_dropped_after_one_chunk_and_the_next_peer_serves() {
    let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (origin, ids) = filled(a.path(), 10, 32 << 10);
    let bad = liar(&origin, ids.clone());
    let good = serve(&origin);
    let fresh = Store::new(b.path());
    let s = peer::fetch(&fresh, &ids, &[bad, good], T, &mut floor(&origin)).unwrap();
    assert_eq!(s.dropped.len(), 1, "{s:?}");
    assert_eq!(s.dropped[0].0, bad);
    assert_eq!((s.peer_chunks, s.floor_chunks), (10, 0), "{s:?}");
    for id in &ids {
        assert!(fresh.verified(id).unwrap());
    }
}

/// A proxy to `to` that cuts each connection after `budget` answer bytes (a link that drops).
fn cutting_proxy(to: SocketAddr, budget: usize) -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    std::thread::spawn(move || {
        for c in l.incoming().flatten() {
            let up = TcpStream::connect(to).unwrap();
            let (mut c_r, mut up_w) = (c.try_clone().unwrap(), up.try_clone().unwrap());
            std::thread::spawn(move || std::io::copy(&mut c_r, &mut up_w));
            let (mut up_r, mut c_w) = (up, c);
            std::thread::spawn(move || {
                let mut left = budget;
                let mut buf = [0u8; 16 << 10];
                while left > 0 {
                    let Ok(n) = up_r.read(&mut buf) else { break };
                    if n == 0 {
                        break;
                    }
                    let n = n.min(left);
                    if c_w.write_all(&buf[..n]).is_err() {
                        break;
                    }
                    left -= n;
                }
                let _ = c_w.shutdown(std::net::Shutdown::Both);
            });
        }
    });
    addr
}

#[test]
fn a_link_cut_mid_answer_keeps_what_arrived_and_resumes_the_rest() {
    let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (origin, ids) = filled(a.path(), 20, 64 << 10);
    let addr = serve(&origin);
    // About 7.5 chunks arrive, then the link drops.
    let cut = cutting_proxy(addr, 7 * (64 << 10) + (32 << 10));
    let fresh = Store::new(b.path());
    let s: FetchStats =
        peer::fetch(&fresh, &ids, &[cut, cut, cut], T, &mut floor(&origin)).unwrap();
    // Each attempt keeps the chunks it got whole; the cut one is asked again.
    assert_eq!(s.floor_chunks, 0, "{s:?}");
    assert_eq!(s.peer_chunks, 20, "{s:?}");
    assert_eq!(s.dropped.len(), 2, "{s:?}");
}

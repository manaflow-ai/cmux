use super::*;

/// 64 KiB through a 128 KiB/s, 100 ms link takes about 0.6 s, not less.
#[test]
fn the_link_is_as_slow_as_asked() {
    let dir = std::env::temp_dir().join(format!("csd-proxy-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let up = dir.join("up.sock");
    let l = UnixListener::bind(&up).unwrap();
    std::thread::scope(|sc| {
        sc.spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            s.write_all(&vec![b'x'; 64 << 10]).unwrap();
        });
        let link = Link { rate_bps: 128 << 10, latency: Duration::from_millis(100) };
        let p = Proxy::start(sc, &dir.join("p.sock"), &up, link).unwrap();
        let t = Instant::now();
        let mut c = UnixStream::connect(&p.listen).unwrap();
        let mut got = Vec::new();
        c.read_to_end(&mut got).unwrap();
        let took = t.elapsed();
        assert_eq!(got.len(), 64 << 10);
        assert!(took >= Duration::from_millis(550), "{took:?}");
        assert!(took < Duration::from_secs(3), "{took:?}");
    });
    let _ = std::fs::remove_dir_all(&dir);
}

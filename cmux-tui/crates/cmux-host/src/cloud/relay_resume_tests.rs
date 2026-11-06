//! A wake from a pause (cmuxterm-hq run 42119371232): the socket from before it looks alive to the relay, whose
//! clock stood still, so the platform sent the next chat down it and ended that chat with `host_gone`.

use super::*;

fn runner() -> Runner {
    Runner {
        bin: PathBuf::from("/bin/false"),
        user: "nobody".into(),
        uid: 65534,
        gid: 65534,
        groups: vec![65534],
        home: PathBuf::from("/"),
    }
}

fn wall() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

#[test]
fn a_resume_drops_the_socket_at_once_and_keeps_its_chats() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        // The platform's end: it takes the socket and stays silent, as a socket from before a pause looks here.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/relay", listener.local_addr().unwrap());
        let (resume, mut resumes) = watch::channel(0u64);
        let mut link = Link::default();
        let chat = tokio::spawn(std::future::pending::<()>());
        link.chats.0.insert("c1".to_owned(), chat.abort_handle());
        let endpoint = async {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            // The socket is up; then the machine resumes.
            resume.send_modify(|n| *n += 1);
            let gone = async { while let Some(Ok(_)) = ws.next().await {} };
            tokio::time::timeout(Duration::from_secs(10), gone).await.is_ok()
        };
        let runner = runner();
        let started = std::time::Instant::now();
        let serving = serve(&url, "t", &runner, &mut link, &mut resumes, 0, wall);
        let (ended, gone) =
            tokio::join!(tokio::time::timeout(Duration::from_secs(5), serving), endpoint);
        let ended = ended.map_err(|_| "still serving the old socket 5 s after the resume");
        assert_eq!(ended, Ok(Ok(Ended::Resumed)));
        assert!(started.elapsed() < Duration::from_secs(2), "not at a ping tick or after 60 s");
        assert!(gone, "the old socket is closed");
        tokio::task::yield_now().await;
        assert!(!chat.is_finished(), "a running chat goes on to the next socket");
        assert!(link.chats.0.contains_key("c1"));
    });
}

#[test]
fn a_resume_cuts_the_backoff_short() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let (_stop, mut stopping) = watch::channel(false);
    let (resume, mut resumes) = watch::channel(0u64);
    let started = std::time::Instant::now();
    let waiting = std::thread::spawn(move || {
        pause(&rt, &mut stopping, &mut resumes, 0, Duration::from_secs(10));
    });
    std::thread::sleep(Duration::from_millis(50));
    resume.send_modify(|n| *n += 1);
    waiting.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(2), "it waited out the backoff after a resume");
}

#[test]
fn a_wall_clock_leap_between_pings_reads_as_a_resume() {
    // The run's pause: acpmux saw gap_ms=753239; pings run every 20 s.
    assert!(slept_through(1_000, 1_000 + 753_239));
    assert!(!slept_through(1_000, 1_000 + PING_EVERY.as_millis() as u64));
    assert!(!slept_through(1_000, 500), "a clock set back is not a pause");
}

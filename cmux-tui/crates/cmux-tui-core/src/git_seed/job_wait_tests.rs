use super::*;

fn job() -> Arc<Job> {
    Arc::new(Job::running("seed_t".into(), PathBuf::from("/t"), String::new(), Phase::Clone))
}

#[test]
fn a_held_status_answers_when_the_job_ends() {
    let job = job();
    let worker = job.clone();
    let ender = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(100));
        worker.finish(Ok(()));
    });
    let began = Instant::now();
    assert!(job.wait_end(Duration::from_secs(5)));
    let took = began.elapsed();
    ender.join().unwrap();
    assert_eq!(job.answer()["state"], "done");
    assert!(took >= Duration::from_millis(90), "answered before the end: {took:?}");
    assert!(took < Duration::from_secs(3), "waited past the end: {took:?}");
}

#[test]
fn a_held_status_answers_when_the_head_is_ready() {
    let job = job();
    let worker = job.clone();
    let marker = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        // Progress alone does not end the wait.
        worker.enter(Phase::Fetch);
        std::thread::sleep(Duration::from_millis(50));
        worker.reached_head();
    });
    let began = Instant::now();
    assert!(job.wait_end(Duration::from_secs(5)));
    marker.join().unwrap();
    assert!(began.elapsed() >= Duration::from_millis(90));
    assert_eq!(job.answer()["head_ready"], true);
    assert_eq!(job.answer()["state"], "running");
}

#[test]
fn a_held_status_answers_at_its_limit_or_at_once_when_ended() {
    let job = job();
    let began = Instant::now();
    assert!(job.wait_end(Duration::from_millis(60)));
    assert!(began.elapsed() >= Duration::from_millis(55));
    job.finish(Err(Failed { code: "seed.t", error: "t".into(), install_url: None }));
    let began = Instant::now();
    assert!(!job.wait_end(Duration::from_secs(5)), "an ended job does not wait");
    assert!(began.elapsed() < Duration::from_millis(500));
}

use super::*;

#[test]
fn terminal_work_pool_runs_every_job_and_keeps_input_order() {
    let pool = TerminalWorkPool::default();
    let jobs: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..50usize)
        .map(|index| {
            Box::new(move || {
                std::thread::sleep(Duration::from_millis((50 - index as u64) % 7));
                index * 2
            }) as Box<dyn FnOnce() -> usize + Send>
        })
        .collect();
    let results = pool.run_all(jobs).into_iter().map(Result::unwrap).collect::<Vec<_>>();
    assert_eq!(results, (0..50).map(|index| index * 2).collect::<Vec<_>>());
}

#[test]
fn terminal_work_pool_survives_panicking_jobs() {
    fn failing_job() -> usize {
        panic!("job failed")
    }
    let pool = TerminalWorkPool::default();
    let panicking: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..2 * MAX_TERMINAL_WORKERS)
        .map(|_| Box::new(failing_job) as Box<dyn FnOnce() -> usize + Send>)
        .collect();
    assert!(pool.run_all(panicking).iter().all(Result::is_err));
    for _ in 0..2 * MAX_TERMINAL_WORKERS {
        let queued = pool.try_submit(Box::new(|| panic!("raw job failed")));
        assert!(queued.is_ok());
    }
    // Every worker slot came back, so later jobs still run.
    let jobs: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..MAX_TERMINAL_WORKERS)
        .map(|index| Box::new(move || index) as Box<dyn FnOnce() -> usize + Send>)
        .collect();
    let results = pool.run_all(jobs).into_iter().map(Result::unwrap).collect::<Vec<_>>();
    assert_eq!(results, (0..MAX_TERMINAL_WORKERS).collect::<Vec<_>>());
    assert_eq!(pool.state.lock().unwrap().queue.len(), 0);
}

#[test]
fn terminal_work_pool_bounds_concurrent_workers() {
    let pool = TerminalWorkPool::default();
    let running = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let jobs: Vec<Box<dyn FnOnce() + Send>> = (0..40)
        .map(|_| {
            let running = running.clone();
            let peak = peak.clone();
            Box::new(move || {
                let now = running.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(now, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(5));
                running.fetch_sub(1, Ordering::SeqCst);
            }) as Box<dyn FnOnce() + Send>
        })
        .collect();
    pool.run_all(jobs);
    let peak = peak.load(Ordering::SeqCst);
    assert!(peak <= MAX_TERMINAL_WORKERS, "peak {peak} workers");
    assert!(peak > 1, "jobs did not overlap");
}

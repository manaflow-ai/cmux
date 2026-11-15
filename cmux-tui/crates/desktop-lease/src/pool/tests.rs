use super::*;
use crate::backend::ActOutput;
use std::sync::atomic::AtomicUsize;

/// A desktop that only counts: resident 100 MB awake, 10 MB suspended, 0 evicted.
#[derive(Default)]
struct Counts {
    spawned: AtomicUsize,
    destroyed: AtomicUsize,
    evicted: AtomicUsize,
}

struct Fake(Arc<Counts>);

struct FakeDesktop {
    counts: Arc<Counts>,
    resident: u64,
}

impl Backend for Fake {
    fn kind(&self) -> &'static str {
        "linux-xvfb"
    }
    fn spawn(&self, _id: &str, _spec: &SlotSpec) -> Result<Box<dyn Desktop>> {
        self.0.spawned.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(FakeDesktop { counts: Arc::clone(&self.0), resident: 100 << 20 }))
    }
}

impl Desktop for FakeDesktop {
    fn suspend(&mut self) -> Result<SuspendReport> {
        self.resident = 10 << 20;
        Ok(SuspendReport::default())
    }
    fn resume(&mut self) -> Result<f64> {
        self.resident = 100 << 20;
        Ok(1.0)
    }
    fn act(&mut self, _action: &Action) -> Result<ActOutput> {
        Ok(ActOutput { png: vec![1, 2, 3], ..Default::default() })
    }
    fn resident_bytes(&self) -> u64 {
        self.resident
    }
    fn evict(&mut self) -> Result<SuspendReport> {
        self.counts.evicted.fetch_add(1, Ordering::SeqCst);
        self.resident = 0;
        Ok(SuspendReport::default())
    }
    fn destroy(&mut self) {
        self.counts.destroyed.fetch_add(1, Ordering::SeqCst);
    }
    fn owner_record(&self) -> serde_json::Value {
        serde_json::Value::Null
    }
}

fn pool(warm: usize, budget_mb: u64) -> (Arc<Pool>, Arc<Counts>) {
    let counts = Arc::new(Counts::default());
    let cfg = Config { warm, budget_mb, suspend_after: Duration::ZERO };
    (Pool::new(vec![Arc::new(Fake(Arc::clone(&counts)))], cfg), counts)
}

fn state(pool: &Pool, id: &str) -> State {
    pool.slot(id).ok().and_then(|s| s.lock().ok().map(|s| s.state)).unwrap_or(State::Evicted)
}

/// Waits for the background suspend an action starts (bounded).
fn until(mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !f() {
        assert!(Instant::now() < deadline, "condition never held");
        std::thread::yield_now();
    }
}

#[test]
fn lease_takes_a_warm_suspended_slot_and_act_resumes_then_suspends_it() {
    let (pool, counts) = pool(2, 10_000);
    pool.refill().unwrap();
    assert_eq!(counts.spawned.load(Ordering::SeqCst), 2);
    let lease = pool.lease("a", &SlotSpec::default()).unwrap();
    assert!(lease.from_warm);
    assert_eq!(state(&pool, &lease.slot), State::Suspended);
    let r = pool.act("a", &lease.slot, &Action::Screenshot).unwrap();
    assert_eq!(r.was, State::Suspended);
    assert_eq!(r.png, vec![1, 2, 3]);
    until(|| state(&pool, &lease.slot) == State::Suspended);
}

#[test]
fn another_owner_cannot_act_or_release() {
    let (pool, _) = pool(1, 10_000);
    pool.refill().unwrap();
    let lease = pool.lease("a", &SlotSpec::default()).unwrap();
    assert!(pool.act("b", &lease.slot, &Action::Screenshot).is_err());
    assert!(pool.release("b", &lease.slot).is_err());
    pool.release("a", &lease.slot).unwrap();
    assert!(pool.act("a", &lease.slot, &Action::Screenshot).is_err());
}

#[test]
fn over_budget_destroys_idle_warm_slots_before_evicting_leased_ones() {
    // Three suspended slots are 30 MB; a 15 MB budget drops the two idle warm ones first.
    let (pool, counts) = pool(3, 10_000);
    pool.refill().unwrap();
    let lease = pool.lease("a", &SlotSpec::default()).unwrap();
    pool.set_budget_mb(15);
    pool.enforce_budget();
    assert_eq!(counts.evicted.load(Ordering::SeqCst), 0);
    assert_eq!(state(&pool, &lease.slot), State::Suspended);
    assert!(counts.destroyed.load(Ordering::SeqCst) >= 1);
    // Under 5 MB the leased one is evicted, not destroyed.
    pool.set_budget_mb(5);
    pool.enforce_budget();
    assert_eq!(counts.evicted.load(Ordering::SeqCst), 1);
    assert_eq!(state(&pool, &lease.slot), State::Evicted);
    // The next action resumes an evicted slot too.
    assert_eq!(pool.act("a", &lease.slot, &Action::Screenshot).unwrap().was, State::Evicted);
}

#[test]
fn release_owner_frees_every_slot_of_an_ended_session() {
    let (pool, _) = pool(0, 10_000);
    let a = pool.lease("a", &SlotSpec::default()).unwrap();
    let b = pool.lease("a", &SlotSpec::default()).unwrap();
    let c = pool.lease("c", &SlotSpec::default()).unwrap();
    assert!(!a.from_warm);
    assert_eq!(pool.release_owner("a"), 2);
    assert!(pool.slot(&a.slot).is_err() && pool.slot(&b.slot).is_err());
    assert!(pool.slot(&c.slot).is_ok());
}

//! The pool: N pre-warmed, suspended desktops; lease hands one out, every
//! action resumes it first and suspends it again right after (the model is
//! thinking), release destroys it and warms a fresh one. Over the RAM budget
//! the least recently used suspended slot goes a tier down: an idle warm slot
//! is destroyed, a leased one is evicted (its pages leave RAM).

use crate::backend::{ActOutput, Action, Backend, Desktop, SlotSpec, SuspendReport};
use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Config {
    /// Desktops kept warm (made and suspended) for the next lease.
    pub warm: usize,
    /// The resident budget over every slot, in MB; over it, LRU goes down a tier.
    pub budget_mb: u64,
    /// How long a slot stays awake after an action before it is suspended (0: at once).
    pub suspend_after: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Awake,
    Suspended,
    Evicted,
}

struct Slot {
    desktop: Box<dyn Desktop>,
    spec: SlotSpec,
    state: State,
    owner: Option<String>,
    last_used: Instant,
    /// Bumped by every action, so a late suspend skips a slot acted on since.
    generation: u64,
    last_suspend: Option<SuspendReport>,
}

/// One action's answer.
#[derive(Debug, Clone, Serialize)]
pub struct ActReport {
    #[serde(skip)]
    pub png: Vec<u8>,
    pub slot: String,
    pub title: Option<String>,
    /// The state the slot was in when the action arrived.
    pub was: State,
    pub resume_ms: f64,
    pub act_ms: f64,
    pub screenshot_ms: f64,
    /// Arrival to screenshot in hand, resume included.
    pub total_ms: f64,
    pub resident_awake_mb: f64,
    /// The suspend that ran after the previous action (what the slot cost while the model thought).
    pub last_suspend: Option<SuspendReport>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LeaseReport {
    pub slot: String,
    pub backend: String,
    pub from_warm: bool,
    pub lease_ms: f64,
}

pub struct Pool {
    backends: Vec<Arc<dyn Backend>>,
    slots: Mutex<HashMap<String, Arc<Mutex<Slot>>>>,
    warm: Mutex<VecDeque<String>>,
    warming: (Mutex<usize>, Condvar),
    next_id: AtomicU64,
    budget_mb: AtomicU64,
    /// Owns the pool's background work (suspends, destroys, warming, connections).
    scope: cmux_scope::Scope,
    pub cfg: Config,
}

/// One runtime for every pool's background work, made once and never dropped. `None` when it
/// could not be made: the work then runs on the caller's thread.
fn runtime() -> Option<&'static tokio::runtime::Runtime> {
    static RT: OnceLock<Option<tokio::runtime::Runtime>> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("desktop-lease")
            .enable_all()
            .build()
            .map_err(|e| eprintln!("desktop-lease: no runtime ({e}); background work runs inline"))
            .ok()
    })
    .as_ref()
}

const MB: f64 = 1024.0 * 1024.0;

impl Pool {
    pub fn new(backends: Vec<Arc<dyn Backend>>, cfg: Config) -> Arc<Self> {
        Arc::new(Pool {
            backends,
            slots: Mutex::new(HashMap::new()),
            warm: Mutex::new(VecDeque::new()),
            warming: (Mutex::new(0), Condvar::new()),
            next_id: AtomicU64::new(1),
            budget_mb: AtomicU64::new(cfg.budget_mb),
            scope: cmux_scope::Scope::new("desktop-lease pool"),
            cfg,
        })
    }

    fn backend(&self, kind: &str) -> Result<Arc<dyn Backend>> {
        self.backends
            .iter()
            .find(|b| b.kind() == kind)
            .cloned()
            .ok_or_else(|| anyhow!("no '{kind}' slot backend on this host"))
    }

    fn slot(&self, id: &str) -> Result<Arc<Mutex<Slot>>> {
        lock(&self.slots)?.get(id).cloned().ok_or_else(|| anyhow!("no slot '{id}'"))
    }

    fn make(&self, spec: &SlotSpec) -> Result<String> {
        let id = format!("s{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let desktop = self.backend(&spec.backend)?.spawn(&id, spec)?;
        let slot = Slot {
            desktop,
            spec: spec.clone(),
            state: State::Awake,
            owner: None,
            last_used: Instant::now(),
            generation: 0,
            last_suspend: None,
        };
        lock(&self.slots)?.insert(id.clone(), Arc::new(Mutex::new(slot)));
        Ok(id)
    }

    /// Fill the warm set up to `cfg.warm`, suspending each new desktop.
    pub fn refill(self: &Arc<Self>) -> Result<()> {
        loop {
            {
                let warm = lock(&self.warm)?.len();
                let mut warming = lock(&self.warming.0)?;
                if warm + *warming >= self.cfg.warm || self.resident_total() > self.budget_bytes() {
                    return Ok(());
                }
                *warming += 1;
            }
            let made = self.make(&SlotSpec::default()).and_then(|id| {
                self.suspend_now(&id, None)?;
                Ok(id)
            });
            if let Ok(id) = &made {
                lock(&self.warm)?.push_back(id.clone());
            }
            *lock(&self.warming.0)? -= 1;
            self.warming.1.notify_all();
            made?;
        }
    }

    /// Run blocking `work` as a task the pool's scope owns (its close cancels and joins it).
    pub fn background(&self, name: &'static str, work: impl FnOnce() + Send + 'static) {
        match runtime() {
            Some(rt) => {
                let _entered = rt.enter();
                self.scope.spawn_named(name, async move {
                    let _ = tokio::task::spawn_blocking(work).await;
                });
            }
            None => work(),
        }
    }

    /// Close the pool's scope: its background work is joined (or named, past `within`).
    pub fn close(&self, within: Duration) {
        if let Some(rt) = runtime() {
            let report = rt.block_on(self.scope.close(within));
            if !report.joined() {
                eprintln!("desktop-lease: {report}");
            }
        }
    }

    pub fn refill_in_background(self: &Arc<Self>) {
        let pool = Arc::clone(self);
        self.background("warm a slot", move || {
            if let Err(e) = pool.refill() {
                eprintln!("desktop-lease: warming a slot failed: {e:#}");
            }
        });
    }

    pub fn lease(self: &Arc<Self>, owner: &str, spec: &SlotSpec) -> Result<LeaseReport> {
        let t = Instant::now();
        let default_shape = *spec == SlotSpec::default();
        let warm = if default_shape {
            // A lease that arrives while the pool is still warming waits for that slot.
            let mut warm = lock(&self.warm)?.pop_front();
            while warm.is_none() {
                let n = lock(&self.warming.0)?;
                if *n == 0 {
                    break;
                }
                drop(self.warming.1.wait(n).map_err(|_| anyhow!("pool lock poisoned"))?);
                warm = lock(&self.warm)?.pop_front();
            }
            warm
        } else {
            None
        };
        let (id, from_warm) = match warm {
            Some(id) => (id, true),
            None => {
                let id = self.make(spec)?;
                self.suspend_now(&id, None)?;
                (id, false)
            }
        };
        {
            let slot = self.slot(&id)?;
            let mut s = lock(&slot)?;
            s.owner = Some(owner.to_owned());
            s.last_used = Instant::now();
        }
        self.refill_in_background();
        Ok(LeaseReport { slot: id, backend: spec.backend.clone(), from_warm, lease_ms: ms(t) })
    }

    pub fn act(self: &Arc<Self>, owner: &str, id: &str, action: &Action) -> Result<ActReport> {
        let t = Instant::now();
        let slot = self.slot(id)?;
        let (out, was, resume_ms, generation, resident, last_suspend): (ActOutput, _, _, _, _, _) = {
            let mut s = lock(&slot)?;
            if s.owner.as_deref() != Some(owner) {
                bail!("slot '{id}' is not leased by '{owner}'");
            }
            let was = s.state;
            let resume_ms = if was == State::Awake { 0.0 } else { s.desktop.resume()? };
            s.state = State::Awake;
            let out = s.desktop.act(action)?;
            s.generation += 1;
            s.last_used = Instant::now();
            let last_suspend = s.last_suspend.take();
            (out, was, resume_ms, s.generation, s.desktop.resident_bytes(), last_suspend)
        };
        // The model thinks now: suspend once the grace has passed, unless another action came.
        let pool = Arc::clone(self);
        let id_owned = id.to_owned();
        self.background("suspend after an action", move || {
            std::thread::sleep(pool.cfg.suspend_after);
            if let Err(e) = pool.suspend_now(&id_owned, Some(generation)) {
                eprintln!("desktop-lease: suspending {id_owned} failed: {e:#}");
            }
            pool.enforce_budget();
        });
        Ok(ActReport {
            slot: id.to_owned(),
            title: out.title,
            was,
            resume_ms,
            act_ms: out.act_ms,
            screenshot_ms: out.screenshot_ms,
            total_ms: ms(t),
            resident_awake_mb: resident as f64 / MB,
            last_suspend,
            png: out.png,
        })
    }

    /// Suspend a slot unless it is already, or (with `generation`) was acted on since.
    fn suspend_now(&self, id: &str, generation: Option<u64>) -> Result<()> {
        let Ok(slot) = self.slot(id) else { return Ok(()) };
        let mut s = lock(&slot)?;
        if s.state != State::Awake || generation.is_some_and(|g| g != s.generation) {
            return Ok(());
        }
        let report = s.desktop.suspend()?;
        s.state = State::Suspended;
        s.last_suspend = Some(report);
        Ok(())
    }

    pub fn release(self: &Arc<Self>, owner: &str, id: &str) -> Result<()> {
        let slot = self.slot(id)?;
        if lock(&slot)?.owner.as_deref() != Some(owner) {
            bail!("slot '{id}' is not leased by '{owner}'");
        }
        lock(&self.slots)?.remove(id);
        // Destroy off the caller's path; a fresh warm slot replaces it.
        let pool = Arc::clone(self);
        self.background("destroy a released slot", move || {
            if let Ok(mut s) = slot.lock() {
                s.desktop.destroy();
            }
            if let Err(e) = pool.refill() {
                eprintln!("desktop-lease: warming a slot failed: {e:#}");
            }
        });
        Ok(())
    }

    /// Release every slot an owner holds (its session ended).
    pub fn release_owner(self: &Arc<Self>, owner: &str) -> usize {
        let ids: Vec<String> = match lock(&self.slots) {
            Ok(slots) => slots
                .iter()
                .filter(|(_, s)| s.try_lock().is_ok_and(|s| s.owner.as_deref() == Some(owner)))
                .map(|(id, _)| id.clone())
                .collect(),
            Err(_) => return 0,
        };
        ids.iter().filter(|id| self.release(owner, id).is_ok()).count()
    }

    fn budget_bytes(&self) -> u64 {
        self.budget_mb.load(Ordering::Relaxed).saturating_mul(1024 * 1024)
    }

    pub fn set_budget_mb(&self, mb: u64) {
        self.budget_mb.store(mb, Ordering::Relaxed);
    }

    pub fn resident_total(&self) -> u64 {
        let slots: Vec<_> = match lock(&self.slots) {
            Ok(s) => s.values().cloned().collect(),
            Err(_) => return 0,
        };
        slots.iter().filter_map(|s| s.lock().ok()).map(|s| s.desktop.resident_bytes()).sum()
    }

    /// Over budget: LRU suspended slots go down a tier until under it.
    pub fn enforce_budget(self: &Arc<Self>) {
        let budget = self.budget_bytes();
        if self.resident_total() <= budget {
            return;
        }
        let mut candidates: Vec<(Instant, String, Option<String>)> = match lock(&self.slots) {
            Ok(slots) => slots
                .iter()
                .filter_map(|(id, s)| {
                    let s = s.try_lock().ok()?;
                    (s.state == State::Suspended)
                        .then(|| (s.last_used, id.clone(), s.owner.clone()))
                })
                .collect(),
            Err(_) => return,
        };
        candidates.sort();
        for (_, id, owner) in candidates {
            if self.resident_total() <= budget {
                break;
            }
            if owner.is_none() {
                // Only a slot still waiting in the warm set: one popped for a lease is spoken for.
                let was_warm = lock(&self.warm).is_ok_and(|mut warm| {
                    let n = warm.len();
                    warm.retain(|w| w != &id);
                    warm.len() != n
                });
                if was_warm
                    && let Ok(mut slots) = lock(&self.slots)
                    && let Some(slot) = slots.remove(&id)
                    && let Ok(mut s) = slot.lock()
                {
                    s.desktop.destroy();
                }
            } else if let Ok(slot) = self.slot(&id)
                && let Ok(mut s) = slot.lock()
                && s.state == State::Suspended
            {
                match s.desktop.evict() {
                    Ok(r) => {
                        s.state = State::Evicted;
                        s.last_suspend = Some(r);
                    }
                    Err(e) => eprintln!("desktop-lease: evicting {id} failed: {e:#}"),
                }
            }
        }
    }

    pub fn stats(&self) -> serde_json::Value {
        let slots: Vec<(String, Arc<Mutex<Slot>>)> = match lock(&self.slots) {
            Ok(s) => s.iter().map(|(k, v)| (k.clone(), Arc::clone(v))).collect(),
            Err(_) => vec![],
        };
        let rows: Vec<_> = slots
            .iter()
            .filter_map(|(id, s)| {
                let s = s.lock().ok()?;
                Some(serde_json::json!({
                    "slot": id,
                    "state": s.state,
                    "owner": s.owner,
                    "backend": s.spec.backend,
                    "resident_mb": s.desktop.resident_bytes() as f64 / MB,
                    "idle_s": s.last_used.elapsed().as_secs_f64(),
                    "owner_record": s.desktop.owner_record(),
                }))
            })
            .collect();
        serde_json::json!({
            "slots": rows,
            "warm": lock(&self.warm).map(|w| w.len()).unwrap_or(0),
            "resident_total_mb": self.resident_total() as f64 / MB,
            "budget_mb": self.budget_mb.load(Ordering::Relaxed),
        })
    }

    /// Destroy every slot (shutdown).
    pub fn destroy_all(&self) {
        let slots: Vec<_> = match lock(&self.slots) {
            Ok(mut s) => s.drain().map(|(_, v)| v).collect(),
            Err(_) => return,
        };
        if let Ok(mut w) = lock(&self.warm) {
            w.clear();
        }
        for slot in slots {
            if let Ok(mut s) = slot.lock() {
                s.desktop.destroy();
            }
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> Result<std::sync::MutexGuard<'_, T>> {
    m.lock().map_err(|_| anyhow!("pool lock poisoned"))
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

#[cfg(test)]
mod tests;

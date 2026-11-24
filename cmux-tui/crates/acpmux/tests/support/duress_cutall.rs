//! The duress bench's cut-all legs (included by `duress_host150.rs`; see `duress_daemon.rs` for how
//! to run it).
//!
//! Why (Leo, 2026-11-24, ask ee32c80a2c): "under extreme conditions, extreme duress, we need to
//! chug along swimmingly. so. we need to be able to auto bundle, auto batch, auto connect far
//! better." A relay blip or the daemon's own stall drops every peer link in the same moment; the
//! host-wide dial gate (`src/peer_dial_gate.rs`: [`SLOTS`] at once, the rest spread over
//! [`SPREAD`]) is what keeps that from being N dials in one instant on a host at load 150.
//!
//! - `cutall` (expands to `cutall1`, `cutall10`, `cutall20`, `cutall40`): the baseline leg at N
//!   peers; once every link reads connected, every proxy's links are cut in the same instant (the
//!   proxies keep accepting), and the leg records the dials in the first second after the cut
//!   (proxy accepts, beside the gate's bound), when each peer redialed and read connected again,
//!   the worst presence gap and the peers over 2 s, and the daemon's own link gauges.
//! - `cutallload` (`cutallload1` ... `cutallload40`): the same under host150's load (busy loops
//!   at 10 x cores, the fork storm, the daemon under `MemoryHigh`).
//!
//! The row gains `cutAll`, and each leg prints `CUTALL <json>`.
use super::*;

pub(crate) const LEG: &str = "cutall";
pub(crate) const LOAD_LEG: &str = "cutallload";
/// The gate's numbers (`src/peer_dial_gate.rs`), for the bound the row states beside the count.
const SLOTS: usize = 6;
const SPREAD: Duration = Duration::from_millis(1500);
/// How long the links have to all read connected before the cut, and the peers to come back after.
const READY_BY: Duration = Duration::from_secs(90);
const BACK_BY: Duration = Duration::from_secs(60);
/// The presence sampler's period after the cut: 10 Hz, so a gap is known to 100 ms.
const SAMPLE: Duration = Duration::from_millis(100);
/// The dial counter's period: proxy accepts are read every 20 ms, off the socket's thread.
const DIAL_SAMPLE: Duration = Duration::from_millis(20);
const GAP_OVER_MS: f64 = 2000.0;

/// `cutallN` or `cutallloadN`: N.
pub(crate) fn n(leg: &str) -> Option<usize> {
    leg.strip_prefix(LOAD_LEG).or_else(|| leg.strip_prefix(LEG))?.parse().ok()
}

/// Whether the leg runs under host150's load.
pub(crate) fn loaded(leg: &str) -> bool {
    leg.strip_prefix(LOAD_LEG).is_some_and(|rest| rest.parse::<usize>().is_ok())
}

/// The most dials the gate lets through in the first second after N links dropped together: its
/// slots at once, and the share of the rest whose spread start falls in that second.
pub(crate) fn first_second_bound(n: usize) -> usize {
    let rest = n.saturating_sub(SLOTS);
    SLOTS.min(n) + (rest as f64 * (1.0 / SPREAD.as_secs_f64())).ceil() as usize
}

/// One proxy's links (to cut) and counters (to read), `peerNN` at index NN.
pub(crate) struct CutHandle {
    pub links: Arc<Mutex<Vec<tokio::task::AbortHandle>>>,
    pub wire: Arc<Wire>,
}

pub(crate) struct CutAll {
    thread: std::thread::JoinHandle<Value>,
}

fn peer_states(r: &mut Rpc) -> Result<BTreeMap<String, String>, String> {
    let v = r.call("_acpmux/peers", json!({}), Duration::from_secs(5))?;
    Ok(v["peers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| {
            let state = p["state"].as_str().map(str::to_owned).unwrap_or_else(|| {
                if p["connected"].as_bool() == Some(true) { "connected" } else { "offline" }.into()
            });
            Some((p["name"].as_str()?.to_owned(), state))
        })
        .collect())
}

fn is_up(state: Option<&String>) -> bool {
    state.is_some_and(|s| s == "connected" || s == "degraded")
}

impl CutAll {
    /// Waits for every peer's link to read connected, cuts them all at once, and measures until
    /// every peer is back or [`BACK_BY`]. Runs beside the leg's window.
    pub(crate) fn start(socket: &Path, handles: Vec<CutHandle>, names: Vec<String>) -> Self {
        let socket = socket.to_path_buf();
        let thread = std::thread::spawn(move || run(&socket, &handles, &names));
        Self { thread }
    }

    pub(crate) fn join(self) -> Value {
        self.thread.join().unwrap_or_else(|_| json!({"error": "the cut-all thread panicked"}))
    }
}

fn run(socket: &Path, handles: &[CutHandle], names: &[String]) -> Value {
    let n = names.len();
    let mut r = match Rpc::connect(socket) {
        Ok(r) => r,
        Err(e) => return json!({"error": format!("socket: {e}")}),
    };
    // Every link ready first: the cut is of N live links, not of dials still in flight.
    let asked = Instant::now();
    let mut last = BTreeMap::new();
    loop {
        if let Ok(states) = peer_states(&mut r) {
            if names.iter().all(|p| is_up(states.get(p))) {
                break;
            }
            last = states;
        }
        if asked.elapsed() > READY_BY {
            let down: Vec<String> =
                names.iter().filter(|p| !is_up(last.get(*p))).cloned().collect();
            return json!({"error": format!("{} of {n} links never read connected before the cut", down.len()),
                          "down": down});
        }
        std::thread::sleep(SAMPLE);
    }
    let ready_ms = ms_f(asked.elapsed());
    let gauges_before = link_gauges(socket);
    let accepts = |h: &CutHandle| h.wire.accepts.load(Ordering::Relaxed);
    let before: Vec<u64> = handles.iter().map(accepts).collect();

    // The cut: every proxy's links in the same instant; the proxies keep accepting.
    let cut_at = Instant::now();
    for h in handles {
        for link in h.links.lock().unwrap().drain(..) {
            link.abort();
        }
    }

    // Dials (proxy accepts) on their own thread at 50 Hz, so a slow socket read under load
    // cannot blur the first second; each peer's first redial time with them.
    let stop = Arc::new(AtomicBool::new(false));
    let counters: Vec<Arc<Wire>> = handles.iter().map(|h| h.wire.clone()).collect();
    let dial_thread = {
        let (stop, before) = (stop.clone(), before.clone());
        std::thread::spawn(move || {
            let mut series: Vec<(f64, u64)> = vec![];
            let mut first_redial: Vec<Option<f64>> = vec![None; counters.len()];
            loop {
                let at = ms_f(cut_at.elapsed());
                let mut total = 0;
                for (i, w) in counters.iter().enumerate() {
                    let d = w.accepts.load(Ordering::Relaxed) - before[i];
                    total += d;
                    if d > 0 && first_redial[i].is_none() {
                        first_redial[i] = Some(at);
                    }
                }
                series.push((at, total));
                if stop.load(Ordering::SeqCst) {
                    return (series, first_redial);
                }
                std::thread::sleep(DIAL_SAMPLE);
            }
        })
    };

    // Presence at 10 Hz: per peer, when it first read down and when it read up again after its
    // redial (a peer whose drop fell between two samples reads a gap under one period).
    let mut down_at: Vec<Option<f64>> = vec![None; n];
    let mut back_at: Vec<Option<f64>> = vec![None; n];
    let mut gap: Vec<f64> = vec![0.0; n];
    let mut reads = 0u64;
    let mut read_errors = 0u64;
    let mut read_max_ms = 0f64;
    let mut gauges_1s: Option<(f64, Value)> = None;
    while cut_at.elapsed() < BACK_BY {
        let tick = Instant::now();
        let at = ms_f(cut_at.elapsed());
        if gauges_1s.is_none() && at >= 1000.0 {
            gauges_1s = link_gauges(socket).map(|g| (ms_f(cut_at.elapsed()), g));
        }
        match peer_states(&mut r) {
            Ok(states) => {
                reads += 1;
                read_max_ms = read_max_ms.max(ms_f(tick.elapsed()));
                for (i, p) in names.iter().enumerate() {
                    let up = is_up(states.get(p));
                    let redialed = handles[i].wire.accepts.load(Ordering::Relaxed) > before[i];
                    if !up && down_at[i].is_none() {
                        down_at[i] = Some(at);
                    }
                    if up && redialed && back_at[i].is_none() {
                        back_at[i] = Some(at);
                        if let Some(d) = down_at[i] {
                            gap[i] = at - d;
                        }
                    }
                }
            }
            Err(_) => {
                read_errors += 1;
                if let Ok(again) = Rpc::connect(socket) {
                    r = again;
                }
            }
        }
        if back_at.iter().all(Option::is_some) {
            break;
        }
        if let Some(rest) = SAMPLE.checked_sub(tick.elapsed()) {
            std::thread::sleep(rest);
        }
    }
    let end_ms = ms_f(cut_at.elapsed());
    // A peer still down at the end: its gap runs to the end.
    for i in 0..n {
        if back_at[i].is_none() {
            gap[i] = end_ms - down_at[i].unwrap_or(0.0);
        }
    }
    stop.store(true, Ordering::SeqCst);
    let (series, first_redial) = dial_thread.join().unwrap_or_default();
    let dials_by =
        |ms: f64| series.iter().take_while(|(at, _)| *at <= ms).last().map_or(0, |s| s.1);
    let gauges_after = link_gauges(socket);
    let delta = |a: &Option<Value>, b: &Option<Value>| -> Value {
        match (a, b) {
            (Some(a), Some(b)) => b
                .as_object()
                .into_iter()
                .flatten()
                .filter_map(|(k, v)| Some((k.clone(), json!(v.as_i64()? - a.get(k)?.as_i64()?))))
                .collect::<serde_json::Map<_, _>>()
                .into(),
            _ => json!("no gauges.links in this build"),
        }
    };
    let worst = gap.iter().copied().fold(0.0, f64::max);
    let over = gap.iter().filter(|g| **g > GAP_OVER_MS).count();
    let reconnected = back_at.iter().filter(|b| b.is_some()).count();
    let back_worst = back_at.iter().flatten().copied().fold(0.0, f64::max);
    let per_peer: serde_json::Map<String, Value> = names
        .iter()
        .enumerate()
        .map(|(i, p)| {
            (
                p.clone(),
                json!({"downAtMs": down_at[i], "redialAtMs": first_redial.get(i).copied().flatten(),
                       "backAtMs": back_at[i], "gapMs": gap[i],
                       "dials": handles[i].wire.accepts.load(Ordering::Relaxed) - before[i]}),
            )
        })
        .collect();
    let out = json!({
        "peers": n,
        "readyBeforeCutMs": ready_ms,
        "dialsFirstSecond": dials_by(1000.0),
        "dialsFirstSecondBound": first_second_bound(n),
        "dialsFirst500ms": dials_by(500.0),
        "dialsFirst2s": dials_by(2000.0),
        "dialsTotal": series.last().map_or(0, |s| s.1),
        "reconnected": reconnected,
        "allReconnected": reconnected == n,
        "allBackMs": (reconnected == n).then_some(back_worst),
        "presenceGapWorstMs": worst,
        "peersOver2s": over,
        "sampleMs": ms_f(SAMPLE),
        "reads": reads, "readErrors": read_errors, "readMaxMs": read_max_ms,
        "gaugesAt1s": gauges_1s.as_ref().map(|(at, g)| json!({"atMs": at, "delta": delta(&gauges_before, &Some(g.clone()))})),
        "gaugesDelta": delta(&gauges_before, &gauges_after),
        "perPeer": per_peer,
    });
    println!(
        "CUTALL {}",
        json!({
            "peers": n, "dialsFirstSecond": out["dialsFirstSecond"], "bound": out["dialsFirstSecondBound"],
            "reconnected": reconnected, "allBackMs": out["allBackMs"], "presenceGapWorstMs": worst,
            "peersOver2s": over, "gaugesDelta": out["gaugesDelta"],
        })
    );
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cutall_names_and_bound() {
        assert_eq!(n("cutall40"), Some(40));
        assert_eq!(n("cutallload10"), Some(10));
        assert_eq!(n("cutall"), None);
        assert!(loaded("cutallload1"));
        assert!(!loaded("cutall1"));
        assert_eq!(first_second_bound(1), 1);
        assert_eq!(first_second_bound(6), 6);
        // 34 spread over 1.5 s: 23 of them start in the first second.
        assert_eq!(first_second_bound(40), 6 + 23);
    }
}

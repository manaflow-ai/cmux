//! The carrier's kept circuits: a stream on a kept circuit (opened first if none), reopening
//! the ones that close, and cutting or counting them, split from `hub_carrier.rs`.

use super::*;

impl HubCarrier {
    /// A stream on the `lane` kept circuit to `daemon`, opening that circuit first if there is
    /// none. A circuit that fails under the open is dropped and opened again, once.
    async fn kept_open(
        &self,
        daemon: &str,
        lane: CircuitLane,
        hello: Bytes,
        early: &[u8],
        report: &mut DialReport,
        path: Path,
    ) -> KeptOpen {
        let slot = match path {
            Path::Relay => self.kept.slot(daemon, lane),
            Path::Direct(_) | Path::Punched => self.direct.kept.slot(daemon, lane),
        };
        let mut why = String::new();
        for _ in 0..2 {
            let mux = {
                let mut kept = slot.lock().await;
                match kept.live.clone().filter(|mux| !mux.is_closed()) {
                    Some(mux) => mux,
                    None => {
                        if kept.no_mux_until.is_some_and(|until| Instant::now() < until) {
                            return KeptOpen::Plain("the machine keeps no circuits".into());
                        }
                        // Parallel dials wait here on this one open, not on one each. Never a
                        // plain dial beside it: a service hello can ask the far machine's owner
                        // for consent, and one dial asks once.
                        let (mux, said, mut stages) = match self.open_kept(daemon, lane, path).await
                        {
                            Ok(opened) => opened,
                            Err(e) => return KeptOpen::Failed(e),
                        };
                        // This dial's OPEN goes right behind the `mux` hello, not after its
                        // answer: a new kept circuit costs no more round trips than a plain one.
                        let asked = Instant::now();
                        let wait = self.timings.handshake;
                        let (first, said) = tokio::join!(
                            mux.open(hello.clone(), early, wait),
                            tokio::time::timeout(wait, said)
                        );
                        stages.answer = asked.elapsed();
                        stages.log(daemon, lane.name());
                        *report = DialReport {
                            kept: false,
                            circuit: Some(stages),
                            stream: Duration::ZERO,
                            via: direct::Via::Hub,
                            early: early.len(),
                        };
                        let early_out = first.as_ref().err().is_some_and(|e| e.early_out);
                        match said {
                            Ok(Ok(Ok(()))) => {
                                self.stats.kept_circuits.fetch_add(1, Ordering::Relaxed);
                                kept.live = Some(mux.clone());
                                kept.path = Some(path);
                                kept.reopen_at = None;
                            }
                            // The far machine refused the `mux` hello before reading any
                            // stream: early bytes behind it were never read.
                            Ok(Ok(Err(refusal))) => {
                                mux.close().await;
                                tracing::debug!(
                                    "hub carrier: the machine keeps no circuits: {refusal}"
                                );
                                kept.no_mux_until = Some(Instant::now() + mux::NO_MUX_ASK_AGAIN);
                                return KeptOpen::Plain("the machine keeps no circuits".into());
                            }
                            Ok(Err(_)) | Err(_) => {
                                mux.close().await;
                                let why = mux.ended().unwrap_or_else(|| {
                                    "the machine did not answer the kept circuit's hello".into()
                                });
                                return if early_out {
                                    KeptOpen::Lost(why)
                                } else {
                                    KeptOpen::Failed(why)
                                };
                            }
                        }
                        match first {
                            Ok(Ok(stream)) => {
                                record_call(lane, false);
                                return KeptOpen::Stream(stream);
                            }
                            Ok(Err(refusal)) => return KeptOpen::Refused(refusal),
                            Err(e) if e.early_out => {
                                mux.close().await;
                                return KeptOpen::Lost(e.why);
                            }
                            Err(e) => {
                                mux.close().await;
                                why = e.why;
                                continue;
                            }
                        }
                    }
                }
            };
            let asked = Instant::now();
            let opened = mux.open(hello.clone(), early, self.timings.handshake).await;
            *report = DialReport {
                kept: true,
                circuit: None,
                stream: asked.elapsed(),
                via: direct::Via::Hub,
                early: early.len(),
            };
            if matches!(opened, Ok(Ok(_))) {
                crate::gauges::carrier::global().kept_stream(report.stream);
                record_call(lane, true);
            }
            match opened {
                Ok(Ok(stream)) => return KeptOpen::Stream(stream),
                Ok(Err(refusal)) => return KeptOpen::Refused(refusal),
                Err(e) if e.early_out => {
                    tracing::info!(
                        "hub carrier: a kept circuit failed after a stream's first bytes left \
                         ({}); not sent again",
                        e.why
                    );
                    mux.close().await;
                    return KeptOpen::Lost(e.why);
                }
                Err(e) => {
                    let e = e.why;
                    tracing::info!(
                        "hub carrier: a kept circuit failed under a dial ({e}); opening it again"
                    );
                    mux.close().await;
                    why = e;
                }
            }
        }
        KeptOpen::Plain(format!("the kept circuit failed twice: {why}"))
    }

    /// The direct path's answer for a dial to `daemon` (`hub_carrier_direct.rs`), when it
    /// decides it: a stream on the kept direct circuit, or the far machine's own refusal. None
    /// (no direct address, or the path failed, which holds the machine off it a while): the
    /// relay.
    async fn direct_open(
        &self,
        daemon: &str,
        lane: CircuitLane,
        hello: Bytes,
        early: &[u8],
        report: &mut DialReport,
    ) -> Option<KeptOpen> {
        // A private route first; else a punched connection (`hub_carrier_punch.rs`), which a
        // first dial never waits for: it starts one and rides the relay.
        let path = match self.direct_address(daemon).await {
            Some(address) => Path::Direct(address),
            None => self.punch_path(daemon, lane)?,
        };
        let address = path;
        let miss = |carrier: &Self| match path {
            Path::Punched => carrier.direct.punch.miss(daemon),
            _ => carrier.direct.miss(daemon),
        };
        match self.kept_open(daemon, lane, hello, early, report, path).await {
            KeptOpen::Stream(stream) => {
                report.via = direct::Via::Direct;
                Some(KeptOpen::Stream(stream))
            }
            KeptOpen::Refused(refusal) if refusal.reason != "service.unknown" => {
                Some(KeptOpen::Refused(refusal))
            }
            // The far service may have read the early bytes: no relay dial repeats them.
            KeptOpen::Lost(why) => {
                tracing::info!("hub carrier direct: {address:?} failed ({why}) after early bytes");
                miss(self);
                Some(KeptOpen::Lost(why))
            }
            KeptOpen::Refused(refusal) => {
                tracing::debug!("hub carrier direct: {address:?} refused: {refusal}; the relay");
                miss(self);
                *report = DialReport::default();
                None
            }
            KeptOpen::Failed(why) | KeptOpen::Plain(why) => {
                tracing::info!("hub carrier direct: {address:?} failed ({why}); the relay");
                miss(self);
                *report = DialReport::default();
                None
            }
        }
    }

    /// Open a kept circuit to `daemon`: a circuit whose first record is the `mux` hello, its
    /// dialer's end running. The answer comes on `said` (a machine whose acpmux predates kept
    /// circuits refuses it, `service.unknown`, and closes the circuit).
    async fn open_kept(
        &self,
        daemon: &str,
        lane: CircuitLane,
        path: Path,
    ) -> Result<(Arc<mux::Mux>, mux::HelloAnswer, DialStages), String> {
        crate::gauges::bump(&crate::gauges::links().hub_kept_dials);
        let (secure, stages) = match path {
            Path::Relay => self.open_circuit(daemon).await?,
            Path::Direct(address) => self.open_direct(daemon, address).await?,
            Path::Punched => self.open_punched(daemon, lane).await?,
        };
        secure.send(mux::mux_hello()).await.map_err(|e| e.to_string())?;
        let (mux, said) = mux::start_dialer(
            Box::new(secure),
            self.stats.clone(),
            Arc::downgrade(&self.alive),
            self.timings.keepalive,
            self.timings.kept_idle,
        );
        Ok((mux, said, stages))
    }

    /// Keep every kept circuit open (Leo, 2026-11-25: "small, chatty calls stay on whichever
    /// machine holds the files, batched over one always-open connection, never a new connection
    /// per call"): every [`REOPEN_SCAN`], open again each kept circuit that ended under this
    /// carrier (the far machine restarted, the relay or the hub dropped it, the keepalive heard
    /// nothing), rather than leave the next dial a whole new circuit (0.5 to 0.9 s against a
    /// stream's 0.07 s). Ends with the carrier. A circuit closed on purpose (no stream for
    /// `kept_idle`) is not opened again, and one whose machine stays away is given up once it
    /// would have idled out anyway.
    pub fn keep_reopening(self: &Arc<Self>) {
        let carrier = Arc::downgrade(self);
        mux::spawn_reopening(async move {
            loop {
                tokio::time::sleep(REOPEN_SCAN).await;
                let Some(carrier) = carrier.upgrade() else { return };
                carrier.reopen_closed().await;
            }
        });
    }

    /// One pass of [`Self::keep_reopening`]: every machine at once, each slot locked while its
    /// circuit opens, so a dial to that machine waits on this open rather than racing it.
    pub async fn reopen_closed(&self) -> usize {
        let slots: Vec<_> =
            self.kept.to_reopen().into_iter().chain(self.direct.kept.to_reopen()).collect();
        let opened =
            futures::future::join_all(slots.into_iter().map(|(daemon, lane, slot)| async move {
                self.reopen(&daemon, lane, &slot).await
            }))
            .await;
        opened.into_iter().filter(|opened| *opened).count()
    }

    async fn reopen(
        &self,
        daemon: &str,
        lane: CircuitLane,
        slot: &tokio::sync::Mutex<mux::Kept>,
    ) -> bool {
        let mut kept = slot.lock().await;
        let Some(old) = kept.live.clone().filter(|mux| mux.wants_reopen()) else { return false };
        if kept.reopen_at.is_some_and(|at| Instant::now() < at) {
            return false;
        }
        let Some(path) = kept.path else { return false };
        if old.quiet_for() >= self.timings.kept_idle {
            kept.live = None;
            return false;
        }
        let why = match self.open_kept(daemon, lane, path).await {
            Ok((mux, said, _)) => match tokio::time::timeout(self.timings.handshake, said).await {
                Ok(Ok(Ok(()))) => {
                    self.stats.kept_circuits.fetch_add(1, Ordering::Relaxed);
                    self.stats.kept_reopens.fetch_add(1, Ordering::Relaxed);
                    tracing::info!(daemon, ?path, "hub carrier: opened a kept circuit again");
                    kept.live = Some(mux);
                    kept.reopen_at = None;
                    kept.reopen_wait = Duration::ZERO;
                    return true;
                }
                Ok(Ok(Err(refusal))) => {
                    mux.close().await;
                    kept.live = None;
                    kept.no_mux_until = Some(Instant::now() + mux::NO_MUX_ASK_AGAIN);
                    tracing::info!(
                        daemon,
                        "hub carrier: the machine keeps no circuits now: {refusal}"
                    );
                    return false;
                }
                Ok(Err(_)) | Err(_) => {
                    mux.close().await;
                    mux.ended().unwrap_or_else(|| "no answer to the `mux` hello".into())
                }
            },
            Err(e) => e,
        };
        kept.reopen_wait =
            (kept.reopen_wait * 2).clamp(mux::REOPEN_BACKOFF_MIN, mux::REOPEN_BACKOFF_MAX);
        kept.reopen_at = Some(Instant::now() + kept.reopen_wait);
        tracing::debug!(
            daemon,
            "hub carrier: a kept circuit did not open again ({why}); next try in {:?}",
            kept.reopen_wait
        );
        false
    }

    /// `false` answers a kept circuit's hello as an acpmux that predates kept circuits does
    /// (`service.unknown`), so a test can check that a dialer falls back to plain circuits.
    #[doc(hidden)]
    pub fn serve_kept_circuits(&self, on: bool) {
        self.serves_kept.store(on, Ordering::SeqCst);
    }

    /// `false` dials and serves acpmux links as a daemon from before they rode kept circuits:
    /// dials go plain with no hello, and a kept circuit's acpmux stream is refused
    /// `service.unknown`. Tests use it to check that new and old daemons still talk both ways.
    #[doc(hidden)]
    pub fn acpmux_streams(&self, on: bool) {
        self.acpmux_streams.store(on, Ordering::SeqCst);
    }

    /// Whether a kept circuit to `daemon` is open now, and how many streams ride its kept
    /// circuits (the cheap one and the bulk one).
    pub fn kept_streams(&self, daemon: &str) -> Option<usize> {
        let live = self.kept.live(daemon);
        (!live.is_empty()).then(|| live.iter().map(|mux| mux.streams()).sum())
    }

    /// How many kept circuits to `daemon` are open now (at most one per lane).
    pub fn kept_circuits(&self, daemon: &str) -> usize {
        self.kept.live(daemon).len()
    }

    /// Cut the kept circuit to `daemon` under its streams, as a relay drop would (tests, and a
    /// caller that knows the path changed).
    pub async fn cut_kept(&self, daemon: &str) -> bool {
        let live = self.kept.live(daemon);
        for mux in &live {
            mux.close().await;
        }
        !live.is_empty()
    }

    /// A link to `daemon` that rode a kept circuit ended after `silent` with no byte in (a peer
    /// link dropped for silence): close each kept circuit to `daemon` that heard nothing in that
    /// window either. The link pinged across it the whole time, so it is dead, and the redial
    /// opens a fresh circuit at once instead of spending [`mux::ANSWER_SUSPECT`] on an OPEN that
    /// cannot be answered. A circuit that heard anything in the window (another stream's bytes,
    /// a keepalive PONG) is alive and kept. Under `ANSWER_SUSPECT` of silence the link proved no
    /// more than an OPEN would, so nothing is closed. Returns how many circuits it closed.
    pub async fn close_kept_silent_for(&self, daemon: &str, silent: Duration) -> usize {
        if silent < mux::ANSWER_SUSPECT {
            return 0;
        }
        let dead: Vec<_> = [&self.kept, &self.direct.kept]
            .into_iter()
            .flat_map(|kept| kept.silent_for(daemon, silent))
            .collect();
        for mux in &dead {
            tracing::info!(
                "hub carrier: a link on a kept circuit heard nothing for {}ms, nor did the circuit; closing it so the redial opens a new one",
                silent.as_millis()
            );
            mux.close().await;
        }
        dead.len()
    }
}

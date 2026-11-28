//! The VM side: watches its folder, reports what changed (batched), serves the leader's fetches
//! and applies its writes compare-and-swap. It decides nothing; the leader runs every round.
//! One [`serve`] lasts one connection; the caller serves the next dial the same way, and each
//! connection starts with the whole manifest, so whatever changed while the link was down (a
//! pause, a dropped network, a sleeping Mac) is caught up in the first round.

use std::collections::BTreeSet;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, unbounded};

use crate::proto::{self, Item, Msg, WireOp};
use crate::replica::{Outcome, Replica};
use crate::state::State;
use crate::watch::{Seen, Watch};
use crate::{DEBOUNCE_MAX, DEBOUNCE_QUIET, IDLE_DROP};

enum In {
    Frame(Msg, Vec<u8>),
    Closed(String),
    Watch(Seen),
}

/// A follower's folder, kept between connections so its index is not rebuilt per dial.
pub struct Follower {
    replica: Replica,
    state: State,
    watch_rx: Receiver<In>,
    _watch: Option<Watch>,
    alerts: Vec<String>,
}

impl Follower {
    pub fn new(root: impl Into<PathBuf>, state_dir: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let mut replica = Replica::new(root)?;
        let state = State::open(state_dir)?;
        let (tx, rx) = unbounded();
        let mut alerts = vec![];
        let watch = match Watch::start(replica.root(), tx, In::Watch) {
            Ok(w) => Some(w),
            Err(e) => {
                alerts.push(format!(
                    "follower watcher failed, rescanning on every ping: {}",
                    crate::replica::first_line(&e.to_string())
                ));
                None
            }
        };
        replica.full_scan();
        Ok(Self { replica, state, watch_rx: rx, _watch: watch, alerts })
    }

    /// Serves one connection until it closes or goes silent past [`IDLE_DROP`].
    pub fn serve(
        &mut self,
        reader: impl Read + Send + 'static,
        writer: impl Write,
    ) -> anyhow::Result<()> {
        let mut w = BufWriter::new(writer);
        let (tx, rx) = unbounded::<In>();
        std::thread::spawn(move || {
            let mut r = BufReader::new(reader);
            loop {
                match proto::read_frame(&mut r) {
                    Ok((m, b)) => {
                        if tx.send(In::Frame(m, b)).is_err() {
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(In::Closed(e.to_string()));
                        return;
                    }
                }
            }
        });
        // Whatever the watcher queued before this connection is covered by the full scan below.
        while self.watch_rx.try_recv().is_ok() {}
        self.replica.full_scan();
        let (synced, tree) = match self.state.load() {
            Ok(t) => t,
            Err(e) => {
                self.alerts.push(format!(
                    "VM synced copy unreadable, not offered: {}",
                    crate::replica::first_line(&format!("{e:#}"))
                ));
                (None, Default::default())
            }
        };
        proto::write_frame(
            &mut w,
            &Msg::Hello { protocol: proto::PROTOCOL, synced: synced.clone() },
            &[],
        )?;
        if let Some(id) = synced {
            proto::write_frame(
                &mut w,
                &Msg::SyncedTree { id, tree: tree.into_iter().collect() },
                &[],
            )?;
        }
        self.send_state(&mut w, true, BTreeSet::new())?;

        let mut dirty: BTreeSet<String> = BTreeSet::new();
        let mut first_dirty: Option<Instant> = None;
        let mut last_dirty = Instant::now();
        let mut last_heard = Instant::now();
        let watch_rx = self.watch_rx.clone();
        loop {
            let wait = match first_dirty {
                Some(first) => {
                    let quiet = DEBOUNCE_QUIET.saturating_sub(last_dirty.elapsed());
                    let max = DEBOUNCE_MAX.saturating_sub(first.elapsed());
                    quiet.min(max)
                }
                None => Duration::from_secs(1),
            };
            let got = crossbeam_channel::select! {
                recv(rx) -> m => m.ok(),
                recv(watch_rx) -> m => m.ok(),
                default(wait) => None,
            };
            match got {
                Some(In::Frame(msg, body)) => {
                    last_heard = Instant::now();
                    self.handle(&mut w, msg, &body)?;
                }
                Some(In::Closed(why)) => return Err(anyhow::anyhow!("link closed: {why}")),
                Some(In::Watch(Seen::Paths(paths))) => {
                    for p in paths {
                        if let Some(rel) = self.replica.relative(&p) {
                            dirty.insert(rel);
                        }
                    }
                    first_dirty.get_or_insert_with(Instant::now);
                    last_dirty = Instant::now();
                }
                Some(In::Watch(Seen::Rescan(why))) => {
                    self.alerts.push(why);
                    let changed = self.replica.full_scan();
                    dirty.extend(changed);
                    first_dirty.get_or_insert_with(Instant::now);
                }
                None => {}
            }
            if first_dirty.is_some_and(|f| {
                last_dirty.elapsed() >= DEBOUNCE_QUIET || f.elapsed() >= DEBOUNCE_MAX
            }) {
                let named = std::mem::take(&mut dirty);
                let changed = self.replica.rescan_paths(named);
                first_dirty = None;
                if !changed.is_empty() || !self.alerts.is_empty() || !self.replica.alerts.is_empty()
                {
                    self.send_state(&mut w, false, changed)?;
                }
            }
            if last_heard.elapsed() > IDLE_DROP {
                return Err(anyhow::anyhow!("link silent for {} s", IDLE_DROP.as_secs()));
            }
        }
    }

    fn send_state(
        &mut self,
        w: &mut impl Write,
        full: bool,
        paths: BTreeSet<String>,
    ) -> anyhow::Result<()> {
        let entries: Vec<(String, Option<String>)> = if full {
            self.replica.tree().into_iter().map(|(p, h)| (p, Some(h))).collect()
        } else {
            paths
                .into_iter()
                .map(|p| {
                    let h = self.replica.get(&p).cloned();
                    (p, h)
                })
                .collect()
        };
        let mut alerts = std::mem::take(&mut self.alerts);
        alerts.append(&mut self.replica.alerts);
        proto::write_frame(w, &Msg::State { full, entries, alerts }, &[])?;
        Ok(())
    }

    fn handle(&mut self, w: &mut impl Write, msg: Msg, body: &[u8]) -> anyhow::Result<()> {
        match msg {
            Msg::Ping => proto::write_frame(w, &Msg::Pong, &[])?,
            Msg::Fetch { id, paths } => {
                let mut items = vec![];
                let mut out = vec![];
                for p in paths {
                    match self.replica.read(&p) {
                        Ok(Some((hash, bytes))) => {
                            items.push(Item { path: p, hash: Some(hash), len: bytes.len() as u64 });
                            out.extend_from_slice(&bytes);
                        }
                        _ => items.push(Item { path: p, hash: None, len: 0 }),
                    }
                }
                proto::write_frame(w, &Msg::Blobs { id, items }, &out)?;
            }
            Msg::Apply { id, ops } => {
                let lens = ops.iter().map(|op| match op {
                    WireOp::Write { len, .. } => *len,
                    WireOp::Delete { .. } => 0,
                });
                let parts = proto::split_body(body, lens)?;
                let outcomes: Vec<Outcome> = ops
                    .iter()
                    .zip(parts)
                    .map(|(op, bytes)| match op {
                        WireOp::Write { path, expect, hash, .. } => {
                            self.replica.write(path, expect.as_deref(), hash, bytes)
                        }
                        WireOp::Delete { path, expect } => self.replica.delete(path, expect),
                    })
                    .collect();
                proto::write_frame(w, &Msg::Applied { id, outcomes }, &[])?;
            }
            Msg::Synced { changes, .. } => {
                let (_, mut tree) = self.state.load().unwrap_or((None, Default::default()));
                for (p, h) in changes {
                    match h {
                        Some(h) => tree.insert(p, h),
                        None => tree.remove(&p),
                    };
                }
                self.state.commit(&tree);
            }
            Msg::SyncedTree { tree, .. } => {
                self.state.commit(&tree.into_iter().collect());
            }
            Msg::Hello { .. }
            | Msg::Pong
            | Msg::State { .. }
            | Msg::Blobs { .. }
            | Msg::Applied { .. } => {}
        }
        Ok(())
    }
}

//! `coord-sim gen`: N synthetic coordinator chats drawn from a shape, as scripts (`event.rs` SimEvent
//! NDJSON, one per coordinator) and/or as acpmux session directories a real daemon opens.
//!
//!   coord-sim gen --out DIR [--shape FILE] [--seed N] [--coordinators N] [--events N] [--scale X]
//!                 [--format script|acpmux|both] [--peak N] [--bytes SIZE] [--harness claude|codex]
//!                 [--max-line SIZE] [--segment-bytes SIZE] [--start-ms MS]
//!   coord-sim gen --check PROBE.json|ACPMUX_HOME --out DIR [--shape FILE]   compare a probe of the run
//!                 (`coord_shape_probe.py`'s JSON, or the home measured in-process) with the shape
//!
//! `--events` is per coordinator (default: drawn from `per_session.events`); `--scale` multiplies the
//! drawn event count, peak and every size, so one chat reaches multi-GB (`--bytes` stops each chat once
//! its lines reach SIZE). Output:
//!   DIR/coord-<i>.ndjson                                          (script)
//!   DIR/acpmux-home/sessions/<id>/session.json, events/NNNNNN.ndjson  (acpmux: ACPMUX_HOME=DIR/acpmux-home)
//!   DIR/acpmux-home/attachments/<sha256>                       (acpmux, the prompts' images)
//!   DIR/manifest.json                                             (what each coordinator was drawn as)
//! Memory stays constant whatever the size: every line streams to its file, its filler copied in
//! chunks. The same seed makes the same bytes.

mod fidelity;
mod plan;
mod render;
mod sha256;
mod sink;

use crate::event::{Op, SimEvent};
use crate::rng::Rng;
use crate::shape::Shape;
use crate::{flag, flag_or};
use fidelity::{MANIFEST_SCHEMA, Manifest, Planned};
use plan::{Coord, CoordSpec, Family, Item, Step};
use render::Ctx;
use sink::{FillerPool, SegmentWriter};
use std::cmp::Reverse;
use std::collections::{BTreeSet, BinaryHeap};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

/// acpmux's `TRANSCRIPT_MUX_KINDS` (`hub/paging.rs`): the mux records a chat transcript renders.
const TRANSCRIPT_MUX_KINDS: &[&str] = &[
    "_acpmux/message",
    "fork_start_failed",
    "user_message",
    "queued",
    "dequeued",
    "queue_removed",
    "prompt_retracted",
    "steer_withdrawn",
    "steer_read",
    "steer_returned",
    "stopping",
    "queue_updated",
    "queue_order",
    "queue_paused",
    "queue_resumed",
    "queue_approved",
    "queue_declined",
    "turn_started",
    "sender_claim",
    "native_history",
    "turn_silent",
    "turn_heard",
    "loop_detected",
    "loop_cleared",
    "claim_checks",
    "turn_retrying",
    "turn_result",
    "background_turn",
    "permission_request",
    "permission_auto",
    "permission_decision",
    "permission_group",
    "permission_chat_allowance",
    "message_superseded",
    "failover",
    "recap",
    "memory_offer",
    "memory_resolved",
    "coach_offer",
    "coach",
    "policy_unenforced",
    "host_notice",
    "forked",
    "imported",
    "session_offer",
    "session_offer_decision",
    "mode",
    "model",
    "stopped",
    "exited",
    "resumed",
    "reopened",
    "host_started",
    "host_ended",
    "plan_build",
    "race",
];

/// acpmux's `NON_TRANSCRIPT_UPDATES` (`hub/paging.rs`).
const NON_TRANSCRIPT_UPDATES: &[&str] = &[
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    "compaction_summary",
    "prompt_suggestion",
];

/// A fixed start (2026-11-19 00:00 UTC), so the same seed makes the same bytes.
const DEFAULT_START_MS: u64 = 1_795_046_400_000;

#[derive(Debug, Clone)]
pub struct Opts {
    pub shape: Option<String>,
    pub seed: u64,
    pub coordinators: u32,
    pub events: Option<u64>,
    pub scale: f64,
    pub out: PathBuf,
    pub script: bool,
    pub acpmux: bool,
    pub peak: Option<u64>,
    pub byte_limit: u64,
    pub harness: Option<Family>,
    pub max_line: u64,
    pub segment_bytes: u64,
    pub start_ms: u64,
}

/// `512`, `64K`/`64KiB`, `8M`/`8MiB`, `5G`/`5GiB` (powers of 1024), or `1KB`, `100MB`, `1GB`, `4GB`,
/// `1TB` (powers of 1000), fractions allowed (`1.5G`).
pub fn parse_size(s: &str) -> Result<u64, String> {
    let s = s.trim();
    let upper = s.to_ascii_uppercase();
    let units: [(&str, u64); 12] = [
        ("KIB", 1 << 10),
        ("MIB", 1 << 20),
        ("GIB", 1 << 30),
        ("TIB", 1 << 40),
        ("KB", 1_000),
        ("MB", 1_000_000),
        ("GB", 1_000_000_000),
        ("TB", 1_000_000_000_000),
        ("K", 1 << 10),
        ("M", 1 << 20),
        ("G", 1 << 30),
        ("T", 1 << 40),
    ];
    let (num, mult) = units
        .iter()
        .find(|(u, _)| upper.ends_with(u))
        .map_or((s, 1), |(u, m)| (s.get(..s.len() - u.len()).unwrap_or(""), *m));
    let num = num.trim();
    let v: f64 = num.parse().map_err(|_| format!("bad size {s:?}"))?;
    if v.is_nan() || v < 0.0 {
        return Err(format!("bad size {s:?}"));
    }
    Ok((v * mult as f64).round() as u64)
}

fn size_flag(args: &[String], name: &str, default: u64) -> Result<u64, String> {
    flag(args, name).map_or(Ok(default), |v| parse_size(v).map_err(|e| format!("{name}: {e}")))
}

impl Opts {
    pub fn parse(args: &[String]) -> Result<Opts, String> {
        let out = flag(args, "--out").ok_or("--out DIR is required")?;
        let (script, acpmux) = match flag(args, "--format").unwrap_or("both") {
            "script" => (true, false),
            "acpmux" => (false, true),
            "both" => (true, true),
            f => return Err(format!("--format: {f:?}, want script|acpmux|both")),
        };
        let harness = match flag(args, "--harness") {
            None => None,
            Some(h) => Some(
                Family::parse(h).ok_or_else(|| format!("--harness: {h:?}, want claude|codex"))?,
            ),
        };
        let scale: f64 = flag_or(args, "--scale", 1.0)?;
        // `--target-bytes` (or `--bytes`): each chat's lines total this, within 2%; with no `--events`
        // the chat runs until it gets there.
        let byte_limit = match flag(args, "--target-bytes") {
            Some(_) => size_flag(args, "--target-bytes", 0)?,
            None => size_flag(args, "--bytes", 0)?,
        };
        let max_line = size_flag(args, "--max-line", 32 << 20)?;
        if !(scale > 0.0 && scale.is_finite()) {
            return Err("--scale must be above 0".into());
        }
        Ok(Opts {
            shape: flag(args, "--shape").map(str::to_owned),
            seed: flag_or(args, "--seed", 1)?,
            coordinators: flag_or::<u32>(args, "--coordinators", 1)?.max(1),
            events: flag(args, "--events")
                .map(|v| v.parse().map_err(|_| format!("--events: bad value {v:?}")))
                .transpose()?,
            scale,
            out: PathBuf::from(out),
            script,
            acpmux,
            peak: flag(args, "--peak")
                .map(|v| v.parse().map_err(|_| format!("--peak: bad value {v:?}")))
                .transpose()?,
            byte_limit,
            harness,
            // A line is at most 2% of a byte target, so the chat ends within 2% of it.
            max_line: if byte_limit > 0 {
                max_line.min((byte_limit / 50).max(4096))
            } else {
                max_line
            },
            segment_bytes: size_flag(args, "--segment-bytes", sink::SEGMENT_BYTES)?,
            start_ms: flag_or(args, "--start-ms", DEFAULT_START_MS)?,
        })
    }
}

pub fn run(args: &[String]) -> Result<(), String> {
    if let Some(probe) = flag(args, "--check") {
        return check(args, probe);
    }
    let opts = Opts::parse(args)?;
    let shape = Shape::load(opts.shape.as_deref())?;
    let started = std::time::Instant::now();
    let manifest = generate(&shape, &opts)?;
    let secs = started.elapsed().as_secs_f64().max(1e-9);
    let bytes: u64 = manifest.coordinators.iter().map(|c| c.bytes).sum();
    let lines: u64 = manifest.coordinators.iter().map(|c| c.lines).sum();
    let largest = manifest.coordinators.iter().map(|c| c.bytes).max().unwrap_or(0);
    let summary = serde_json::json!({
        "schema": "coord-sim-gen-run.v1",
        "out": opts.out.display().to_string(),
        "coordinators": manifest.coordinators.len(),
        "lines": lines,
        "bytes": bytes,
        "largest_chat_bytes": largest,
        "seconds": (secs * 1000.0).round() / 1000.0,
        "mb_per_s": ((bytes as f64 / 1e6 / secs) * 10.0).round() / 10.0,
        "lines_per_s": (lines as f64 / secs).round(),
    });
    println!("{summary}");
    Ok(())
}

fn check(args: &[String], probe_path: &str) -> Result<(), String> {
    let out =
        PathBuf::from(flag(args, "--out").ok_or("--check needs --out DIR (the generated run)")?);
    let shape = Shape::load(flag(args, "--shape"))?;
    // A directory is a generated `.acpmux` home measured here; a file is `coord_shape_probe.py`'s JSON.
    let got = if Path::new(probe_path).is_dir() {
        fidelity::probe(Path::new(probe_path))?
    } else {
        Shape::load(Some(probe_path))?
    };
    let m = read_manifest(&out)?;
    let report = fidelity::compare(&shape, &got, &m)?;
    println!("{}", serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?);
    if report.failures.is_empty() {
        Ok(())
    } else {
        Err(format!("outside tolerance: {}", report.failures.join(", ")))
    }
}

pub fn read_manifest(out: &Path) -> Result<Manifest, String> {
    let p = out.join("manifest.json");
    let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", p.display()))
}

/// A UUIDv7-looking id from a time and the coordinator's stream.
fn uuid_like(ms: u64, rng: &mut Rng) -> String {
    let (a, b) = (rng.next_u64(), rng.next_u64());
    format!(
        "{:08x}-{:04x}-7{:03x}-{:04x}-{:012x}",
        (ms >> 16) & 0xffff_ffff,
        ms & 0xffff,
        a & 0xfff,
        0x8000 | ((a >> 12) & 0x3fff),
        b & 0xffff_ffff_ffff
    )
}

/// One coordinator's writers and what its `session.json` will say.
struct Out {
    script: Option<BufWriter<std::fs::File>>,
    script_path: PathBuf,
    seg: Option<SegmentWriter>,
    session_dir: PathBuf,
    ctx: Ctx,
    seq: u64,
    script_seq: u64,
    transcript_seq: u64,
    turns: u64,
    last_at: u64,
    script_bytes: u64,
}

impl Out {
    /// The bytes this chat holds so far: its acpmux log's, else its script's payloads.
    fn written(&self) -> u64 {
        self.seg.as_ref().map_or(self.script_bytes, |s| s.total)
    }
}

struct Run<'a> {
    opts: &'a Opts,
    home: PathBuf,
    pool: FillerPool,
    updates: BTreeSet<String>,
    names: Vec<String>,
}

impl Run<'_> {
    fn is_update(&self, key: &str) -> bool {
        let Some(kind) = key.strip_prefix("in:") else { return false };
        self.updates.contains(kind.strip_suffix(".replay").unwrap_or(kind))
    }

    fn is_transcript(&self, key: &str) -> bool {
        let (dir, kind) = render::record_kind(key);
        if dir == "in" && self.is_update(key) {
            return !kind.ends_with(".replay") && !NON_TRANSCRIPT_UPDATES.contains(&kind);
        }
        dir == "mux" && TRANSCRIPT_MUX_KINDS.contains(&kind)
    }

    /// Writes one step of coordinator `idx`: its script line and its acpmux line(s).
    fn emit(&self, idx: u32, o: &mut Out, step: &Step, key: Option<&str>) -> Result<(), String> {
        let op = match &step.item {
            Item::Event(_) => key.map(|k| Op::Event { kind: k.to_owned() }),
            Item::UserTurn => Some(Op::UserTurn),
            Item::Subagent { events } => Some(Op::Subagent { events: *events }),
            Item::Compaction => Some(Op::Compaction),
            Item::Attachment => Some(Op::Attachment),
            Item::SendTo { to } => Some(Op::SendTo { to: *to }),
            // The sender's `SendTo` makes it when the script is played.
            Item::Receipt { .. } => None,
        };
        if let (Some(w), Some(op)) = (o.script.as_mut(), op) {
            o.script_seq += 1;
            o.script_bytes += step.bytes;
            let ev = SimEvent { seq: o.script_seq, at_ms: step.at_ms, bytes: step.bytes, op };
            let line = serde_json::to_string(&ev).map_err(|e| e.to_string())?;
            w.write_all(line.as_bytes())
                .and_then(|()| w.write_all(b"\n"))
                .map_err(|e| format!("{}: {e}", o.script_path.display()))?;
        }
        let Some(seg) = o.seg.as_mut() else { return Ok(()) };
        let at = self.opts.start_ms + step.at_ms;
        let key = match &step.item {
            Item::Event(_) => key.unwrap_or("mux:status"),
            Item::UserTurn => {
                render::begin_turn(&mut o.ctx);
                o.turns += 1;
                plan::USER_TURN
            }
            Item::Subagent { .. } => plan::SUBAGENT,
            Item::Compaction => plan::COMPACTION,
            Item::Receipt { from } => {
                o.ctx.peer = self.names.get(*from as usize).cloned().unwrap_or_default();
                plan::RECEIPT
            }
            // The sender's side of a message to another coordinator: its tool call.
            Item::SendTo { .. } => "in:tool_call",
            Item::Attachment => {
                let pick = (u64::from(idx) << 40) ^ o.seq ^ 0xA77A;
                let id = sink::write_attachment(&self.home, step.bytes, &self.pool, pick)?;
                let name = format!("coord-sim-{}.png", o.ctx.images.len() + 1);
                o.ctx.images.push((id, "image/png".into(), name));
                return Ok(());
            }
        };
        o.seq += 1;
        let line = render::render(key, o.seq, at, step.bytes, self.is_update(key), &mut o.ctx);
        seg.write(&line, &self.pool, (u64::from(idx) << 40) ^ o.seq)?;
        if self.is_transcript(key) {
            o.transcript_seq = o.seq;
        }
        o.last_at = at;
        Ok(())
    }
}

/// Generates every coordinator into `opts.out`, returning the manifest it also writes there.
pub fn generate(shape: &Shape, opts: &Opts) -> Result<Manifest, String> {
    sink::mkdirs(&opts.out)?;
    // An acpmux home of its own (ACPMUX_HOME), laid out as the account home's.
    let home = opts.out.join("acpmux-home");
    let mut root = Rng::new(opts.seed);
    let mut coords = Vec::new();
    let mut outs = Vec::new();
    let mut names = Vec::new();
    let tool_kinds: Vec<(String, u64)> =
        shape.acpmux.tool_call_kinds.iter().map(|(k, v)| (k.clone(), *v)).collect();
    for i in 0..opts.coordinators {
        let mut rng = root.fork(u64::from(i));
        let ps = &shape.acpmux.per_session;
        let events = match opts.events {
            Some(n) => n,
            None if opts.byte_limit > 0 => u64::MAX / 4,
            None => ((ps.events.sample(&mut rng) as f64) * opts.scale).round() as u64,
        }
        .max(1);
        let peak = match opts.peak {
            Some(p) => p,
            None => ((ps.peak_events_1s.sample(&mut rng) as f64) * opts.scale).round() as u64,
        }
        .max(1);
        let family =
            opts.harness.unwrap_or(if i % 2 == 0 { Family::Claude } else { Family::Codex });
        let id = uuid_like(opts.start_ms + u64::from(i), &mut rng);
        let agent_session = uuid_like(opts.start_ms + u64::from(i), &mut rng);
        let name = format!("coord-sim-{}-{i}", opts.seed);
        let spec = CoordSpec {
            idx: i,
            family,
            events,
            peak,
            scale: opts.scale,
            max_line: opts.max_line,
            byte_limit: opts.byte_limit,
            coordinators: opts.coordinators,
            origin_ms: opts.start_ms,
        };
        let plan_rng = rng.fork(0x51A7);
        coords.push(Coord::new(shape, spec, plan_rng)?);
        let session_dir = home.join("sessions").join(&id);
        let script_path = opts.out.join(format!("coord-{i}.ndjson"));
        let mut ctx = Ctx::new(family.name(), id.clone(), agent_session, name.clone());
        ctx.tool_kinds = tool_kinds.clone();
        outs.push(Out {
            script: if opts.script { Some(sink::create(&script_path)?) } else { None },
            script_path,
            seg: if opts.acpmux {
                Some(SegmentWriter::new(&session_dir, opts.segment_bytes))
            } else {
                None
            },
            session_dir,
            ctx,
            seq: 0,
            script_seq: 0,
            transcript_seq: 0,
            turns: 0,
            last_at: opts.start_ms,
            script_bytes: 0,
        });
        names.push(name);
    }
    let run = Run {
        opts,
        home: home.clone(),
        pool: FillerPool::new(opts.seed),
        updates: shape.acpmux.session_update_bytes.keys().cloned().collect(),
        names,
    };
    // Every coordinator at once, in time order: a message one sends lands in the other's log at the
    // same moment.
    let mut heap = BinaryHeap::new();
    for (i, c) in coords.iter_mut().enumerate() {
        if let Some(t) = c.peek() {
            heap.push(Reverse((t, i)));
        }
    }
    while let Some(Reverse((_, i))) = heap.pop() {
        let Some(c) = coords.get_mut(i) else { continue };
        let Some(step) = c.pop() else { continue };
        let key = match step.item {
            Item::Event(k) => c.table.keys.get(k).cloned(),
            _ => None,
        };
        if let Item::Receipt { from } = step.item
            && let Some(sender) = coords.get_mut(from as usize)
        {
            let send = Step {
                at_ms: step.at_ms,
                item: Item::SendTo { to: i as u32 },
                bytes: sender.send_size(),
            };
            if let Some(o) = outs.get_mut(from as usize) {
                run.emit(from, o, &send, None)?;
            }
        }
        let mut full = false;
        if let Some(o) = outs.get_mut(i) {
            run.emit(i as u32, o, &step, key.as_deref())?;
            full = opts.byte_limit > 0 && o.written() >= opts.byte_limit;
        }
        if full {
            continue;
        }
        if let Some(t) = coords.get_mut(i).and_then(Coord::peek) {
            heap.push(Reverse((t, i)));
        }
    }
    let mut planned = Vec::new();
    for (i, (c, o)) in coords.iter().zip(outs.iter_mut()).enumerate() {
        if let Some(w) = o.script.as_mut() {
            w.flush().map_err(|e| format!("{}: {e}", o.script_path.display()))?;
        }
        let (mut bytes, mut segments) = (o.script_bytes, 0);
        if let Some(seg) = o.seg.as_mut() {
            seg.finish()?;
            bytes = seg.total;
            segments = seg.segments;
            write_session_json(opts, o, c.spec.family)?;
        }
        planned.push(Planned {
            index: i as u32,
            id: o.ctx.session_id.clone(),
            name: o.ctx.name.clone(),
            harness: c.spec.family.name().into(),
            events: c.spec.events,
            peak_events_1s: c.spec.peak,
            lines: if opts.acpmux { o.seq } else { o.script_seq },
            bytes,
            segments,
        });
    }
    let manifest = Manifest {
        schema: MANIFEST_SCHEMA.into(),
        seed: opts.seed,
        scale: opts.scale,
        coordinators: planned,
    };
    let text = serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?;
    sink::write_atomic(&opts.out.join("manifest.json"), &(text + "\n"))?;
    Ok(manifest)
}

/// The chat's `session.json`, acpmux.session.v1 (`store.rs` `SessionMeta`): an idle chat (no agent
/// process; a prompt would start one), so the daemon opens it without starting anything and its
/// closed-log retention never compacts it.
fn write_session_json(opts: &Opts, o: &Out, family: Family) -> Result<(), String> {
    let (agent_name, agent_title) = match family {
        Family::Claude => ("claude-stdio", "Claude Code"),
        Family::Codex => ("cmux-codex-acp", "Codex"),
    };
    let meta = serde_json::json!({
        "schema": "acpmux.session.v1",
        "id": o.ctx.session_id,
        "name": o.ctx.name,
        "nameGiven": true,
        "harness": family.name(),
        "harnessArgv": [],
        "family": family.name(),
        "cwd": "/tmp",
        "agentSessionId": o.ctx.agent_session,
        "agentSessionFamily": family.name(),
        "status": "idle",
        "createdAt": opts.start_ms,
        "updatedAt": o.last_at,
        "lastSeq": o.seq,
        "transcriptSeq": o.transcript_seq,
        "parentId": null,
        "forkSeq": null,
        "agentInfo": {"name": agent_name, "title": agent_title, "version": "coord-sim"},
        "agentCapabilities": {"loadSession": true, "promptCapabilities": {"embeddedContext": true, "image": true}},
        "modes": null,
        "configOptions": null,
        "models": null,
        "permissionPolicy": null,
        "title": format!("coord-sim {}", o.ctx.name),
        "titleSource": "harness",
        "lastPrompt": null,
        "preview": null,
        "eventCount": o.seq,
        "turnCount": o.turns,
        "usage": null,
        "cmuxContextDelivered": false,
        "unread": false,
    });
    let text = serde_json::to_string_pretty(&meta).map_err(|e| e.to_string())?;
    sink::write_atomic(&o.session_dir.join("session.json"), &(text + "\n"))
}

#[cfg(test)]
mod tests;

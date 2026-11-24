//! `terminal-resume-v1` over the raw v12 command path: a viewer that is cut
//! at seeded points and reattaches with its last `offset` reads every byte
//! the terminal produced exactly once, with no replay and no reset, and the
//! reattach costs the missing bytes, not the scrollback.
//!
//! Prints `NETCOND` lines (msr-common.md "Number output shape"): the
//! `before` lines are the same scenario reattaching without `resume_offset`
//! (today's path), the `after` lines with it.

use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::tests::captured_writer;
use super::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
};
use crate::{Mux, Surface, SurfaceOptions};

fn command(value: Value) -> Command {
    serde_json::from_value(value).expect("raw command")
}

fn quiet_surface(name: &str) -> (Arc<Mux>, Arc<Surface>) {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "exec sleep 600".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new_for_test(name, options);
    let surface = mux.new_workspace(None, None).unwrap();
    (mux, surface)
}

/// xorshift64*: a seeded source of cut points.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1)
    }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next() % (hi - lo + 1)
    }
}

/// The terminal under test: it produces `SEQ nnnnnnnn\n` lines, fixed width so a run of lines costs the same at any scale.
struct Producer {
    surface: Arc<Surface>,
    next: u64,
    /// Every byte produced since the surface started.
    produced: Vec<u8>,
}

impl Producer {
    fn lines(&mut self, count: u64) {
        for _ in 0..count {
            let line = format!("SEQ {:08}\n", self.next);
            self.next += 1;
            self.surface.inject_output_for_test(line.as_bytes());
            self.produced.extend_from_slice(line.as_bytes());
        }
        assert_eq!(self.offset(), self.produced.len() as u64, "the stream offset counts the bytes");
    }

    fn offset(&self) -> u64 {
        self.surface.snapshot_stream_position().expect("pty").1
    }
}

struct Link {
    client: u64,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
}

/// What a viewer holds.
#[derive(Default)]
struct Mirror {
    /// Bytes applied after its first attach.
    applied: Vec<u8>,
    /// Offset of `applied`'s first byte.
    base: u64,
    offset: u64,
    generation: String,
    resets: u64,
    /// Bytes of every replay or resume answer after the first attach.
    answer_bytes: Vec<u64>,
    exact: u64,
    gap: u64,
}

impl Mirror {
    fn apply(&mut self, event: &Value, first: bool) {
        match event["event"].as_str() {
            Some("vt-state") => {
                let replay = event["data"].as_str().map_or(0, |data| {
                    base64::engine::general_purpose::STANDARD.decode(data).expect("base64").len()
                });
                if first {
                    self.base = event["offset"].as_u64().expect("vt-state offset");
                } else {
                    // The viewer resets its mirror and replays: no offset to splice at.
                    self.resets += 1;
                    self.answer_bytes.push(replay as u64);
                    self.applied.clear();
                    self.base = event["offset"].as_u64().expect("vt-state offset");
                    self.gap += u64::from(event["resume"] == "gap");
                }
                self.offset = event["offset"].as_u64().expect("vt-state offset");
                self.generation = event["generation"].as_str().expect("generation").to_string();
            }
            Some("output") => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(event["data"].as_str().expect("data"))
                    .expect("base64");
                if event["resume"] == "exact" {
                    self.exact += 1;
                    self.answer_bytes.push(bytes.len() as u64);
                }
                if let Some(offset) = event["offset"].as_u64() {
                    assert_eq!(offset, self.offset + bytes.len() as u64, "stamped offset: {event}");
                    self.offset = offset;
                    self.generation = event["generation"].as_str().expect("generation").to_string();
                }
                self.applied.extend_from_slice(&bytes);
            }
            _ => {}
        }
    }
}

fn open(
    mux: &Arc<Mux>,
    surface: &Surface,
    capability: bool,
    resume: Option<(u64, &str)>,
) -> (Link, Value) {
    open_bounded(mux, surface, capability, resume, None)
}

fn open_bounded(
    mux: &Arc<Mux>,
    surface: &Surface,
    capability: bool,
    resume: Option<(u64, &str)>,
    max_bytes: Option<u64>,
) -> (Link, Value) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if capability {
        handle_command(
            mux,
            client,
            command(json!({"cmd": "set-client-info", "capabilities": ["terminal-resume-v1"]})),
            &writer,
        )
        .unwrap();
    }
    let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
    if let Some((offset, generation)) = resume {
        request["resume_offset"] = json!(offset);
        request["resume_generation"] = json!(generation);
    }
    if let Some(max_bytes) = max_bytes {
        // As the phone attaches (DaemonTerminalSession.historyAttachParams): a replay is the
        // screen, and its history pages in on scroll.
        request["resume_max_bytes"] = json!(max_bytes);
        request["replay_history_rows"] = json!(0);
    }
    let reply = handle_command(mux, client, command(request), &writer).unwrap();
    (Link { client, outbound, writer }, reply)
}

fn pop(link: &Link) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(message) = link.outbound.try_pop() {
            return serde_json::from_str(&message).expect("outbound JSON");
        }
        assert!(Instant::now() < deadline, "no message");
        std::thread::sleep(Duration::from_micros(300));
    }
}

/// Every event up to the one that brings the stream to `target`.
fn events_until(link: &Link, mut at: u64, target: u64) -> Vec<Value> {
    let mut events = Vec::new();
    while at < target {
        let event = pop(link);
        if let Some(offset) = event["offset"].as_u64() {
            at = offset;
        }
        events.push(event);
    }
    events
}

struct Run {
    dups: u64,
    holes: u64,
    resets: u64,
    resumes: u64,
    resume_bytes: u64,
    missing_bytes: u64,
    exact: u64,
    gap: u64,
}

/// One viewer on `producer`'s terminal, cut at seeded points; `resume`: it
/// reattaches with its last offset, else as today.
fn run_seed(mux: &Arc<Mux>, producer: &mut Producer, seed: u64, resume: bool) -> Run {
    let mut rng = Rng::new(seed);
    let mut mirror = Mirror::default();
    let (mut link, _) = open(mux, &producer.surface, true, None);
    let first = pop(&link);
    mirror.apply(&first, true);
    let first_base = mirror.base;
    let mut missing_total = 0;
    for _ in 0..rng.range(3, 6) {
        let before = producer.offset();
        producer.lines(rng.range(1, 30));
        let events = events_until(&link, mirror.offset, producer.offset());
        // The cut: the viewer read only some of what the daemon sent.
        let read = rng.range(0, events.len() as u64) as usize;
        for event in &events[..read] {
            mirror.apply(event, false);
        }
        let _ = before;
        disconnect_client(mux, link.client, false);
        drop(link.writer.clone());
        producer.lines(rng.range(0, 30));
        missing_total += producer.offset() - mirror.offset;
        let held = (mirror.offset, mirror.generation.clone());
        let (new_link, reply) =
            open(mux, &producer.surface, true, resume.then_some((held.0, held.1.as_str())));
        link = new_link;
        let answer = pop(&link);
        if resume {
            assert_eq!(reply["resume"], "exact", "{reply}");
            assert_eq!(answer["resume"], "exact", "{answer}");
            assert_eq!(reply["through"], producer.offset());
        }
        mirror.apply(&answer, false);
    }
    producer.lines(rng.range(1, 30));
    for event in events_until(&link, mirror.offset, producer.offset()) {
        mirror.apply(&event, false);
    }
    disconnect_client(mux, link.client, false);
    let produced = &producer.produced[first_base as usize..];
    let (dups, holes) = if resume {
        let applied = &mirror.applied;
        (
            applied.len().saturating_sub(produced.len()) as u64,
            produced.len().saturating_sub(applied.len()) as u64,
        )
    } else {
        (0, 0)
    };
    if resume {
        assert_eq!(mirror.applied, produced, "seed {seed}: every byte once, in order");
    }
    Run {
        dups,
        holes,
        resets: mirror.resets,
        resumes: mirror.answer_bytes.len() as u64,
        resume_bytes: mirror.answer_bytes.iter().sum(),
        missing_bytes: missing_total,
        exact: mirror.exact,
        gap: mirror.gap,
    }
}

fn netcond(prefix: &str, scale: &str, metric: &str, value: f64, seed: u64) {
    println!(
        "{prefix}NETCOND {}",
        json!({"surface":"terminal","profile":"seeded-drop@1","phase":"reconnect","scale":scale,
               "metric":metric,"value":value,"run":0,"seed":seed})
    );
}

/// 100 seeds: every byte exactly once, no reset after the first attach, and
/// each resume carries exactly the bytes missing.
#[test]
fn seeded_cuts_read_every_byte_once_with_no_reset() {
    let (mux, surface) = quiet_surface("resume-seeds");
    let mut producer = Producer { surface, next: 0, produced: Vec::new() };
    producer.lines(200);
    let (mut dups, mut holes, mut resets, mut resumes, mut exact) = (0, 0, 0, 0, 0);
    let (mut bytes, mut missing) = (0, 0);
    for seed in 0..100 {
        let run = run_seed(&mux, &mut producer, seed, true);
        dups += run.dups;
        holes += run.holes;
        resets += run.resets;
        resumes += run.resumes;
        exact += run.exact;
        bytes += run.resume_bytes;
        missing += run.missing_bytes;
        assert_eq!(run.gap, 0);
        assert_eq!(run.resume_bytes, run.missing_bytes, "seed {seed}: O(missing)");
    }
    assert_eq!((dups, holes, resets), (0, 0, 0));
    assert_eq!(exact, resumes);
    assert_eq!(bytes, missing);
    netcond("after ", "1x", "dups", dups as f64, 0);
    netcond("after ", "1x", "holes", holes as f64, 0);
    netcond("after ", "1x", "resets", resets as f64, 0);
    netcond("after ", "1x", "resume_bytes", bytes as f64 / resumes as f64, 0);
    netcond("after ", "1x", "resume_round_trips", 1.0, 0);
    // Today's path: the same cuts, reattaching without an offset.
    let (mut b_resets, mut b_resumes, mut b_bytes) = (0, 0, 0);
    for seed in 0..100 {
        let run = run_seed(&mux, &mut producer, seed, false);
        b_resets += run.resets;
        b_resumes += run.resumes;
        b_bytes += run.resume_bytes;
    }
    assert_eq!(b_resets, b_resumes, "without an offset every reattach is a reset");
    netcond("before ", "1x", "dups", 0.0, 0);
    netcond("before ", "1x", "holes", 0.0, 0);
    netcond("before ", "1x", "resets", b_resets as f64, 0);
    netcond("before ", "1x", "resume_bytes", b_bytes as f64 / b_resumes as f64, 0);
    netcond("before ", "1x", "resume_round_trips", 1.0, 0);
    disconnect_client(&mux, 0, false);
    mux.shutdown();
}

/// One cut at scrollback `lines`: the bytes a reattach costs, with and
/// without an offset.
fn cost_at(lines: u64, resume: bool, name: &str) -> (u64, u64) {
    let (mux, surface) = quiet_surface(name);
    let mut producer = Producer { surface, next: 0, produced: Vec::new() };
    producer.lines(lines);
    let mut mirror = Mirror::default();
    let (link, _) = open(&mux, &producer.surface, true, None);
    mirror.apply(&pop(&link), true);
    producer.lines(5);
    for event in events_until(&link, mirror.offset, producer.offset()) {
        mirror.apply(&event, false);
    }
    disconnect_client(&mux, link.client, false);
    producer.lines(10);
    let held = (mirror.offset, mirror.generation.clone());
    let (link, reply) =
        open(&mux, &producer.surface, true, resume.then_some((held.0, held.1.as_str())));
    let answer = pop(&link);
    let missing = producer.offset() - held.0;
    mirror.apply(&answer, false);
    if resume {
        assert_eq!(reply["resume"], "exact");
    }
    let cost = *mirror.answer_bytes.last().expect("an answer");
    disconnect_client(&mux, link.client, false);
    mux.shutdown();
    (cost, missing)
}

/// The cost of a resume does not grow with the scrollback; today's replay does.
#[test]
fn resume_cost_is_flat_across_scrollback() {
    let scales = [("1x", 50u64), ("10x", 500), ("100x", 5_000), ("1000x", 50_000)];
    let mut costs = Vec::new();
    let mut before = Vec::new();
    for (scale, lines) in scales {
        let (cost, missing) = cost_at(lines, true, &format!("resume-cost-{scale}"));
        assert_eq!(cost, missing, "{scale}: exactly the missing bytes");
        netcond("after ", scale, "resume_bytes", cost as f64, 0);
        costs.push(cost as f64);
        let (cost, _) = cost_at(lines, false, &format!("replay-cost-{scale}"));
        netcond("before ", scale, "resume_bytes", cost as f64, 0);
        before.push(cost as f64);
    }
    let (lo, hi) = costs.iter().fold((f64::MAX, 0f64), |(lo, hi), c| (lo.min(*c), hi.max(*c)));
    assert!(hi <= lo * 1.2, "resume cost {costs:?} is not flat within 1.2x");
    assert!(before[3] > before[0] * 2.0, "the replay grows with scrollback: {before:?}");
}

/// A generation of another terminal, an offset the ring dropped, an offset
/// from the future, and a client that did not opt in: today's answer.
#[test]
fn gaps_and_old_clients_get_todays_answer() {
    let (mux, surface) = quiet_surface("resume-gaps");
    let mut producer = Producer { surface, next: 0, produced: Vec::new() };
    producer.lines(10);
    let mut mirror = Mirror::default();
    let (link, _) = open(&mux, &producer.surface, true, None);
    mirror.apply(&pop(&link), true);
    disconnect_client(&mux, link.client, false);
    let held = (mirror.offset, mirror.generation.clone());

    // Another terminal's nonce.
    let (other_nonce, epoch) = held.1.split_once('.').unwrap();
    let foreign = format!("{:x}.{epoch}", u64::from_str_radix(other_nonce, 16).unwrap() ^ 1);
    let (link, reply) = open(&mux, &producer.surface, true, Some((held.0, &foreign)));
    assert_eq!(pop(&link)["event"], "vt-state");
    assert_eq!(reply["resume"], "gap", "{reply}");
    disconnect_client(&mux, link.client, false);
    // The future.
    let (link, reply) = open(&mux, &producer.surface, true, Some((producer.offset() + 5, &held.1)));
    let state = pop(&link);
    assert_eq!(
        (state["event"].as_str(), state["resume"].as_str()),
        (Some("vt-state"), Some("gap"))
    );
    assert_eq!(reply["resume"], "gap");
    disconnect_client(&mux, link.client, false);
    // The ring dropped it: more than its budget went by.
    let chunk = vec![b'x'; 64 * 1024];
    for _ in 0..80 {
        producer.surface.inject_output_for_test(&chunk);
    }
    let (link, reply) = open(&mux, &producer.surface, true, Some((held.0, &held.1)));
    assert_eq!(pop(&link)["event"], "vt-state");
    assert_eq!(reply["resume"], "gap");
    disconnect_client(&mux, link.client, false);

    // An old client: no capability, no params, today's lines.
    let (link, reply) = open(&mux, &producer.surface, false, None);
    let state = pop(&link);
    assert_eq!(state["event"], "vt-state");
    assert!(state.get("offset").is_none() && state.get("generation").is_none(), "{state}");
    assert!(reply.get("resume").is_none() && reply.get("through").is_none(), "{reply}");
    producer.surface.inject_output_for_test(b"hello");
    let output = pop(&link);
    let expected = format!(
        "{{\"event\":\"output\",\"surface\":{},\"data\":\"{}\"}}",
        producer.surface.id,
        base64::engine::general_purpose::STANDARD.encode(b"hello")
    );
    assert_eq!(output.to_string(), serde_json::from_str::<Value>(&expected).unwrap().to_string());
    disconnect_client(&mux, link.client, false);
    mux.shutdown();
}

/// `terminal-resume-bounded-v1`: a viewer back after a short time away gets
/// the exact missed bytes; back after a long one (more missed than its bound,
/// the size of its last replay) it gets one screen replay instead of every
/// byte, so the catch-up costs a screen whatever the time away.
#[test]
fn a_bounded_resume_replays_one_screen_after_a_long_time_away() {
    let (mux, surface) = quiet_surface("resume-bounded");
    let mut producer = Producer { surface, next: 0, produced: Vec::new() };
    producer.lines(10);
    let mut mirror = Mirror::default();
    let (link, _) = open(&mux, &producer.surface, true, None);
    let first = pop(&link);
    mirror.apply(&first, true);
    disconnect_client(&mux, link.client, false);
    let bound = 4 * 1024u64;

    // A short time away: 20 lines, under the bound, exact.
    producer.lines(20);
    let held = (mirror.offset, mirror.generation.clone());
    let (link, reply) =
        open_bounded(&mux, &producer.surface, true, Some((held.0, &held.1)), Some(bound));
    assert_eq!(reply["resume"], "exact", "{reply}");
    let missing = producer.offset() - mirror.offset;
    mirror.apply(&pop(&link), false);
    assert_eq!(*mirror.answer_bytes.last().unwrap(), missing);
    disconnect_client(&mux, link.client, false);

    // A long time away: 20,000 lines (about 260 KB, still in the 4 MiB ring).
    producer.lines(20_000);
    let missing = producer.offset() - mirror.offset;
    assert!(missing > 50 * bound, "{missing}");
    let held = (mirror.offset, mirror.generation.clone());
    let (link, reply) =
        open_bounded(&mux, &producer.surface, true, Some((held.0, &held.1)), Some(bound));
    assert_eq!(reply["resume"], "gap", "{reply}");
    let state = pop(&link);
    assert_eq!(
        (state["event"].as_str(), state["resume"].as_str()),
        (Some("vt-state"), Some("gap"))
    );
    mirror.apply(&state, false);
    let replay = *mirror.answer_bytes.last().unwrap();
    assert!(replay * 10 < missing, "one screen ({replay} B) instead of {missing} B");
    assert_eq!(mirror.offset, producer.offset(), "current after one answer");
    netcond("after ", "long-away", "resume_bytes", replay as f64, 0);
    netcond("before ", "long-away", "resume_bytes", missing as f64, 0);
    disconnect_client(&mux, link.client, false);

    // Without the bound the same cursor gets every byte (terminal-resume-v1).
    let (link, reply) = open(
        &mux,
        &producer.surface,
        true,
        Some((first["offset"].as_u64().unwrap(), first["generation"].as_str().unwrap())),
    );
    assert_eq!(reply["resume"], "exact");
    disconnect_client(&mux, link.client, false);
    mux.shutdown();
}

#[test]
fn the_capability_is_advertised() {
    let (mux, _surface) = quiet_surface("resume-identify");
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(capabilities.iter().any(|value| value == "terminal-resume-v1"), "{identity}");
    assert!(capabilities.iter().any(|value| value == "terminal-resume-bounded-v1"), "{identity}");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

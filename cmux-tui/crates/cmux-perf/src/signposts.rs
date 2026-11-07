//! cmux's signposts (subsystem `com.cmuxterm.app.next`, every process) from
//! `/usr/bin/log stream --signpost --style ndjson`, as trace.py records them
//! (plans/cmux-next/trace.md, "What is in the trace").
//!
//! A begin and an end with the same process, category, name and signpost id
//! make one `X` slice on the emitting thread; an `event` is an instant. An end
//! with no begin in the window, or a begin still open at the end, is an
//! instant too, counted as unpaired. Times come from each line's `timestamp`
//! (local wall time with its offset), so they share the sampler's clock.
//!
//! The `log stream` child is ours alone: it ends by its own pid (SIGTERM, then
//! SIGKILL after [`STOP_GRACE`]), and every wait on it has a deadline.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::Value;

use crate::clock::parse_timestamp;
use crate::trace::Event;

pub const SUBSYSTEM: &str = "com.cmuxterm.app.next";
/// How long `log stream` has to exit after SIGTERM before SIGKILL.
pub const STOP_GRACE: Duration = Duration::from_secs(2);

/// One completed signpost interval, for the summary.
#[derive(Debug, Clone, PartialEq)]
pub struct Interval {
    pub name: String,
    pub category: String,
    pub pid: i64,
    pub start_us: i64,
    pub ms: f64,
}

/// What a stream's lines held.
#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub events: Vec<Event>,
    pub intervals: Vec<Interval>,
    pub instants: usize,
    pub unpaired_begin: usize,
    pub unpaired_end: usize,
    /// `lossEvent` lines: logd dropped that many batches.
    pub lost: usize,
}

/// `key=value` words of a signpost message.
fn fields(message: &str) -> serde_json::Map<String, Value> {
    message
        .split_whitespace()
        .filter_map(|word| word.split_once('='))
        .map(|(key, value)| (key.to_owned(), Value::from(value)))
        .collect()
}

struct Begin {
    at: i64,
    tid: u64,
    message: String,
}

/// The signposts of `lines` between `start_us` and `end_us`.
pub fn parse<'a>(lines: impl IntoIterator<Item = &'a str>, start_us: i64, end_us: i64) -> Parsed {
    let mut parsed = Parsed::default();
    let mut open: HashMap<(i64, String, String, u64), Begin> = HashMap::new();
    for line in lines {
        let Ok(event) = serde_json::from_str::<Value>(line.trim()) else { continue };
        let text = |key: &str| event.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
        if text("eventType") == "lossEvent" {
            parsed.lost += 1;
            continue;
        }
        if text("eventType") != "signpostEvent" || text("subsystem") != SUBSYSTEM {
            continue;
        }
        let Some(at) = parse_timestamp(&text("timestamp")) else { continue };
        if at < start_us || at > end_us {
            continue;
        }
        let pid = event.get("processID").and_then(Value::as_i64).unwrap_or(0);
        let tid = event.get("threadID").and_then(Value::as_u64).unwrap_or(0);
        let id = event.get("signpostID").and_then(Value::as_u64).unwrap_or(0);
        let (name, category, message) =
            (text("signpostName"), text("category"), text("eventMessage"));
        let key = (pid, category.clone(), name.clone(), id);
        match text("signpostType").as_str() {
            "begin" => {
                open.insert(key, Begin { at, tid, message });
            }
            "end" => match open.remove(&key) {
                Some(begin) => {
                    let mut slice =
                        Event::slice(&name, &category, begin.at, at - begin.at, pid, begin.tid);
                    slice.args = fields(&begin.message);
                    for (field, value) in fields(&message) {
                        slice.args.insert(format!("end.{field}"), value);
                    }
                    parsed.intervals.push(Interval {
                        name: name.clone(),
                        category: category.clone(),
                        pid,
                        start_us: begin.at,
                        ms: (at - begin.at) as f64 / 1000.0,
                    });
                    parsed.events.push(slice);
                }
                None => {
                    parsed.unpaired_end += 1;
                    let instant = Event::instant(&name, &category, at, pid, tid)
                        .with_arg("unpaired", "end with no begin in the window");
                    parsed.events.push(instant);
                }
            },
            "event" => {
                let mut instant = Event::instant(&name, &category, at, pid, tid);
                instant.args = fields(&message);
                parsed.instants += 1;
                parsed.events.push(instant);
            }
            _ => {}
        }
    }
    for ((pid, category, name, _), begin) in open {
        parsed.unpaired_begin += 1;
        let instant = Event::instant(&name, &category, begin.at, pid, begin.tid)
            .with_arg("unpaired", "begin with no end in the window");
        parsed.events.push(instant);
    }
    parsed.events.sort_by_key(|event| event.ts);
    parsed
}

/// A running `log stream` and the thread that reads it.
pub struct Stream {
    child: Child,
    reader: JoinHandle<()>,
    lines: mpsc::Receiver<Vec<String>>,
}

impl Stream {
    /// Starts `log stream` for cmux's subsystem.
    pub fn start() -> std::io::Result<Self> {
        let mut child = Command::new("/usr/bin/log")
            .args(["stream", "--signpost", "--style", "ndjson", "--predicate"])
            .arg(format!("subsystem == \"{SUBSYSTEM}\""))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            // Its own process group: Ctrl-C reaches only the recorder, which then stops it in order.
            .process_group(0)
            .spawn()?;
        let stdout = child.stdout.take().ok_or_else(|| std::io::Error::other("no stdout"))?;
        let (send, lines) = mpsc::channel();
        // Reads for the whole window: a full pipe would block `log stream` and logd would drop events.
        let reader =
            std::thread::Builder::new().name("perf-signposts".to_owned()).spawn(move || {
                let mut kept = Vec::new();
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if line.starts_with('{') {
                        kept.push(line);
                    }
                }
                let _ = send.send(kept);
            })?;
        Ok(Self { child, reader, lines })
    }

    /// Ends the child by its pid and returns every line it printed, or why
    /// that failed. Each step has its deadline.
    pub fn stop(mut self) -> Result<Vec<String>, String> {
        let early = self.child.try_wait().ok().flatten();
        if early.is_none() {
            let pid = self.child.id() as libc::pid_t;
            // A waiter that sees the exit without reaping it (WNOWAIT): until
            // `wait` below reaps it, the pid stays this child's, so a SIGKILL
            // by pid can never reach another process.
            let (send, exited) = mpsc::channel();
            let _waiter = std::thread::spawn(move || {
                // SAFETY: an all-zero siginfo_t is a valid out buffer.
                let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
                // SAFETY: waitid on our own unreaped child with a valid out pointer.
                let _ = unsafe {
                    libc::waitid(
                        libc::P_PID,
                        pid as libc::id_t,
                        &mut info,
                        libc::WEXITED | libc::WNOWAIT,
                    )
                };
                let _ = send.send(());
            });
            // SAFETY: kill on our own child, not reaped yet.
            unsafe { libc::kill(pid, libc::SIGTERM) };
            let mut ended = exited.recv_timeout(STOP_GRACE).is_ok();
            if !ended {
                // SAFETY: as above.
                unsafe { libc::kill(pid, libc::SIGKILL) };
                ended = exited.recv_timeout(STOP_GRACE).is_ok();
            }
            if !ended {
                return Err("log stream did not end after SIGKILL".to_owned());
            }
            let _ = self.child.wait();
        }
        let lines = self
            .lines
            .recv_timeout(STOP_GRACE)
            .map_err(|_| "log stream did not close its output after it was stopped".to_owned());
        if lines.is_ok() {
            let _ = self.reader.join();
        }
        match (early, lines) {
            (Some(code), Ok(lines)) if lines.is_empty() && !code.success() => {
                Err(format!("log stream ended at once ({code})"))
            }
            (_, lines) => lines,
        }
    }
}

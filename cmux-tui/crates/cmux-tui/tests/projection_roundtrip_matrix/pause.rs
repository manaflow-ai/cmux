//! A machine paused under a live agent, then resumed (Leo, 2026-11-19: "we can investigate
//! pausing, you know, the auto pausing, like how reliable is it").
//!
//! A pause stops every process of the machine at once and the link to the Mac drops: the carrier
//! session ends with the machine's network. Here the machine's daemon (it serves the mount) and
//! the agent's shell get SIGSTOP, and the [`Relay`] the Mac dials through closes its streams and
//! refuses new ones until the resume. The agent reads a file it never read before every 50 ms, in
//! the mount, and appends to a notes file there, so every read after the resume goes to the Mac.
//!
//! Each case asserts what a person sees after the resume: no read fails (no `EHOSTDOWN` from a
//! link that came back late), the first read lands within the mount's wait for the Mac, and Bring
//! Back takes the agent's notes home. It prints its numbers as one `pause-numbers:` line.

use std::io::{BufRead as _, BufReader};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt as _;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use super::*;

/// The link between the Mac and the machine: a socket the Mac dials that passes its bytes to the
/// machine's, and, like `carrier serve`, beside it a quiet socket (`<path>.quiet`) when `quiet`.
/// Paused, it closes every stream it carries and closes each new dial unanswered, as the quiet
/// socket does while the machine sleeps.
pub(super) struct Relay {
    pub(super) path: PathBuf,
    paused: Arc<AtomicBool>,
    live: Arc<Mutex<Vec<UnixStream>>>,
}

impl Relay {
    pub(super) fn start(path: &Path, target: &Path, quiet: bool) -> Self {
        let relay = Self {
            path: path.to_path_buf(),
            paused: Arc::new(AtomicBool::new(false)),
            live: Arc::new(Mutex::new(Vec::new())),
        };
        relay.listen(UnixListener::bind(path).unwrap(), target);
        if quiet {
            let mut quiet_path = path.as_os_str().to_owned();
            quiet_path.push(".quiet");
            relay.listen(UnixListener::bind(PathBuf::from(quiet_path)).unwrap(), target);
        }
        relay
    }

    fn listen(&self, listener: UnixListener, target: &Path) {
        let (paused, live, target) = (self.paused.clone(), self.live.clone(), target.to_path_buf());
        std::thread::spawn(move || {
            for mac in listener.incoming() {
                let Ok(mac) = mac else { return };
                if paused.load(Ordering::SeqCst) {
                    continue; // dropped: closed unanswered
                }
                let Ok(machine) = UnixStream::connect(&target) else { continue };
                let (Ok(mac_in), Ok(machine_out), Ok(mac_keep), Ok(machine_keep)) =
                    (mac.try_clone(), machine.try_clone(), mac.try_clone(), machine.try_clone())
                else {
                    continue;
                };
                live.lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .extend([mac_keep, machine_keep]);
                pipe(mac_in, machine_out);
                pipe(machine, mac);
            }
        });
    }

    /// The machine's network goes: every stream ends, and dials are closed unanswered.
    pub(super) fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        for stream in self.live.lock().unwrap_or_else(PoisonError::into_inner).drain(..) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }

    pub(super) fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }
}

fn pipe(mut from: UnixStream, mut to: UnixStream) {
    std::thread::spawn(move || {
        let _ = std::io::copy(&mut from, &mut to);
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
}

/// The machine's processes: every one whose state folder is the machine's (its daemon and what
/// the daemon started).
fn machine_pids(state: &Path) -> Vec<String> {
    let mut wanted = b"CMUX_TUI_STATE_DIR=".to_vec();
    wanted.extend_from_slice(state.as_os_str().as_encoded_bytes());
    let mut pids = Vec::new();
    for entry in fs::read_dir("/proc").unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(environ) = fs::read(entry.path().join("environ")) else { continue };
        if environ.split(|&b| b == 0).any(|var| var == wanted.as_slice()) {
            pids.push(name);
        }
    }
    pids
}

fn signal(signal: &str, targets: &[String]) {
    if targets.is_empty() {
        return;
    }
    let status = Command::new("kill").arg(signal).arg("--").args(targets).status().unwrap();
    assert!(status.success(), "kill {signal} {targets:?}");
}

fn now_ns() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
}

/// How many files the agent may read: one folder each, so the mount's read-ahead of a folder's
/// small files never answers the next read from the cache.
const FILES: usize = 1500;

fn agent_files(side: &Side, at: &Path) {
    repo(side, at);
    for n in 0..FILES {
        write(&at.join(format!("p/d{n}/f")), &format!("file {n}\n"));
    }
    side.git(at, &["add", "-A"]);
    side.git(at, &["commit", "-qm", "agent files"]);
}

/// The agent: a shell in the mount, in a process group of its own, that reads `p/d<n>/f` and
/// appends to `notes.txt` every 50 ms, and logs `<ns> ok|err <n> <error>` outside the mount.
struct Agent {
    child: std::process::Child,
    log: PathBuf,
}

impl Agent {
    fn start(t: &Trip) -> Self {
        let log = t.root.join("agent.log");
        let script = format!(
            "n=0; while [ $n -lt {FILES} ]; do \
               t0=$(date +%s%N); \
               if out=$(cat p/d$n/f 2>&1) && echo \"read $n\" >> notes.txt; then \
                 echo \"$(date +%s%N) ok $n $t0\" >> {log}; \
               else echo \"$(date +%s%N) err $n $t0 $out\" >> {log}; fi; \
               n=$((n+1)); sleep 0.05; done",
            log = log.display()
        );
        let child = Command::new("sh")
            .args(["-c", &script])
            .current_dir(&t.folder)
            .env("HOME", &t.machine.side.home)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        Self { child, log }
    }

    fn group(&self) -> Vec<String> {
        vec![format!("-{}", self.child.id())]
    }

    /// Each read: when it ended (ns), whether it worked, how long it took (ms), and its error.
    fn reads(&self) -> Vec<(u128, bool, u128, String)> {
        let Ok(file) = fs::File::open(&self.log) else { return Vec::new() };
        BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            .filter_map(|line| {
                let mut parts = line.splitn(5, ' ');
                let at: u128 = parts.next()?.parse().ok()?;
                let ok = parts.next()? == "ok";
                let _n = parts.next();
                let started: u128 = parts.next()?.parse().ok()?;
                let took = at.saturating_sub(started) / 1_000_000;
                Some((at, ok, took, parts.next().unwrap_or("").to_owned()))
            })
            .collect()
    }

    fn stop(&mut self) {
        let _ = Command::new("kill").args(["-TERM", "--"]).args(self.group()).status();
        let _ = self.child.wait();
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = Command::new("kill").args(["-KILL", "--"]).args(self.group()).status();
        let _ = self.child.wait();
    }
}

/// The mount's wait for the Mac (`cmux_projection::link::AWAY_WAIT`): a read later than this
/// after the resume failed or nearly did.
const AWAY_WAIT: Duration = Duration::from_secs(5);

/// Pauses the machine `pauses` times for `hold` each under a live agent, its link back
/// `carrier_delay` after the machine resumes (the carrier reconnecting); asserts every read after
/// each resume worked, the first within [`AWAY_WAIT`] of the link's return, then Bring Back.
fn paused_under_an_agent(
    case: &str,
    quiet: bool,
    hold: Duration,
    pauses: usize,
    carrier_delay: Duration,
) {
    let t = match trip_with(case, true, Some(quiet), agent_files) {
        Ok(trip) => trip,
        Err(why) => {
            eprintln!("skipping: {why}");
            return;
        }
    };
    let relay = t.relay.as_ref().unwrap();
    let mut agent = Agent::start(&t);
    // The agent reads a while with the link up.
    std::thread::sleep(Duration::from_secs(2));
    let mut first_reads_ms = Vec::new();
    let mut longest_reads_ms = Vec::new();
    let mut failures = Vec::new();
    for _ in 0..pauses {
        let machine = machine_pids(&t.machine.side.state);
        assert!(!machine.is_empty(), "no process of the machine's found");
        relay.pause();
        signal("-STOP", &machine);
        signal("-STOP", &agent.group());
        std::thread::sleep(hold);
        let resumed = now_ns();
        signal("-CONT", &machine);
        signal("-CONT", &agent.group());
        std::thread::sleep(carrier_delay);
        relay.resume();
        // The agent's next reads.
        std::thread::sleep(AWAY_WAIT + Duration::from_secs(3));
        let after: Vec<_> = agent.reads().into_iter().filter(|(at, ..)| *at >= resumed).collect();
        let first_ok =
            after.iter().find(|(_, ok, ..)| *ok).map(|(at, ..)| (at - resumed) / 1_000_000);
        first_reads_ms.push(first_ok);
        longest_reads_ms.push(after.iter().map(|(_, _, took, _)| *took).max());
        failures.extend(
            after
                .iter()
                .filter(|(_, ok, ..)| !ok)
                .map(|(_, _, took, error)| format!("{took} ms: {error}")),
        );
    }
    agent.stop();
    let reads = agent.reads();
    let worked = reads.iter().filter(|(_, ok, ..)| *ok).count();
    eprintln!(
        "pause-numbers: {}",
        serde_json::json!({
            "case": case, "quiet": quiet, "hold_ms": hold.as_millis(), "pauses": pauses,
            "carrier_delay_ms": carrier_delay.as_millis(),
            "reads": reads.len(), "reads_ok": worked,
            "first_read_after_resume_ms": first_reads_ms, "longest_read_after_resume_ms": longest_reads_ms,
            "failures_after_resume": failures,
        })
    );
    assert!(failures.is_empty(), "reads failed after a resume: {failures:?}");
    for first in &first_reads_ms {
        let first = first.expect("no read worked after a resume");
        assert!(
            first < (carrier_delay + AWAY_WAIT).as_millis(),
            "the first read took {first} ms after the resume"
        );
    }
    // Bring Back after the pauses takes the agent's notes home.
    let notes = read(&t.at("notes.txt"));
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("notes.txt")), notes, "{answer}");
    t.statuses_agree();
}

/// A Cloud machine (a quiet socket beside the carrier's): paused briefly three times.
#[test]
fn a_cloud_machine_paused_under_an_agent_reads_and_brings_back_after_resume() {
    paused_under_an_agent("pause-quiet", true, Duration::from_secs(3), 3, Duration::ZERO);
}

/// A Cloud machine paused long enough for any backoff to reach its ceiling.
#[test]
fn a_cloud_machine_paused_long_under_an_agent_reads_after_resume() {
    paused_under_an_agent("pause-quiet-long", true, Duration::from_secs(30), 1, Duration::ZERO);
}

/// A machine of one's own, or an older carrier (no quiet socket): the Mac redials the socket
/// itself, with a backoff, so a long pause must not leave the first read waiting past the mount's
/// wait.
#[test]
fn a_machine_with_no_quiet_socket_paused_long_reads_after_resume() {
    paused_under_an_agent("pause-plain-long", false, Duration::from_secs(30), 1, Duration::ZERO);
}

/// A Cloud machine whose carrier reconnects 9 s after the resume (a Cloud machine's median is
/// 8.4 s): the agent's reads in the meantime wait for the link rather than fail with `EHOSTDOWN`
/// at the mount's 5 s wait.
#[test]
fn a_cloud_machine_whose_carrier_is_slow_after_resume_reads_without_failing() {
    paused_under_an_agent(
        "pause-slow-carrier",
        true,
        Duration::from_secs(3),
        1,
        Duration::from_secs(9),
    );
}

/// The slowest carrier reconnect seen on Cloud is 13.7 s: 15 s.
#[test]
fn a_cloud_machine_whose_carrier_takes_15_s_after_resume_reads_without_failing() {
    paused_under_an_agent(
        "pause-slower-carrier",
        true,
        Duration::from_secs(3),
        1,
        Duration::from_secs(15),
    );
}

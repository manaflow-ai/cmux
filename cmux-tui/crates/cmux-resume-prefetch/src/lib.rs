//! Working-set prefetch on a Cloud machine's resume (hq#21300).
//!
//! Freestyle restores a paused machine's memory lazily on the host: the guest runs at once, and each
//! guest page loads from the snapshot on its first touch (about 0.85 s per GiB, hq#17877; colder the
//! longer the pause). The guest cannot see those faults (the pages are guest-resident, so
//! `/proc/vmstat` and `mincore` say nothing), so the working set is recorded as the guest-resident
//! pages of the machine's processes (`/proc/PID/pagemap`'s present bit), and a prefetch is a read of
//! one byte from each of those pages (`process_vm_readv`, many threads), which makes the host load
//! them before the daemon, the agent or the shell needs them. `MADV_WILLNEED` would do nothing here:
//! to the guest those pages are already in memory.
//!
//! - [`record`] reads the page tables only: it loads no page.
//! - [`prefetch`] touches the recorded pages of the processes still alive (same pid and start time),
//!   in the plan's order: the terminal daemon first, then the agents, the shells, the rest.
//!
//! Linux only; elsewhere both return empty results.

use serde_json::{Value, json};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The plan file's version: a plan of another version is not read.
pub const PLAN_VERSION: u64 = 1;

/// Pages one `process_vm_readv` touches (IOV_MAX is 1024).
const BATCH_PAGES: usize = 512;

/// A process the plan names: a recycled pid with another start time is not this process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcPlan {
    pub pid: i32,
    /// `/proc/PID/stat` field 22, clock ticks after boot.
    pub start: u64,
    pub comm: String,
    /// Runs of resident pages: (first page's address, pages).
    pub ranges: Vec<(u64, u64)>,
}

impl ProcPlan {
    pub fn pages(&self) -> u64 {
        self.ranges.iter().map(|r| r.1).sum()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub page: u64,
    pub recorded_at_ms: u64,
    pub procs: Vec<ProcPlan>,
}

impl Plan {
    pub fn pages(&self) -> u64 {
        self.procs.iter().map(ProcPlan::pages).sum()
    }

    pub fn to_json(&self) -> Value {
        json!({
            "v": PLAN_VERSION,
            "page": self.page,
            "recorded_at_ms": self.recorded_at_ms,
            "procs": self.procs.iter().map(|p| json!({
                "pid": p.pid, "start": p.start, "comm": p.comm,
                "ranges": p.ranges.iter().map(|r| json!([r.0, r.1])).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        })
    }

    /// `None` for another version or a malformed plan (a plan is only ever a hint).
    pub fn from_json(v: &Value) -> Option<Plan> {
        if v["v"].as_u64() != Some(PLAN_VERSION) {
            return None;
        }
        let mut procs = Vec::new();
        for p in v["procs"].as_array()? {
            let mut ranges = Vec::new();
            for r in p["ranges"].as_array()? {
                ranges.push((r[0].as_u64()?, r[1].as_u64()?));
            }
            procs.push(ProcPlan {
                pid: i32::try_from(p["pid"].as_i64()?).ok()?,
                start: p["start"].as_u64()?,
                comm: p["comm"].as_str()?.to_owned(),
                ranges,
            });
        }
        Some(Plan {
            page: v["page"].as_u64()?,
            recorded_at_ms: v["recorded_at_ms"].as_u64().unwrap_or(0),
            procs,
        })
    }
}

/// What one prefetch did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    /// Pages the plan named.
    pub planned: u64,
    /// Pages read (each loaded on the host if it was cold).
    pub touched: u64,
    /// Processes of the plan that are gone or were replaced (their pages are skipped).
    pub stale_procs: u64,
    pub threads: usize,
    pub ms: u64,
    /// The deadline cut it short.
    pub cut: bool,
}

/// The order processes are prefetched in: what the first echo and the first reply need first.
pub fn rank(comm: &str) -> u8 {
    let c = comm.to_ascii_lowercase();
    if c.starts_with("cmux-tui") || c == "cmux" {
        0
    } else if ["claude", "node", "codex", "acpmux", "bun", "cmux-host", "cmux-vm-agent"]
        .iter()
        .any(|n| c.starts_with(n))
    {
        1
    } else if ["bash", "zsh", "sh", "fish", "dash"].contains(&c.as_str()) {
        2
    } else {
        3
    }
}

/// Coalesces present pages into runs. `entries` are pagemap words for consecutive pages from
/// `first`; bit 63 is "present".
pub fn present_runs(first: u64, page: u64, entries: &[u64], out: &mut Vec<(u64, u64)>) -> u64 {
    let mut n = 0;
    for (i, e) in entries.iter().enumerate() {
        if e >> 63 & 1 == 0 {
            continue;
        }
        n += 1;
        let addr = first + i as u64 * page;
        match out.last_mut() {
            Some(last) if last.0 + last.1 * page == addr => last.1 += 1,
            _ => out.push((addr, 1)),
        }
    }
    n
}

fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

pub fn page_size() -> u64 {
    #[cfg(target_os = "linux")]
    {
        // SAFETY: sysconf has no preconditions.
        let p = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        if p > 0 {
            return p as u64;
        }
    }
    4096
}

/// `/proc/PID/stat` field 22 (start time) and field 4 (parent pid).
pub fn proc_start(pid: i32) -> Option<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    s.rsplit_once(')')?.1.split_whitespace().nth(19)?.parse().ok()
}

fn proc_ppid(pid: i32) -> Option<i32> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    s.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
}

/// User processes (kernel threads have no address space to prefetch), this one excluded.
fn processes() -> Vec<(i32, String)> {
    let me = std::process::id() as i32;
    let Ok(dir) = std::fs::read_dir("/proc") else { return Vec::new() };
    let mut out = Vec::new();
    for e in dir.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else {
            continue;
        };
        if pid == me || pid == 2 || proc_ppid(pid) == Some(2) {
            continue;
        }
        let comm = std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .unwrap_or_default()
            .trim()
            .to_owned();
        out.push((pid, comm));
    }
    out
}

/// One process's resident pages, at most `budget` of them.
#[cfg(target_os = "linux")]
fn resident(pid: i32, page: u64, budget: u64) -> Vec<(u64, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut out = Vec::new();
    let Ok(maps) = std::fs::read_to_string(format!("/proc/{pid}/maps")) else { return out };
    let Ok(mut pm) = std::fs::File::open(format!("/proc/{pid}/pagemap")) else { return out };
    let mut n = 0u64;
    let mut buf = vec![0u8; 8 * 8192];
    for line in maps.lines() {
        let mut f = line.split_whitespace();
        let (Some(span), Some(perms)) = (f.next(), f.next()) else { continue };
        let name = line.split_whitespace().nth(5).unwrap_or("");
        if !perms.starts_with('r')
            || matches!(name, "[vvar]" | "[vsyscall]" | "[vdso]" | "[vvar_vclock]")
        {
            continue;
        }
        let Some((a, b)) = span.split_once('-') else { continue };
        let (Ok(start), Ok(end)) = (u64::from_str_radix(a, 16), u64::from_str_radix(b, 16)) else {
            continue;
        };
        let mut at = start;
        while at < end && n < budget {
            let count = (((end - at) / page) as usize).min(buf.len() / 8);
            if count == 0 || pm.seek(SeekFrom::Start(at / page * 8)).is_err() {
                break;
            }
            let bytes = &mut buf[..count * 8];
            if pm.read_exact(bytes).is_err() {
                break;
            }
            let words: Vec<u64> = bytes
                .chunks_exact(8)
                .map(|c| u64::from_ne_bytes(c.try_into().unwrap_or([0; 8])))
                .collect();
            n += present_runs(at, page, &words, &mut out);
            at += count as u64 * page;
        }
        if n >= budget {
            break;
        }
    }
    out
}

#[cfg(not(target_os = "linux"))]
fn resident(_pid: i32, _page: u64, _budget: u64) -> Vec<(u64, u64)> {
    Vec::new()
}

/// Records the guest-resident pages of every user process, in [`rank`] order (larger first within a
/// rank), at most `max_pages` in all. Reads page tables only.
pub fn record(max_pages: u64) -> Plan {
    let page = page_size();
    let mut procs: Vec<ProcPlan> = processes()
        .into_iter()
        .filter_map(|(pid, comm)| {
            Some(ProcPlan { pid, start: proc_start(pid)?, comm, ranges: Vec::new() })
        })
        .collect();
    let mut left = max_pages;
    for p in &mut procs {
        if left == 0 {
            break;
        }
        p.ranges = resident(p.pid, page, left);
        left = left.saturating_sub(p.pages());
    }
    procs.retain(|p| !p.ranges.is_empty());
    procs.sort_by_key(|p| (rank(&p.comm), std::cmp::Reverse(p.pages())));
    Plan { page, recorded_at_ms: wall_ms(), procs }
}

/// The batches of page addresses, per process, in plan order.
fn batches(plan: &Plan, live: &[bool]) -> Vec<(i32, Vec<u64>)> {
    let mut out = Vec::new();
    for (p, ok) in plan.procs.iter().zip(live) {
        if !ok {
            continue;
        }
        let mut cur = Vec::with_capacity(BATCH_PAGES);
        for &(addr, n) in &p.ranges {
            for i in 0..n {
                cur.push(addr + i * plan.page);
                if cur.len() == BATCH_PAGES {
                    out.push((p.pid, std::mem::take(&mut cur)));
                }
            }
        }
        if !cur.is_empty() {
            out.push((p.pid, cur));
        }
    }
    out
}

/// Reads one byte of each page; returns the pages read. A page unmapped since the record ends one
/// call early; the rest of the batch still goes.
#[cfg(target_os = "linux")]
fn touch(pid: i32, pages: &[u64], scratch: &mut [u8]) -> u64 {
    let mut done = 0u64;
    let mut i = 0usize;
    while i < pages.len() {
        let rest = &pages[i..];
        let remote: Vec<libc::iovec> = rest
            .iter()
            .map(|&a| libc::iovec { iov_base: a as *mut libc::c_void, iov_len: 1 })
            .collect();
        let local = libc::iovec {
            iov_base: scratch.as_mut_ptr().cast(),
            iov_len: rest.len().min(scratch.len()),
        };
        // SAFETY: `local` points into `scratch` with at most its length; the remote iovecs are only
        // read by the kernel, which checks them against the target's address space.
        let r = unsafe {
            libc::process_vm_readv(
                pid,
                &local,
                1,
                remote.as_ptr(),
                remote.len() as libc::c_ulong,
                0,
            )
        };
        if r < 0 {
            // The first page failed (unmapped since, or the process is gone): skip it.
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                break;
            }
            i += 1;
            continue;
        }
        let r = r as usize;
        done += r as u64;
        i += r;
        if r < rest.len() {
            i += 1;
        }
    }
    done
}

#[cfg(not(target_os = "linux"))]
fn touch(_pid: i32, _pages: &[u64], _scratch: &mut [u8]) -> u64 {
    0
}

/// Touches the plan's pages with `threads` threads, front first, until done or `deadline`.
pub fn prefetch(plan: &Plan, threads: usize, deadline: Duration) -> Outcome {
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    let began = Instant::now();
    let live: Vec<bool> = plan.procs.iter().map(|p| proc_start(p.pid) == Some(p.start)).collect();
    let work = batches(plan, &live);
    let next = AtomicUsize::new(0);
    let touched = AtomicU64::new(0);
    let cut = AtomicBool::new(false);
    let threads = threads.clamp(1, 64);
    std::thread::scope(|s| {
        for _ in 0..threads {
            s.spawn(|| {
                let mut scratch = vec![0u8; BATCH_PAGES];
                loop {
                    if began.elapsed() >= deadline {
                        cut.store(true, Ordering::Relaxed);
                        return;
                    }
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some((pid, pages)) = work.get(i) else { return };
                    touched.fetch_add(touch(*pid, pages, &mut scratch), Ordering::Relaxed);
                }
            });
        }
    });
    Outcome {
        planned: plan.pages(),
        touched: touched.into_inner(),
        stale_procs: live.iter().filter(|ok| !**ok).count() as u64,
        threads,
        ms: began.elapsed().as_millis() as u64,
        cut: cut.into_inner(),
    }
}

impl Outcome {
    pub fn to_json(&self) -> Value {
        json!({
            "planned": self.planned, "touched": self.touched, "stale_procs": self.stale_procs,
            "threads": self.threads, "ms": self.ms, "cut": self.cut,
        })
    }
}

#[cfg(test)]
mod tests;

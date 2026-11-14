use crate::panic_free::RecoverPoison;
use std::collections::{BTreeMap, HashMap, HashSet};
#[cfg(all(test, target_os = "linux"))]
use std::io::Read;
use std::io::Write;
#[cfg(any(windows, all(test, target_os = "linux")))]
use std::mem::size_of;
#[cfg(unix)]
use std::os::fd::AsRawFd;
#[cfg(all(test, target_os = "linux"))]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(any(not(unix), all(test, target_os = "linux")))]
use std::process::Command;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak, mpsc};
use std::time::{Duration, Instant};

use regex::bytes::{Regex, RegexBuilder};
use serde_json::json;
#[cfg(windows)]
use wait_timeout::ChildExt;
#[cfg(windows)]
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
#[cfg(windows)]
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
};
#[cfg(windows)]
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
#[cfg(windows)]
use windows_sys::Win32::System::Threading::{
    CREATE_SUSPENDED, OpenProcess, OpenThread, PROCESS_SET_QUOTA, PROCESS_TERMINATE, ResumeThread,
    THREAD_SUSPEND_RESUME,
};

use crate::journal_kernel::{JournalDocument, SharedJournalRead};
#[cfg(unix)]
use crate::unix_process_scope::{UnixChildExitSignal, UnixProcessScope};
use crate::workspace_registry::{
    JournalHookAttempt, JournalHookDelivery, JournalHookDeliveryResult, JournalHookScan,
    JournalHookState, SessionJournalReader,
};
use crate::{JournalHookManifest, JournalSensitivity, Mux};

// Bound one dispatcher transaction so hook discovery cannot monopolize the
// registry writer while producer events are waiting for durable receipts.
const HOOK_SCAN_PAGE_SIZE: usize = 256;
const MIN_DELIVERY_WORKERS: usize = 4;
const MAX_DELIVERY_WORKERS: usize = 32;
pub(crate) const SHUTDOWN_WAIT: Duration = Duration::from_secs(2);

#[derive(Default)]
struct JournalHookRuntimeState {
    running: bool,
    shutdown: bool,
}

/// Session-owned cancellation and completion fence for the dispatcher and all
/// hook workers. Mux shutdown sets cancellation before it closes any journal
/// source and waits for this runtime to release every active process scope.
#[derive(Default)]
pub(crate) struct JournalHookRuntime {
    cancelled: AtomicBool,
    state: Mutex<JournalHookRuntimeState>,
    changed: Condvar,
}

impl JournalHookRuntime {
    fn begin(&self) -> bool {
        let mut state = self.state.lock().recover_poison();
        if state.shutdown || state.running {
            return false;
        }
        state.running = true;
        self.cancelled.store(false, Ordering::Release);
        true
    }

    fn finish(&self) {
        let mut state = self.state.lock().recover_poison();
        state.running = false;
        self.changed.notify_all();
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    pub(crate) fn shutdown_until(&self, deadline: Instant) -> bool {
        self.cancelled.store(true, Ordering::Release);
        let mut state = self.state.lock().recover_poison();
        state.shutdown = true;
        while state.running {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next, timeout) = self.changed.wait_timeout(state, remaining).recover_poison();
            state = next;
            if timeout.timed_out() && state.running {
                return false;
            }
        }
        true
    }
}

struct JournalHookRuntimeGuard(Arc<JournalHookRuntime>);

impl Drop for JournalHookRuntimeGuard {
    fn drop(&mut self) {
        self.0.finish();
    }
}

#[cfg(windows)]
struct WindowsHookJob {
    handle: HANDLE,
}

#[cfg(windows)]
impl WindowsHookJob {
    fn assign(child: &std::process::Child) -> std::io::Result<Self> {
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let job = Self { handle };
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let information_size = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
            .expect("Windows job information fits in u32");
        if unsafe {
            SetInformationJobObject(
                job.handle,
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&information).cast(),
                information_size,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error());
        }

        let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, child.id()) };
        if process.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let assigned = unsafe { AssignProcessToJobObject(job.handle, process) };
        let assign_error = (assigned == 0).then(std::io::Error::last_os_error);
        unsafe {
            CloseHandle(process);
        }
        if let Some(error) = assign_error {
            return Err(error);
        }
        Ok(job)
    }

    fn terminate_descendants(&self) {
        unsafe {
            TerminateJobObject(self.handle, 1);
        }
    }

    fn terminate_and_wait(&self, child: &mut std::process::Child) {
        self.terminate_descendants();
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(windows)]
fn resume_suspended_hook_child(child: &std::process::Child) -> std::io::Result<()> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error());
    }
    let result = (|| {
        let mut thread_entry = THREADENTRY32 {
            dwSize: u32::try_from(size_of::<THREADENTRY32>())
                .expect("Windows thread entry size fits in u32"),
            ..THREADENTRY32::default()
        };
        if unsafe { Thread32First(snapshot, &mut thread_entry) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        loop {
            if thread_entry.th32OwnerProcessID == child.id() {
                let thread =
                    unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, thread_entry.th32ThreadID) };
                if thread.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                let resume_result = unsafe { ResumeThread(thread) };
                let resume_error = (resume_result == u32::MAX).then(std::io::Error::last_os_error);
                unsafe {
                    CloseHandle(thread);
                }
                return resume_error.map_or(Ok(()), Err);
            }
            if unsafe { Thread32Next(snapshot, &mut thread_entry) } == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "suspended hook process has no thread to resume",
                ));
            }
        }
    })();
    unsafe {
        CloseHandle(snapshot);
    }
    result
}

#[cfg(windows)]
impl Drop for WindowsHookJob {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct HookVersion {
    hook_id: String,
    manifest_version: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct DeliveryKey {
    hook: HookVersion,
    event_id: String,
}

struct DeliveryJob {
    key: DeliveryKey,
    delivery: JournalHookDelivery,
    attempt: JournalHookAttempt,
}

struct DeliveryCompletion {
    key: DeliveryKey,
    result: JournalHookDeliveryResult,
}

struct DeliveryWorkers {
    sender: mpsc::Sender<DeliveryJob>,
    completions: mpsc::Receiver<DeliveryCompletion>,
    capacity: usize,
    handles: Vec<std::thread::JoinHandle<()>>,
}

struct CompiledHook {
    manifest: JournalHookManifest,
    cursor_sequence: u64,
    filter: CompiledHookFilter,
}

struct CompiledHookFilter {
    exact_kinds: HashSet<String>,
    kind_prefixes: Vec<String>,
    classes: [bool; 4],
    has_class_filter: bool,
    subject_kinds: HashSet<String>,
    max_sensitivity: JournalSensitivity,
    regex: Option<CompiledHookRegex>,
}

enum HookRegexField {
    Kind,
    Subjects,
    Payload,
    Record,
    TerminalOutput,
}

struct CompiledHookRegex {
    field: HookRegexField,
    matcher: Regex,
}

/// Starts one session-owned dispatcher. The dispatcher keeps only a weak mux
/// reference, so it cannot prolong the session lifetime.
pub(crate) fn start(mux: &Arc<Mux>) -> anyhow::Result<()> {
    if !mux.shared_journal_enabled() || mux.daemon_shutdown_requested() {
        return Ok(());
    }
    if !mux.journal_hook_states()?.iter().any(|state| state.enabled)
        || !mux.try_claim_journal_hook_dispatcher()
    {
        return Ok(());
    }
    let runtime = mux.journal_hook_runtime();
    if !runtime.begin() {
        mux.release_journal_hook_dispatcher();
        return Ok(());
    }
    let weak = Arc::downgrade(mux);
    let thread_runtime = runtime.clone();
    let spawned =
        std::thread::Builder::new().name("mux-session-journal-hooks".into()).spawn(move || {
            let _runtime_guard = JournalHookRuntimeGuard(thread_runtime.clone());
            let mut claim = DispatcherClaim::new(weak.clone());
            run_dispatcher(weak, &mut claim, thread_runtime);
        });
    if let Err(error) = spawned {
        runtime.finish();
        mux.release_journal_hook_dispatcher();
        return Err(error.into());
    }
    Ok(())
}

struct DispatcherClaim {
    mux: Weak<Mux>,
    claimed: bool,
}

impl DispatcherClaim {
    const fn new(mux: Weak<Mux>) -> Self {
        Self { mux, claimed: true }
    }

    fn release(&mut self) {
        if self.claimed {
            if let Some(mux) = self.mux.upgrade() {
                mux.release_journal_hook_dispatcher();
            }
            self.claimed = false;
        }
    }

    fn reclaim(&mut self, mux: &Mux) -> bool {
        self.claimed = mux.try_claim_journal_hook_dispatcher();
        self.claimed
    }
}

impl Drop for DispatcherClaim {
    fn drop(&mut self) {
        self.release();
    }
}

fn delivery_worker_count(available_parallelism: usize) -> usize {
    available_parallelism.saturating_mul(2).clamp(MIN_DELIVERY_WORKERS, MAX_DELIVERY_WORKERS)
}

fn start_delivery_workers(
    journal: &Arc<crate::journal_kernel::JournalKernel>,
    runtime: &Arc<JournalHookRuntime>,
) -> anyhow::Result<DeliveryWorkers> {
    let requested = delivery_worker_count(
        std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get),
    );
    let (job_tx, job_rx) = mpsc::channel::<DeliveryJob>();
    let job_rx = Arc::new(Mutex::new(job_rx));
    let (completion_tx, completion_rx) = mpsc::channel::<DeliveryCompletion>();
    let mut capacity = 0;
    let mut handles = Vec::with_capacity(requested);
    for index in 0..requested {
        let jobs = job_rx.clone();
        let completions = completion_tx.clone();
        let journal = journal.clone();
        let runtime = runtime.clone();
        let spawned = std::thread::Builder::new()
            .name(format!("journal-hook-worker-{index}"))
            .spawn(move || run_delivery_worker(&jobs, &completions, &journal, &runtime));
        match spawned {
            Ok(handle) => {
                capacity += 1;
                handles.push(handle);
            }
            Err(error) if capacity == 0 => return Err(error.into()),
            Err(_) => break,
        }
    }
    drop(completion_tx);
    Ok(DeliveryWorkers { sender: job_tx, completions: completion_rx, capacity, handles })
}

fn run_delivery_worker(
    jobs: &Mutex<mpsc::Receiver<DeliveryJob>>,
    completions: &mpsc::Sender<DeliveryCompletion>,
    journal: &crate::journal_kernel::JournalKernel,
    runtime: &JournalHookRuntime,
) {
    loop {
        let job = match jobs.lock().recover_poison().recv() {
            Ok(job) => job,
            Err(_) => return,
        };
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            execute_delivery_with_shutdown(&job.delivery, &job.attempt, &runtime.cancelled)
        }))
        .unwrap_or_else(|_| (None, Some("hook worker panicked".into())));
        let result = JournalHookDeliveryResult {
            delivery: job.delivery,
            attempt: job.attempt.attempt,
            exit_code: outcome.0,
            error: outcome.1,
        };
        if completions.send(DeliveryCompletion { key: job.key, result }).is_err() {
            return;
        }
        journal.wake_waiters();
    }
}

fn run_dispatcher(mux: Weak<Mux>, claim: &mut DispatcherClaim, runtime: Arc<JournalHookRuntime>) {
    let Some(initial_mux) = mux.upgrade() else { return };
    let Ok(mut workers) = start_delivery_workers(&initial_mux.shared_journal_handle(), &runtime)
    else {
        return;
    };
    drop(initial_mux);
    let mut hooks = HashMap::<HookVersion, CompiledHook>::new();
    let mut active = HashSet::<DeliveryKey>::new();
    let mut completed = Vec::<DeliveryCompletion>::new();
    let mut catch_up_reader = None;
    let mut epoch = 0;
    // Spacing for retries after a registry failure; the dispatcher otherwise
    // waits for a journal commit, a worker completion (workers wake the
    // journal), shutdown, or the next scheduled retry. It used to wake every
    // second while any hook was enabled.
    let mut failure_backoff =
        crate::backoff::Backoff::new(Duration::from_millis(100), Duration::from_secs(5));

    loop {
        let Some(mux) = mux.upgrade() else { return };
        epoch = mux.shared_journal_epoch().max(epoch);

        if runtime.is_cancelled() || mux.daemon_shutdown_requested() {
            drop(mux);
            workers.shutdown();
            // Do not commit a completion after Mux shutdown can close the
            // journal writer. Executing rows remain durable and a replacement
            // dispatcher can retry them under the existing at-least-once rule.
            return;
        }

        while let Ok(completion) = workers.completions.try_recv() {
            completed.push(completion);
        }
        if !completed.is_empty() {
            let results =
                completed.iter().map(|completion| completion.result.clone()).collect::<Vec<_>>();
            if mux.finish_journal_hook_deliveries(&results).is_ok() {
                for completion in completed.drain(..) {
                    active.remove(&completion.key);
                }
            } else {
                let journal = mux.shared_journal_handle();
                drop(mux);
                epoch = journal.wait(epoch, failure_backoff.next_delay());
                continue;
            }
        }

        let states = match mux.journal_hook_states() {
            Ok(states) => states,
            Err(_) => {
                let journal = mux.shared_journal_handle();
                drop(mux);
                epoch = journal.wait(epoch, failure_backoff.next_delay());
                continue;
            }
        };
        refresh_compiled_hooks(&mut hooks, states);

        if hooks.is_empty() && active.is_empty() {
            claim.release();
            let enabled = mux
                .journal_hook_states()
                .is_ok_and(|states| states.iter().any(|state| state.enabled));
            if enabled && claim.reclaim(&mux) {
                continue;
            }
            return;
        }

        // A failed scan schedules a retry through the failure backoff below;
        // the wait has no other deadline that would bring it back.
        let mut start_failed = false;
        if scan_hooks(&mux, &mut hooks, &mut catch_up_reader, &runtime).is_err() {
            catch_up_reader = None;
            start_failed = true;
        }
        if runtime.is_cancelled() || mux.daemon_shutdown_requested() {
            continue;
        }

        // Taken before the pending query: a retry that comes due after this
        // instant was invisible to the query, and its deadline must stay in
        // the future of `now` so the wait below returns for it.
        let now = Instant::now();
        if active.len() < workers.capacity {
            let capacity = workers.capacity - active.len();
            // The query includes executing rows so a replacement dispatcher
            // can retry them. Ask for the complete worker window, otherwise
            // active rows can consume the limit and leave idle workers empty.
            let pending = mux.pending_journal_hook_deliveries(workers.capacity);
            start_failed |= pending.is_err();
            if let Ok(deliveries) = pending {
                let mut per_hook = HashMap::<HookVersion, usize>::new();
                for key in &active {
                    *per_hook.entry(key.hook.clone()).or_default() += 1;
                }
                let mut selected = Vec::with_capacity(deliveries.len().min(capacity));
                for delivery in deliveries {
                    let hook = HookVersion {
                        hook_id: delivery.manifest.hook_id.clone(),
                        manifest_version: delivery.manifest.manifest_version,
                    };
                    let key = DeliveryKey {
                        hook: hook.clone(),
                        event_id: delivery.event.event_id.clone(),
                    };
                    if active.contains(&key)
                        || active.len() + selected.len() >= workers.capacity
                        || per_hook.get(&hook).copied().unwrap_or_default()
                            >= usize::from(delivery.manifest.exec.max_parallel)
                    {
                        continue;
                    }
                    *per_hook.entry(hook).or_default() += 1;
                    selected.push((key, delivery));
                }
                if !selected.is_empty() {
                    let deliveries =
                        selected.iter().map(|(_, delivery)| delivery.clone()).collect::<Vec<_>>();
                    let started = mux.start_journal_hook_deliveries(&deliveries);
                    start_failed |= started.is_err();
                    if let Ok(attempts) = started {
                        for ((key, delivery), attempt) in selected.into_iter().zip(attempts) {
                            active.insert(key.clone());
                            if runtime.is_cancelled() || mux.daemon_shutdown_requested() {
                                completed.push(DeliveryCompletion {
                                    key,
                                    result: JournalHookDeliveryResult {
                                        delivery,
                                        attempt: attempt.attempt,
                                        exit_code: None,
                                        error: Some("hook canceled during daemon shutdown".into()),
                                    },
                                });
                            } else if let Err(error) = workers.sender.send(DeliveryJob {
                                key: key.clone(),
                                delivery: delivery.clone(),
                                attempt: attempt.clone(),
                            }) {
                                completed.push(DeliveryCompletion {
                                    key,
                                    result: JournalHookDeliveryResult {
                                        delivery,
                                        attempt: attempt.attempt,
                                        exit_code: None,
                                        error: Some(format!("hook worker pool stopped: {error}")),
                                    },
                                });
                            }
                        }
                    }
                }
            }
        }

        // A one-shot deadline for the next scheduled retry, or none. A retry
        // that is already due but waits for a worker or a per-hook slot
        // starts when a completion wakes the journal, so a past deadline
        // must not become an immediate re-loop.
        if !start_failed {
            failure_backoff.reset();
        }
        let deadline = match mux.next_journal_hook_attempt_deadline() {
            _ if start_failed => Some(now + failure_backoff.next_delay()),
            Ok(deadline) => deadline.filter(|deadline| *deadline > now),
            Err(_) => Some(now + failure_backoff.next_delay()),
        };
        let journal = mux.shared_journal_handle();
        drop(mux);
        epoch = journal.wait_until(epoch, deadline);
    }
}

impl DeliveryWorkers {
    fn shutdown(&mut self) {
        let (closed, _) = mpsc::channel();
        let sender = std::mem::replace(&mut self.sender, closed);
        drop(sender);
        for handle in self.handles.drain(..) {
            if handle.join().is_err() {
                eprintln!("cmux-tui: journal hook worker panicked during shutdown");
            }
        }
    }
}

fn refresh_compiled_hooks(
    hooks: &mut HashMap<HookVersion, CompiledHook>,
    states: Vec<JournalHookState>,
) {
    let enabled = states
        .iter()
        .filter(|state| state.enabled)
        .map(|state| HookVersion {
            hook_id: state.manifest.hook_id.clone(),
            manifest_version: state.manifest.manifest_version,
        })
        .collect::<HashSet<_>>();
    hooks.retain(|key, _| enabled.contains(key));
    for state in states.into_iter().filter(|state| state.enabled) {
        let key = HookVersion {
            hook_id: state.manifest.hook_id.clone(),
            manifest_version: state.manifest.manifest_version,
        };
        if let Some(hook) = hooks.get_mut(&key) {
            if hook.manifest != state.manifest {
                let Ok(filter) = CompiledHookFilter::new(&state.manifest) else { continue };
                hook.filter = filter;
            }
            hook.cursor_sequence = state.cursor_sequence;
            hook.manifest = state.manifest;
            continue;
        }
        let Ok(filter) = CompiledHookFilter::new(&state.manifest) else { continue };
        hooks.insert(
            key,
            CompiledHook {
                manifest: state.manifest,
                cursor_sequence: state.cursor_sequence,
                filter,
            },
        );
    }
}

fn scan_hooks(
    mux: &Mux,
    hooks: &mut HashMap<HookVersion, CompiledHook>,
    catch_up_reader: &mut Option<SessionJournalReader>,
    runtime: &JournalHookRuntime,
) -> anyhow::Result<()> {
    loop {
        if runtime.is_cancelled() || mux.daemon_shutdown_requested() {
            return Ok(());
        }
        let mut cursor_groups = BTreeMap::<u64, Vec<HookVersion>>::new();
        for (key, hook) in hooks.iter() {
            cursor_groups.entry(hook.cursor_sequence).or_default().push(key.clone());
        }
        let mut progressed = false;
        for (cursor, keys) in cursor_groups {
            if runtime.is_cancelled() || mux.daemon_shutdown_requested() {
                return Ok(());
            }
            let page = hook_page(mux, cursor, catch_up_reader)?;
            if page.records.is_empty() {
                continue;
            }
            let Some(scanned_to) = page.records.last().map(|document| document.record.sequence)
            else {
                continue;
            };
            anyhow::ensure!(scanned_to > cursor, "journal hook scan did not advance its cursor");
            let causal_candidates = page
                .records
                .iter()
                .filter(|document| document.record.causation_id.is_some())
                .map(|document| document.record.event_id.clone())
                .collect::<Vec<_>>();
            let causal_hook_ids = keys
                .iter()
                .filter_map(|key| hooks.get(key))
                .filter(|hook| !hook.manifest.filter.include_causal_descendants)
                .map(|hook| hook.manifest.hook_id.clone())
                .collect::<Vec<_>>();
            let causal_descendants = mux
                .journal_events_caused_by_hooks(&causal_hook_ids, &causal_candidates)?
                .into_iter()
                .fold(
                    HashMap::<String, HashSet<String>>::new(),
                    |mut descendants, (hook_id, event_id)| {
                        descendants.entry(hook_id).or_default().insert(event_id);
                        descendants
                    },
                );
            let scans =
                keys.iter()
                    .filter_map(|key| hooks.get(key))
                    .map(|hook| JournalHookScan {
                        hook_id: hook.manifest.hook_id.clone(),
                        manifest_version: hook.manifest.manifest_version,
                        expected_cursor: cursor,
                        scanned_to,
                        matches: page
                            .records
                            .iter()
                            .filter(|document| {
                                !causal_descendants.get(&hook.manifest.hook_id).is_some_and(
                                    |events| events.contains(&document.record.event_id),
                                ) && hook.filter.matches(&hook.manifest, document)
                            })
                            .map(|document| {
                                (document.record.event_id.clone(), document.record.sequence)
                            })
                            .collect(),
                    })
                    .collect::<Vec<_>>();
            let applied = mux.schedule_journal_hook_deliveries(&scans)?;
            anyhow::ensure!(applied.len() == keys.len(), "journal hook scan result is incomplete");
            for (key, applied) in keys.iter().zip(applied) {
                if applied && let Some(hook) = hooks.get_mut(key) {
                    hook.cursor_sequence = scanned_to;
                    progressed = true;
                }
            }
        }
        if !progressed {
            return Ok(());
        }
    }
}

struct HookPage {
    records: Vec<Arc<JournalDocument>>,
}

fn hook_page(
    mux: &Mux,
    cursor: u64,
    catch_up_reader: &mut Option<SessionJournalReader>,
) -> anyhow::Result<HookPage> {
    match mux.shared_journal_after(cursor, HOOK_SCAN_PAGE_SIZE) {
        SharedJournalRead::Page(page) => Ok(HookPage { records: page.records }),
        SharedJournalRead::Gap { .. } | SharedJournalRead::Unavailable => {
            if catch_up_reader.is_none() {
                *catch_up_reader = mux.session_journal_reader()?;
            }
            let reader = catch_up_reader
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("journal catch-up reader is unavailable"))?;
            reader.after(cursor, HOOK_SCAN_PAGE_SIZE).map(|page| HookPage {
                records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
            })
        }
    }
}

impl CompiledHookFilter {
    fn new(manifest: &JournalHookManifest) -> anyhow::Result<Self> {
        let mut exact_kinds = HashSet::new();
        let mut kind_prefixes = Vec::new();
        for kind in &manifest.filter.kinds {
            if let Some(prefix) = kind.strip_suffix(".*") {
                kind_prefixes.push(format!("{prefix}."));
            } else {
                exact_kinds.insert(kind.clone());
            }
        }
        let mut classes = [false; 4];
        for class in &manifest.filter.classes {
            if let Some(slot) = classes.get_mut(class_index(*class)) {
                *slot = true;
            }
        }
        let has_class_filter = !manifest.filter.classes.is_empty();
        let subject_kinds = manifest.filter.subject_kinds.iter().cloned().collect();
        let max_sensitivity =
            manifest.filter.max_sensitivity.unwrap_or(JournalSensitivity::Metadata);
        let regex = manifest
            .filter
            .regex
            .as_ref()
            .map(|regex| {
                let field = match regex.field.as_str() {
                    "kind" => HookRegexField::Kind,
                    "subjects" => HookRegexField::Subjects,
                    "payload" => HookRegexField::Payload,
                    "record" => HookRegexField::Record,
                    "terminal_output" => HookRegexField::TerminalOutput,
                    _ => anyhow::bail!("invalid hook regex field"),
                };
                let matcher = RegexBuilder::new(&regex.pattern)
                    .case_insensitive(!regex.case_sensitive)
                    .size_limit(1 << 20)
                    .dfa_size_limit(2 << 20)
                    .build()?;
                Ok(CompiledHookRegex { field, matcher })
            })
            .transpose()?;
        Ok(Self {
            exact_kinds,
            kind_prefixes,
            classes,
            has_class_filter,
            subject_kinds,
            max_sensitivity,
            regex,
        })
    }

    fn matches(&self, manifest: &JournalHookManifest, document: &JournalDocument) -> bool {
        let record = &document.record;
        if !manifest.filter.include_causal_descendants
            && (record.kind.starts_with("hook.")
                || record
                    .subjects
                    .iter()
                    .any(|subject| subject.kind == "hook" && subject.id == manifest.hook_id))
        {
            return false;
        }
        if (!self.exact_kinds.is_empty() || !self.kind_prefixes.is_empty())
            && !self.exact_kinds.contains(&record.kind)
            && !self.kind_prefixes.iter().any(|prefix| record.kind.starts_with(prefix))
        {
            return false;
        }
        if self.has_class_filter
            && !self.classes.get(class_index(record.class)).copied().unwrap_or(false)
        {
            return false;
        }
        if !self.subject_kinds.is_empty()
            && !record.subjects.iter().any(|subject| self.subject_kinds.contains(&subject.kind))
        {
            return false;
        }
        if sensitivity_rank(record.sensitivity) > sensitivity_rank(self.max_sensitivity) {
            return false;
        }
        self.regex.as_ref().is_none_or(|regex| regex.matches(document))
    }
}

impl CompiledHookRegex {
    fn matches(&self, document: &JournalDocument) -> bool {
        match self.field {
            HookRegexField::Kind => self.matcher.is_match(document.record.kind.as_bytes()),
            HookRegexField::Subjects => self.matcher.is_match(document.subjects_bytes()),
            HookRegexField::Payload => {
                document.payload_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
            HookRegexField::Record => {
                document.record_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
            HookRegexField::TerminalOutput => {
                document.terminal_output_bytes().is_some_and(|bytes| self.matcher.is_match(bytes))
            }
        }
    }
}

fn execute_delivery_with_shutdown(
    delivery: &JournalHookDelivery,
    attempt: &JournalHookAttempt,
    cancelled: &AtomicBool,
) -> (Option<i32>, Option<String>) {
    if cancelled.load(Ordering::Acquire) {
        return hook_shutdown_result();
    }
    let argv = &delivery.manifest.exec.argv;
    let Some((program, arguments)) = argv.split_first() else {
        return (None, Some("hook argv is empty".into()));
    };
    let session_id = delivery
        .event
        .subjects
        .iter()
        .find(|subject| subject.kind == "session")
        .map(|subject| subject.id.as_str());
    let envelope = json!({
        "protocol_version":1,
        "delivery":{
            "delivery_id":format!(
                "{}:{}:{}",
                delivery.manifest.hook_id,
                delivery.manifest.manifest_version,
                delivery.event.event_id,
            ),
            "hook_id":delivery.manifest.hook_id,
            "manifest_version":delivery.manifest.manifest_version,
            "attempt":attempt.attempt,
            "causation_id":attempt.causation_id,
        },
        "event":JournalDocument::new(delivery.event.clone()).wire_value(),
    });
    let mut input = match serde_json::to_vec(&envelope) {
        Ok(input) => input,
        Err(error) => return (None, Some(format!("encode hook envelope: {error}"))),
    };
    input.push(b'\n');
    #[cfg(unix)]
    let mut tree = match UnixProcessScope::prepare() {
        Ok(tree) => tree,
        Err(error) => return (None, Some(format!("prepare hook process scope: {error}"))),
    };
    #[cfg(unix)]
    let mut command = UnixProcessScope::suspended_command(program);
    #[cfg(not(unix))]
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_clear()
        .env("CMUX_JOURNAL_HOOK_ID", &delivery.manifest.hook_id)
        .env("CMUX_JOURNAL_HOOK_VERSION", delivery.manifest.manifest_version.to_string())
        .env("CMUX_JOURNAL_EVENT_ID", &delivery.event.event_id)
        .env("CMUX_JOURNAL_SEQUENCE", delivery.event.sequence.to_string())
        .env("CMUX_JOURNAL_ATTEMPT", attempt.attempt.to_string())
        .env("CMUX_JOURNAL_CAUSATION_ID", &attempt.causation_id)
        .env(
            "CMUX_JOURNAL_CORRELATION_ID",
            format!(
                "{}:{}:{}",
                delivery.manifest.hook_id,
                delivery.manifest.manifest_version,
                delivery.event.event_id,
            ),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(CREATE_SUSPENDED);
    if let Some(session_id) = session_id {
        command.env("CMUX_JOURNAL_SESSION_ID", session_id);
    }
    #[cfg(unix)]
    tree.configure(&mut command);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return (None, Some(format!("start hook executable: {error}"))),
    };
    #[cfg(unix)]
    if let Err(error) = tree.bind(child.id()) {
        tree.terminate();
        terminate_hook_child(&mut child);
        return (None, Some(format!("track hook process scope: {error}")));
    }
    #[cfg(unix)]
    let child_exit = match UnixChildExitSignal::observe(child.id()) {
        Ok(child_exit) => child_exit,
        Err(error) => {
            tree.terminate();
            terminate_hook_child(&mut child);
            return (None, Some(format!("observe hook process exit: {error}")));
        }
    };
    #[cfg(windows)]
    let job = match WindowsHookJob::assign(&child) {
        Ok(job) => job,
        Err(error) => {
            terminate_hook_child(&mut child);
            return (None, Some(format!("isolate hook process tree: {error}")));
        }
    };
    #[cfg(windows)]
    if let Err(error) = resume_suspended_hook_child(&child) {
        job.terminate_and_wait(&mut child);
        return (None, Some(format!("resume isolated hook process: {error}")));
    }
    let process_group = child.id();
    let Some(stdin) = child.stdin.take() else {
        #[cfg(unix)]
        {
            tree.terminate();
            let _ = child.kill();
            child_exit.finish();
            let _ = child.wait();
        }
        #[cfg(windows)]
        job.terminate_and_wait(&mut child);
        return (None, Some("hook stdin pipe is unavailable".into()));
    };
    let timeout = Duration::from_millis(delivery.manifest.exec.timeout_ms);
    #[cfg(unix)]
    {
        let completion = execute_hook_child_unix(stdin, &input, timeout, cancelled, &child_exit);
        tree.terminate();
        if completion.is_err() {
            let _ = child.kill();
        }
        child_exit.finish();
        let status = child.wait();
        match completion {
            Ok(()) => match status {
                Ok(status) => hook_exit_result(status, process_group),
                Err(error) => (None, Some(format!("wait for hook executable: {error}"))),
            },
            Err(result) => result,
        }
    }
    #[cfg(windows)]
    execute_hook_child_portable(&mut child, stdin, &input, process_group, timeout, &job, cancelled)
}

#[cfg(test)]
fn execute_delivery(
    delivery: &JournalHookDelivery,
    attempt: &JournalHookAttempt,
) -> (Option<i32>, Option<String>) {
    execute_delivery_with_shutdown(delivery, attempt, &AtomicBool::new(false))
}

fn hook_shutdown_result() -> (Option<i32>, Option<String>) {
    (None, Some("hook canceled during daemon shutdown".into()))
}

#[cfg(unix)]
fn execute_hook_child_unix(
    mut stdin: std::process::ChildStdin,
    input: &[u8],
    timeout: Duration,
    cancelled: &AtomicBool,
    child_exit: &UnixChildExitSignal,
) -> Result<(), (Option<i32>, Option<String>)> {
    let fd = stdin.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        let error = std::io::Error::last_os_error();
        return Err((None, Some(format!("configure hook stdin: {error}"))));
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        let error = std::io::Error::last_os_error();
        return Err((None, Some(format!("configure hook stdin: {error}"))));
    }
    let deadline = Instant::now() + timeout;
    let mut offset = 0;
    while offset < input.len() {
        if cancelled.load(Ordering::Acquire) {
            return Err(hook_shutdown_result());
        }
        match child_exit.try_waitable() {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => {
                return Err((None, Some(format!("wait for hook executable: {error}"))));
            }
        }
        let now = Instant::now();
        if now >= deadline {
            return Err((None, Some(format!("hook timed out after {} ms", timeout.as_millis()))));
        }
        match stdin.write(input.get(offset..).unwrap_or_default()) {
            Ok(0) => {
                return hook_stdin_closed_result(
                    child_exit,
                    deadline,
                    "hook stdin closed before accepting its event",
                );
            }
            Ok(written) => offset += written,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if let Err(error) = wait_hook_stdin_writable(fd, deadline, cancelled) {
                    if cancelled.load(Ordering::Acquire) {
                        return Err(hook_shutdown_result());
                    }
                    return Err((None, Some(format!("write hook event: {error}"))));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => {
                return hook_stdin_closed_result(
                    child_exit,
                    deadline,
                    &format!("write hook event: {error}"),
                );
            }
        }
    }
    drop(stdin);
    wait_for_hook_exit(child_exit, deadline, timeout, cancelled)
}

#[cfg(unix)]
fn hook_stdin_closed_result(
    child_exit: &UnixChildExitSignal,
    deadline: Instant,
    fallback_error: &str,
) -> Result<(), (Option<i32>, Option<String>)> {
    let wait_deadline = Instant::now()
        + deadline.saturating_duration_since(Instant::now()).min(Duration::from_millis(50));
    match child_exit.wait_until(wait_deadline) {
        Ok(true) => Ok(()),
        Ok(false) | Err(_) => Err((None, Some(fallback_error.into()))),
    }
}

#[cfg(unix)]
fn wait_hook_stdin_writable(
    fd: std::os::fd::RawFd,
    deadline: Instant,
    cancelled: &AtomicBool,
) -> std::io::Result<()> {
    loop {
        if cancelled.load(Ordering::Acquire) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "hook canceled during daemon shutdown",
            ));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "hook timed out"));
        }
        let mut descriptor = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        let poll_ms = remaining.min(Duration::from_millis(50)).as_millis().max(1) as libc::c_int;
        let result = unsafe { libc::poll(&mut descriptor, 1, poll_ms) };
        if result > 0 {
            return Ok(());
        }
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(windows)]
fn execute_hook_child_portable(
    child: &mut std::process::Child,
    mut stdin: std::process::ChildStdin,
    input: &[u8],
    process_group: u32,
    timeout: Duration,
    job: &WindowsHookJob,
    cancelled: &AtomicBool,
) -> (Option<i32>, Option<String>) {
    let deadline = Instant::now() + timeout;
    let input = input.to_vec();
    let (write_result_sender, write_result_receiver) = mpsc::sync_channel(1);
    let writer =
        match std::thread::Builder::new().name("journal-hook-stdin".into()).spawn(move || {
            let result = stdin.write_all(&input);
            drop(stdin);
            let _ = write_result_sender.send(result);
        }) {
            Ok(writer) => writer,
            Err(error) => {
                job.terminate_and_wait(child);
                return (None, Some(format!("start hook stdin writer: {error}")));
            }
        };

    loop {
        if cancelled.load(Ordering::Acquire) {
            job.terminate_and_wait(child);
            let _ = writer.join();
            return hook_shutdown_result();
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            job.terminate_and_wait(child);
            let _ = writer.join();
            return (None, Some(format!("hook timed out after {} ms", timeout.as_millis())));
        }
        match write_result_receiver.recv_timeout(remaining.min(Duration::from_millis(10))) {
            Ok(Ok(())) => {
                let _ = writer.join();
                return wait_for_hook_exit_windows(
                    child,
                    process_group,
                    deadline,
                    timeout,
                    job,
                    cancelled,
                );
            }
            Ok(Err(error)) => {
                let _ = writer.join();
                job.terminate_and_wait(child);
                return (None, Some(format!("write hook event: {error}")));
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                job.terminate_and_wait(child);
                let _ = writer.join();
                return (None, Some("hook stdin writer stopped without a result".into()));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => match child.try_wait() {
                Ok(Some(status)) => {
                    job.terminate_descendants();
                    let _ = writer.join();
                    return hook_exit_result(status, process_group);
                }
                Ok(None) => {}
                Err(error) => {
                    job.terminate_and_wait(child);
                    let _ = writer.join();
                    return (None, Some(format!("wait for hook executable: {error}")));
                }
            },
        }
    }
}

#[cfg(windows)]
fn wait_for_hook_exit_windows(
    child: &mut std::process::Child,
    process_group: u32,
    deadline: Instant,
    timeout: Duration,
    job: &WindowsHookJob,
    cancelled: &AtomicBool,
) -> (Option<i32>, Option<String>) {
    loop {
        if cancelled.load(Ordering::Acquire) {
            job.terminate_and_wait(child);
            return hook_shutdown_result();
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            job.terminate_and_wait(child);
            return (None, Some(format!("hook timed out after {} ms", timeout.as_millis())));
        }
        match child.wait_timeout(remaining.min(Duration::from_millis(50))) {
            Ok(Some(status)) => {
                job.terminate_descendants();
                return hook_exit_result(status, process_group);
            }
            Ok(None) => {}
            Err(error) => {
                job.terminate_and_wait(child);
                return (None, Some(format!("wait for hook executable: {error}")));
            }
        }
    }
}

#[cfg(unix)]
fn wait_for_hook_exit(
    child_exit: &UnixChildExitSignal,
    deadline: Instant,
    timeout: Duration,
    cancelled: &AtomicBool,
) -> Result<(), (Option<i32>, Option<String>)> {
    loop {
        if cancelled.load(Ordering::Acquire) {
            return Err(hook_shutdown_result());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err((None, Some(format!("hook timed out after {} ms", timeout.as_millis()))));
        }
        let wait_deadline = Instant::now() + remaining.min(Duration::from_millis(50));
        match child_exit.wait_until(wait_deadline) {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => {
                return Err((None, Some(format!("wait for hook executable: {error}"))));
            }
        }
    }
}

fn hook_exit_result(
    status: std::process::ExitStatus,
    _process_group: u32,
) -> (Option<i32>, Option<String>) {
    let code = status.code();
    let error = if status.success() {
        None
    } else {
        Some(match code {
            Some(code) => format!("hook exited with status {code}"),
            None => "hook terminated without an exit status".into(),
        })
    };
    (code, error)
}

fn terminate_hook_child(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

const fn sensitivity_rank(value: JournalSensitivity) -> u8 {
    match value {
        JournalSensitivity::Public => 0,
        JournalSensitivity::Metadata => 1,
        JournalSensitivity::Sensitive => 2,
        JournalSensitivity::Secret => 3,
    }
}

const fn class_index(value: crate::JournalClass) -> usize {
    match value {
        crate::JournalClass::State => 0,
        crate::JournalClass::Observation => 1,
        crate::JournalClass::Effect => 2,
        crate::JournalClass::Checkpoint => 3,
    }
}

#[cfg(test)]
mod tests;

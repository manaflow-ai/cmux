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
const IDLE_WAIT: Duration = Duration::from_secs(30);
const ACTIVE_WAIT: Duration = Duration::from_secs(1);
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
        let mut state = self.state.lock().unwrap();
        if state.shutdown || state.running {
            return false;
        }
        state.running = true;
        self.cancelled.store(false, Ordering::Release);
        true
    }

    fn finish(&self) {
        let mut state = self.state.lock().unwrap();
        state.running = false;
        self.changed.notify_all();
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    pub(crate) fn shutdown_until(&self, deadline: Instant) -> bool {
        self.cancelled.store(true, Ordering::Release);
        let mut state = self.state.lock().unwrap();
        state.shutdown = true;
        while state.running {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next, timeout) = self.changed.wait_timeout(state, remaining).unwrap();
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
        let job = match jobs.lock().unwrap().recv() {
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
                epoch = journal.wait(epoch, ACTIVE_WAIT);
                continue;
            }
        }

        let states = match mux.journal_hook_states() {
            Ok(states) => states,
            Err(_) => {
                let journal = mux.shared_journal_handle();
                drop(mux);
                epoch = journal.wait(epoch, ACTIVE_WAIT);
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

        if scan_hooks(&mux, &mut hooks, &mut catch_up_reader, &runtime).is_err() {
            catch_up_reader = None;
        }
        if runtime.is_cancelled() || mux.daemon_shutdown_requested() {
            continue;
        }

        if active.len() < workers.capacity {
            let capacity = workers.capacity - active.len();
            // The query includes executing rows so a replacement dispatcher
            // can retry them. Ask for the complete worker window, otherwise
            // active rows can consume the limit and leave idle workers empty.
            if let Ok(deliveries) = mux.pending_journal_hook_deliveries(workers.capacity) {
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
                    if let Ok(attempts) = mux.start_journal_hook_deliveries(&deliveries) {
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

        let wait = if hooks.is_empty() && active.is_empty() { IDLE_WAIT } else { ACTIVE_WAIT };
        let journal = mux.shared_journal_handle();
        drop(mux);
        epoch = journal.wait(epoch, wait);
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
            let scanned_to = page.records.last().expect("non-empty page").record.sequence;
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
            classes[class_index(*class)] = true;
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
        if self.has_class_filter && !self.classes[class_index(record.class)] {
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
        match stdin.write(&input[offset..]) {
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
mod tests {
    use super::*;
    use crate::{
        JournalClass, JournalEventSchema, JournalHookDeliveryPolicy, JournalHookExec,
        JournalHookFilter, JournalHookRetry, JournalIngress, JournalProducer,
        JournalProducerManifest, JournalReplayPolicy, JournalSubject, SessionJournalRecord,
    };
    use serde_json::Value;
    use sha2::Digest;

    fn document(kind: &str, payload: Value) -> JournalDocument {
        JournalDocument::new(SessionJournalRecord {
            sequence: 1,
            event_id: "event_test".into(),
            schema_version: 1,
            kind: kind.into(),
            class: JournalClass::State,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms: 1,
            committed_at_ms: 1,
            producer: JournalProducer { kind: "test".into(), id: "test".into() },
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: vec![JournalSubject { kind: "workspace".into(), id: "ws_1".into() }],
            sensitivity: JournalSensitivity::Metadata,
            payload,
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: None,
        })
    }

    fn terminal_document(bytes: &[u8]) -> JournalDocument {
        let digest = sha2::Sha256::digest(bytes);
        JournalDocument::new(SessionJournalRecord {
            sequence: 1,
            event_id: "event_terminal_test".into(),
            schema_version: 1,
            kind: "terminal.output".into(),
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms: 1,
            committed_at_ms: 1,
            producer: JournalProducer { kind: "terminal_runtime".into(), id: "term_test".into() },
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: vec![JournalSubject { kind: "terminal".into(), id: "term_test".into() }],
            sensitivity: JournalSensitivity::Sensitive,
            payload: json!({
                "format":"cmux.terminal-output.v1",
                "encoding":"raw",
                "byte_count":bytes.len().to_string(),
                "sha256":format!("{digest:x}"),
                "stream_offset_start":"0",
                "stream_offset_end":bytes.len().to_string(),
            }),
            resource_revision: None,
            previous_resource_revision: None,
            terminal_output: Some(Arc::from(bytes)),
        })
    }

    fn manifest() -> JournalHookManifest {
        JournalHookManifest {
            hook_id: "test_hook".into(),
            manifest_version: 1,
            filter: JournalHookFilter::default(),
            exec: JournalHookExec {
                argv: vec!["/usr/bin/true".into()],
                timeout_ms: 1000,
                max_parallel: 1,
            },
            delivery: JournalHookDeliveryPolicy {
                start: "tail".into(),
                retry: JournalHookRetry { max_attempts: 1, backoff_ms: 0 },
            },
            permissions: vec!["journal.read".into()],
        }
    }

    #[test]
    fn hook_delivery_workers_are_strictly_bounded() {
        assert_eq!(delivery_worker_count(1), 4);
        assert_eq!(delivery_worker_count(8), 16);
        assert_eq!(delivery_worker_count(usize::MAX), 32);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn unix_hook_tree_kills_a_descendant_that_created_a_new_session() {
        const HELPER: &str = "CMUX_TEST_DETACHED_JOURNAL_HOOK";
        const SIGNAL_PATH: &str = "CMUX_TEST_DETACHED_JOURNAL_HOOK_SIGNAL";
        if let Some(mode) = std::env::var_os(HELPER) {
            let signal_path = std::env::var_os(SIGNAL_PATH).unwrap();
            match mode.to_str().unwrap() {
                "close-fds" => {
                    // A normal daemon closes inherited descriptors before it
                    // creates a new session.
                    for fd in 3..1024 {
                        unsafe {
                            libc::close(fd);
                        }
                    }
                }
                "clear-environment" => unsafe {
                    // A daemon can replace its environment after exec. The
                    // scope must retain an independent ownership marker.
                    std::env::remove_var("CMUX_TUI_PROCESS_SCOPE");
                },
                "close-fds-and-clear-environment" => {
                    for fd in 3..1024 {
                        unsafe {
                            libc::close(fd);
                        }
                    }
                    unsafe {
                        std::env::remove_var("CMUX_TUI_PROCESS_SCOPE");
                    }
                }
                "fork-during-cleanup" => {}
                other => panic!("unexpected detached hook helper mode {other}"),
            }
            let session = unsafe { libc::setsid() };
            if mode == "fork-during-cleanup" {
                assert!(session > 0, "the test-only tracker path could not create a session");
            } else {
                assert_eq!(session, -1, "the Linux process-group fence allowed setsid");
                assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
            }
            let mut signal = std::os::unix::net::UnixStream::connect(signal_path).unwrap();
            signal.write_all(&std::process::id().to_ne_bytes()).unwrap();
            let mut release = [0_u8; 1];
            let _ = signal.read_exact(&mut release);
            if mode == "fork-during-cleanup" {
                let input = signal.try_clone().unwrap();
                let mut child = Command::new("/bin/sh")
                    .args(["-c", "read _"])
                    .stdin(Stdio::from(std::os::fd::OwnedFd::from(input)))
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap();
                signal.write_all(&child.id().to_ne_bytes()).unwrap();
                let _ = child.wait();
            }
            return;
        }

        for mode in ["close-fds", "clear-environment", "close-fds-and-clear-environment"] {
            let root = std::env::temp_dir().join(format!(
                "cmux-jh-{}-{:x}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(&root).unwrap();
            let signal_path = root.join("detached.sock");
            let listener = std::os::unix::net::UnixListener::bind(&signal_path).unwrap();
            let (accepted, accepted_receiver) = mpsc::sync_channel(1);
            let acceptor = std::thread::spawn(move || {
                accepted.send(listener.accept().map(|(signal, _)| signal)).unwrap();
            });
            let executable = std::env::current_exe().unwrap();
            let test_name = "journal_hooks::tests::unix_hook_tree_kills_a_descendant_that_created_a_new_session";
            let mut command = UnixProcessScope::suspended_command("/bin/sh");
            // Exit the intermediate shell immediately. The detached child is
            // reparented before cleanup, so no launching ancestor waits for
            // tracker admission.
            let launch = "\"$1\" --exact \"$2\" --nocapture &";
            command
                .args(["-c", launch, "cmux-journal-hook-test"])
                .arg(&executable)
                .arg(test_name)
                .env(HELPER, mode)
                .env(SIGNAL_PATH, &signal_path)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .process_group(0);
            let mut tree = UnixProcessScope::prepare().unwrap();
            tree.configure(&mut command);
            let mut child = command.spawn().unwrap();
            tree.bind(child.id()).unwrap();
            let mut signal = accepted_receiver
                .recv_timeout(Duration::from_secs(5))
                .expect("detached hook did not connect its lifecycle signal")
                .unwrap();
            acceptor.join().unwrap();
            let mut detached = [0_u8; size_of::<u32>()];
            signal.read_exact(&mut detached).unwrap();
            let detached = u32::from_ne_bytes(detached);
            tree.terminate();
            let _ = child.kill();
            let _ = child.wait();
            signal.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut trailing = [0_u8; 1];
            assert_eq!(
                signal.read(&mut trailing).unwrap(),
                0,
                "detached hook {detached} sent unexpected lifecycle data"
            );
            let _ = std::fs::remove_dir_all(root);
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn unix_process_scope_repeats_a_final_scan_after_a_late_fork() {
        const HELPER: &str = "CMUX_TEST_DETACHED_JOURNAL_HOOK";
        const SIGNAL_PATH: &str = "CMUX_TEST_DETACHED_JOURNAL_HOOK_SIGNAL";
        let root = std::env::temp_dir().join(format!(
            "cmux-jh-final-scan-{}-{:x}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let signal_path = root.join("detached.sock");
        let listener = std::os::unix::net::UnixListener::bind(&signal_path).unwrap();
        let executable = std::env::current_exe().unwrap();
        let test_name =
            "journal_hooks::tests::unix_hook_tree_kills_a_descendant_that_created_a_new_session";
        let mut tree = UnixProcessScope::prepare().unwrap();
        let (scan_completed, resume_cleanup) = tree.final_scan_gate_for_test();
        let mut command = UnixProcessScope::suspended_command("/bin/sh");
        command
            .args(["-c", "\"$1\" --exact \"$2\" --nocapture &", "cmux-journal-hook-final-scan"])
            .arg(&executable)
            .arg(test_name)
            .env(HELPER, "fork-during-cleanup")
            .env(SIGNAL_PATH, &signal_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        tree.configure(&mut command);
        let mut root_child = command.spawn().unwrap();
        tree.bind(root_child.id()).unwrap();
        let (mut signal, _) = listener.accept().unwrap();
        let mut parent = [0_u8; size_of::<u32>()];
        signal.read_exact(&mut parent).unwrap();

        let cleanup = std::thread::spawn(move || {
            tree.terminate();
            let _ = root_child.kill();
            let _ = root_child.wait();
        });
        scan_completed
            .recv_timeout(Duration::from_secs(5))
            .expect("final process-scope scan did not reach its signal fence");
        signal.write_all(b"f").unwrap();
        let mut child = [0_u8; size_of::<u32>()];
        signal.read_exact(&mut child).unwrap();
        resume_cleanup.send(()).unwrap();

        signal.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut trailing = [0_u8; 1];
        assert_eq!(
            signal.read(&mut trailing).unwrap(),
            0,
            "late process-scope child {} survived the repeated scan",
            u32::from_ne_bytes(child),
        );
        cleanup.join().unwrap();
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn journal_hook_shutdown_cancels_an_active_detached_process_scope() {
        let root = std::env::temp_dir().join(format!(
            "cmux-jh-shutdown-{}-{:x}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let signal_path = root.join("detached.sock");
        let listener = std::os::unix::net::UnixListener::bind(&signal_path).unwrap();
        let executable = std::env::current_exe().unwrap();
        let test_name =
            "journal_hooks::tests::unix_hook_tree_kills_a_descendant_that_created_a_new_session";
        let mut hook = manifest();
        hook.exec.argv = vec![
            "/bin/sh".into(),
            "-c".into(),
            "CMUX_TEST_DETACHED_JOURNAL_HOOK=close-fds \
             CMUX_TEST_DETACHED_JOURNAL_HOOK_SIGNAL=\"$3\" \
             \"$1\" --exact \"$2\" --nocapture & wait"
                .into(),
            "cmux-journal-hook-shutdown".into(),
            executable.to_string_lossy().into_owned(),
            test_name.into(),
            signal_path.to_string_lossy().into_owned(),
        ];
        hook.exec.timeout_ms = 30_000;
        let delivery = JournalHookDelivery {
            manifest: hook,
            event: document("plugin.test.shutdown", json!({})).record,
            attempt: 0,
        };
        let attempt = JournalHookAttempt { attempt: 1, causation_id: "event_started".into() };
        let runtime = Arc::new(JournalHookRuntime::default());
        assert!(runtime.begin());
        let worker_runtime = runtime.clone();
        let worker = std::thread::spawn(move || {
            let _guard = JournalHookRuntimeGuard(worker_runtime.clone());
            execute_delivery_with_shutdown(&delivery, &attempt, &worker_runtime.cancelled)
        });
        let (mut signal, _) = listener.accept().unwrap();
        let mut detached = [0_u8; size_of::<u32>()];
        signal.read_exact(&mut detached).unwrap();

        assert!(runtime.shutdown_until(Instant::now() + SHUTDOWN_WAIT));
        let (status, error) = worker.join().unwrap();
        assert_eq!(status, None);
        assert!(error.unwrap().contains("daemon shutdown"));
        signal.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut trailing = [0_u8; 1];
        assert_eq!(signal.read(&mut trailing).unwrap(), 0);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    #[test]
    fn portable_hook_stdin_write_obeys_the_execution_timeout() {
        let mut command = Command::new("cmd");
        command
            .args(["/C", "ping -n 30 127.0.0.1 >NUL"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_SUSPENDED);
        let mut child = command.spawn().unwrap();
        assert_eq!(child.try_wait().unwrap(), None);
        let process_group = child.id();
        let job = WindowsHookJob::assign(&child).unwrap();
        resume_suspended_hook_child(&child).unwrap();
        let stdin = child.stdin.take().unwrap();
        let timeout = Duration::from_millis(100);
        let started = Instant::now();

        let (status, error) = execute_hook_child_portable(
            &mut child,
            stdin,
            &vec![b'x'; 1024 * 1024],
            process_group,
            timeout,
            &job,
            &AtomicBool::new(false),
        );

        assert_eq!(status, None);
        assert!(error.unwrap().contains("hook timed out"));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn compiled_hook_regex_matches_cached_payload_bytes() {
        let mut manifest = manifest();
        manifest.filter.regex = Some(crate::JournalHookRegex {
            pattern: "needle-[0-9]+".into(),
            field: "payload".into(),
            case_sensitive: true,
        });
        let filter = CompiledHookFilter::new(&manifest).unwrap();
        assert!(filter.matches(&manifest, &document("resource.changed", json!({"v":"needle-42"}))));
        assert!(!filter.matches(&manifest, &document("resource.changed", json!({"v":"other"}))));
    }

    #[test]
    fn compiled_hook_regex_matches_exact_terminal_output_bytes() {
        let mut manifest = manifest();
        manifest.permissions.push("journal.read.sensitive".into());
        manifest.filter.max_sensitivity = Some(JournalSensitivity::Sensitive);
        manifest.filter.regex = Some(crate::JournalHookRegex {
            pattern: "error-[0-9]+".into(),
            field: "terminal_output".into(),
            case_sensitive: true,
        });
        let filter = CompiledHookFilter::new(&manifest).unwrap();
        assert!(filter.matches(&manifest, &terminal_document(b"prompt> error-42\r\n")));
        assert!(!filter.matches(&manifest, &terminal_document(b"prompt> ready\r\n")));
    }

    #[test]
    fn hooks_do_not_reconsume_delivery_events_by_default() {
        let manifest = manifest();
        let filter = CompiledHookFilter::new(&manifest).unwrap();
        assert!(!filter.matches(&manifest, &document("hook.delivery.completed", json!({}))));
    }

    #[cfg(unix)]
    #[test]
    fn hook_exit_is_not_blocked_by_a_descendant_holding_stdin_open() {
        let mut manifest = manifest();
        manifest.exec.argv =
            vec!["/bin/sh".into(), "-c".into(), "exec 3<&0; (/bin/sleep 3 <&3) & exit 0".into()];
        let delivery = JournalHookDelivery {
            manifest,
            event: document("plugin.test.large", json!({"value":"x".repeat(1024 * 1024)})).record,
            attempt: 0,
        };
        let attempt = JournalHookAttempt { attempt: 1, causation_id: "event_started".into() };
        let started = Instant::now();
        let (exit_code, error) = execute_delivery(&delivery, &attempt);

        #[cfg(target_os = "macos")]
        {
            assert!(exit_code.is_some_and(|code| code != 0), "{error:?}");
            assert!(error.is_some(), "the macOS process sandbox allowed a hook descendant");
        }
        #[cfg(not(target_os = "macos"))]
        {
            assert_eq!(exit_code, Some(0), "{error:?}");
            assert_eq!(error, None);
        }
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn persistent_hook_delivery_records_started_and_completed_receipts() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-hook-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux =
            Mux::open_persistent("hook-delivery", crate::SurfaceOptions::default(), &root).unwrap();
        let mut hook = manifest();
        hook.filter.kinds = vec!["journal.checkpoint.created".into()];
        mux.put_journal_hook(&hook, "client_test", "hook_manifest_1").unwrap();
        mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();

        let deadline = Instant::now() + Duration::from_secs(10);
        let mut cursor = 0;
        let mut epoch = mux.journal_event_epoch();
        let mut started = false;
        let mut completed = false;
        while Instant::now() < deadline && !completed {
            let page = mux.session_journal_after(cursor, 1024).unwrap();
            for record in page.records {
                cursor = record.sequence;
                started |= record.kind == "hook.delivery.started";
                completed |= record.kind == "hook.delivery.completed";
            }
            if !completed {
                epoch = mux.wait_for_journal_event(epoch, Duration::from_secs(1));
            }
        }
        assert!(started, "hook start receipt was not journaled");
        assert!(completed, "hook completion receipt was not journaled");
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn hook_causal_descendants_are_not_rescheduled_by_default() {
        let root = std::env::temp_dir().join(format!(
            "cmux-journal-hook-causation-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent("hook-causation", crate::SurfaceOptions::default(), &root)
            .unwrap();
        let producer = JournalProducerManifest {
            producer_id: "loop_test".into(),
            namespace: "plugin.loop_test".into(),
            manifest_version: 1,
            max_sensitivity: JournalSensitivity::Metadata,
            permissions: vec!["journal.append.plugin.loop_test".into()],
            events: vec![JournalEventSchema {
                kind: "plugin.loop_test.event".into(),
                schema_version: 1,
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Advisory,
                sensitivity: JournalSensitivity::Metadata,
                payload_schema: json!({"type":"object"}),
            }],
        };
        mux.put_journal_producer(&producer, "client_test", "producer_1").unwrap();
        let mut hook = manifest();
        hook.filter.kinds = vec!["plugin.loop_test.event".into()];
        mux.put_journal_hook(&hook, "client_test", "hook_manifest_1").unwrap();

        let source = mux
            .append_journal_ingress(
                &JournalIngress {
                    producer_id: "loop_test".into(),
                    manifest_version: 1,
                    kind: "plugin.loop_test.event".into(),
                    schema_version: 1,
                    occurred_at_ms: None,
                    subjects: Vec::new(),
                    sensitivity: None,
                    payload: json!({"generation":"source"}),
                    causation_id: None,
                    correlation_id: None,
                },
                "client_test",
                "source_1",
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let started_event_id = loop {
            let page = mux.session_journal_after(0, 1024).unwrap();
            if let Some(record) = page.records.into_iter().find(|record| {
                record.kind == "hook.delivery.started"
                    && record.payload["source_event_id"].as_str() == Some(&source.event_id)
            }) {
                break record.event_id;
            }
            assert!(Instant::now() < deadline, "source delivery did not start");
            let epoch = mux.journal_event_epoch();
            mux.wait_for_journal_event(epoch, Duration::from_millis(100));
        };

        let child = mux
            .append_journal_ingress(
                &JournalIngress {
                    producer_id: "loop_test".into(),
                    manifest_version: 1,
                    kind: "plugin.loop_test.event".into(),
                    schema_version: 1,
                    occurred_at_ms: None,
                    subjects: Vec::new(),
                    sensitivity: None,
                    payload: json!({"generation":"child"}),
                    causation_id: Some(started_event_id),
                    correlation_id: None,
                },
                "client_test",
                "child_1",
            )
            .unwrap();
        let causal = mux
            .journal_events_caused_by_hooks(
                &["test_hook".into()],
                std::slice::from_ref(&child.event_id),
            )
            .unwrap();
        assert!(causal.contains(&("test_hook".into(), child.event_id.clone())));

        loop {
            let cursor = mux
                .journal_hook_states()
                .unwrap()
                .into_iter()
                .find(|state| state.enabled && state.manifest.hook_id == "test_hook")
                .unwrap()
                .cursor_sequence;
            if cursor >= child.sequence {
                break;
            }
            assert!(Instant::now() < deadline, "hook cursor did not scan child event");
            let epoch = mux.shared_journal_epoch();
            mux.wait_for_shared_journal(epoch, Duration::from_millis(100));
        }
        let child_starts = mux
            .session_journal_after(0, 1024)
            .unwrap()
            .records
            .into_iter()
            .filter(|record| {
                record.kind == "hook.delivery.started"
                    && record.payload["source_event_id"].as_str() == Some(&child.event_id)
            })
            .count();
        assert_eq!(child_starts, 0);
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[ignore = "manual release-mode multi-agent hook saturation probe"]
    fn multi_agent_hook_saturation_does_not_stall_terminal_ingress() {
        const AGENTS: usize = 64;
        const EVENTS_PER_AGENT: usize = 32;
        const TERMINAL_CHUNKS: usize = 512;
        const TERMINAL_CHUNK_BYTES: usize = 64 * 1024;

        let root = std::env::temp_dir().join(format!(
            "cmux-journal-hook-saturation-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let mux = Mux::open_persistent("hook-saturation", crate::SurfaceOptions::default(), &root)
            .unwrap();
        let mut hook = manifest();
        hook.hook_id = "agent_completion_probe".into();
        hook.filter.kinds = vec!["agent.child.completed".into()];
        hook.filter.max_sensitivity = Some(JournalSensitivity::Sensitive);
        hook.exec.argv = vec!["/bin/sleep".into(), "0.005".into()];
        hook.exec.timeout_ms = 10_000;
        hook.exec.max_parallel = u16::try_from(MAX_DELIVERY_WORKERS).unwrap();
        hook.delivery.retry = JournalHookRetry { max_attempts: 3, backoff_ms: 10 };
        hook.permissions = vec!["journal.read.sensitive".into()];
        mux.put_journal_hook(&hook, "client_probe", "hook_probe_v1").unwrap();

        let barrier = Arc::new(std::sync::Barrier::new(AGENTS + 1));
        let handles = (0..AGENTS)
            .map(|agent| {
                let mux = mux.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    (0..EVENTS_PER_AGENT)
                        .map(|event| {
                            let started = Instant::now();
                            // Include lossless normalization and stable nested
                            // topology hashing in the measured ingress path.
                            let ingress = crate::agent_hook_journal_ingress(
                                "codex",
                                "SubagentStop",
                                None,
                                json!({
                                    "session_id":format!("agent-{agent}"),
                                    "root_session_id":format!("root-session-{agent}"),
                                    "root_agent_id":format!("root-{agent}"),
                                    "parent_agent_id":format!("parent-{agent}"),
                                    "child_agent_id":format!("child-{agent}-{event}"),
                                    "agent_depth":2,
                                    "message":"done"
                                }),
                            )
                            .unwrap();
                            mux.append_journal_ingress(
                                &ingress,
                                "client_probe",
                                &format!("agent_{agent}_{event}"),
                            )
                            .unwrap();
                            started.elapsed()
                        })
                        .collect::<Vec<_>>()
                })
            })
            .collect::<Vec<_>>();
        let terminal_id = Arc::new(
            crate::resource::TerminalPublicId::parse("term_00000000000000000000000000000077")
                .unwrap(),
        );
        let generation: Arc<str> = Arc::from("hook-saturation-generation");
        let terminal_chunk = vec![b'x'; TERMINAL_CHUNK_BYTES];
        let append_started = Instant::now();
        barrier.wait();
        let terminal_started = Instant::now();
        let mut maximum_enqueue = Duration::ZERO;
        for _ in 0..TERMINAL_CHUNKS {
            let started = Instant::now();
            mux.journal_terminal_output(
                terminal_id.clone(),
                generation.clone(),
                terminal_chunk.clone(),
            );
            maximum_enqueue = maximum_enqueue.max(started.elapsed());
        }
        mux.flush_terminal_journal().unwrap();
        let terminal_elapsed = terminal_started.elapsed();
        let mut append_latencies =
            handles.into_iter().flat_map(|handle| handle.join().unwrap()).collect::<Vec<_>>();
        let append_elapsed = append_started.elapsed();
        append_latencies.sort_unstable();
        let event_count = append_latencies.len();

        let deadline = Instant::now() + Duration::from_secs(60);
        let mut cursor = 0;
        let mut completed = 0;
        let mut failed_attempts = Vec::new();
        let mut abandoned = Vec::new();
        let mut epoch = mux.journal_event_epoch();
        while completed + abandoned.len() < event_count && Instant::now() < deadline {
            let page = mux.session_journal_after(cursor, 1024).unwrap();
            for record in page.records {
                cursor = record.sequence;
                completed += usize::from(record.kind == "hook.delivery.completed");
                if record.kind == "hook.delivery.failed" {
                    failed_attempts.push(record.payload.clone());
                } else if record.kind == "hook.delivery.abandoned" {
                    abandoned.push(record.payload.clone());
                }
            }
            if completed + abandoned.len() < event_count {
                epoch = mux.wait_for_journal_event(epoch, Duration::from_millis(100));
            }
        }

        let percentile =
            |percent: usize| append_latencies[(append_latencies.len() - 1) * percent / 100];
        let appends_per_second = event_count as f64 / append_elapsed.as_secs_f64();
        let terminal_mib = TERMINAL_CHUNKS * TERMINAL_CHUNK_BYTES / (1024 * 1024);
        let terminal_mib_per_second = terminal_mib as f64 / terminal_elapsed.as_secs_f64();
        eprintln!(
            "multi-agent hook saturation: {event_count} events from {AGENTS} agents in \
             {append_elapsed:?} ({appends_per_second:.0}/s), ingress p50={:?} p95={:?} \
             p99={:?} max={:?}; terminal {terminal_mib} MiB durable in \
             {terminal_elapsed:?} ({terminal_mib_per_second:.1} MiB/s), max enqueue \
             {maximum_enqueue:?}; {completed} hook children completed, {} attempts retried, \
             {} deliveries abandoned",
            percentile(50),
            percentile(95),
            percentile(99),
            append_latencies.last().unwrap(),
            failed_attempts.len(),
            abandoned.len(),
        );
        assert!(abandoned.is_empty(), "hook deliveries were abandoned: {abandoned:#?}");
        assert_eq!(completed, event_count, "hook deliveries did not drain before the deadline");
        assert!(
            percentile(99) < Duration::from_millis(100),
            "agent ingress p99 regressed to {:?}",
            percentile(99)
        );
        assert!(
            maximum_enqueue < Duration::from_millis(100),
            "terminal enqueue stalled for {maximum_enqueue:?}"
        );
        assert!(
            terminal_mib_per_second >= 10.0,
            "terminal ingress regressed to {terminal_mib_per_second:.1} MiB/s"
        );
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}

use std::collections::{HashMap, HashSet};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::{Arc, Weak, mpsc};
use std::time::Duration;

use regex::bytes::{Regex, RegexBuilder};
use serde_json::json;
use wait_timeout::ChildExt;

use crate::journal_kernel::{JournalDocument, SharedJournalRead};
use crate::workspace_registry::{
    JournalHookAttempt, JournalHookDelivery, JournalHookState, SessionJournalReader,
};
use crate::{JournalHookManifest, JournalSensitivity, Mux};

const HOOK_SCAN_PAGE_SIZE: usize = 1024;
const MAX_ACTIVE_DELIVERIES: usize = 128;
const IDLE_WAIT: Duration = Duration::from_secs(30);
const ACTIVE_WAIT: Duration = Duration::from_secs(1);

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

struct CompiledHook {
    manifest: JournalHookManifest,
    cursor_sequence: u64,
    filter: CompiledHookFilter,
    catch_up_reader: Option<SessionJournalReader>,
}

struct CompiledHookFilter {
    regex: Option<CompiledHookRegex>,
}

enum HookRegexField {
    Kind,
    Subjects,
    Payload,
    Record,
}

struct CompiledHookRegex {
    field: HookRegexField,
    matcher: Regex,
}

/// Starts one session-owned dispatcher. The dispatcher keeps only a weak mux
/// reference, so it cannot prolong the session lifetime.
pub(crate) fn start(mux: &Arc<Mux>) -> anyhow::Result<()> {
    if !mux.shared_journal_enabled() {
        return Ok(());
    }
    let weak = Arc::downgrade(mux);
    std::thread::Builder::new()
        .name("mux-session-journal-hooks".into())
        .spawn(move || run_dispatcher(weak))?;
    Ok(())
}

fn run_dispatcher(mux: Weak<Mux>) {
    let (completed_tx, completed_rx) = mpsc::channel::<DeliveryKey>();
    let mut hooks = HashMap::<HookVersion, CompiledHook>::new();
    let mut active = HashSet::<DeliveryKey>::new();
    let mut epoch = 0;

    loop {
        while let Ok(key) = completed_rx.try_recv() {
            active.remove(&key);
        }
        let Some(mux) = mux.upgrade() else { return };
        epoch = mux.shared_journal_epoch().max(epoch);

        let states = match mux.journal_hook_states() {
            Ok(states) => states,
            Err(_) => {
                epoch = mux.wait_for_shared_journal(epoch, ACTIVE_WAIT);
                continue;
            }
        };
        refresh_compiled_hooks(&mut hooks, states);

        for hook in hooks.values_mut() {
            if scan_hook(&mux, hook).is_err() {
                hook.catch_up_reader = None;
            }
        }

        if active.len() < MAX_ACTIVE_DELIVERIES {
            let capacity = MAX_ACTIVE_DELIVERIES - active.len();
            if let Ok(deliveries) = mux.pending_journal_hook_deliveries(capacity.max(1)) {
                let mut per_hook = HashMap::<HookVersion, usize>::new();
                for key in &active {
                    *per_hook.entry(key.hook.clone()).or_default() += 1;
                }
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
                        || active.len() >= MAX_ACTIVE_DELIVERIES
                        || per_hook.get(&hook).copied().unwrap_or_default()
                            >= usize::from(delivery.manifest.exec.max_parallel)
                    {
                        continue;
                    }
                    let attempt = match mux.start_journal_hook_delivery(&delivery) {
                        Ok(attempt) => attempt,
                        Err(_) => continue,
                    };
                    active.insert(key.clone());
                    *per_hook.entry(hook).or_default() += 1;
                    spawn_delivery(
                        Arc::downgrade(&mux),
                        delivery,
                        attempt,
                        key,
                        completed_tx.clone(),
                    );
                }
            }
        }

        let wait = if hooks.is_empty() && active.is_empty() { IDLE_WAIT } else { ACTIVE_WAIT };
        epoch = mux.wait_for_shared_journal(epoch, wait);
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
                catch_up_reader: None,
            },
        );
    }
}

fn scan_hook(mux: &Mux, hook: &mut CompiledHook) -> anyhow::Result<()> {
    loop {
        let page = hook_page(mux, hook)?;
        if page.records.is_empty() {
            if hook.cursor_sequence >= page.head_sequence {
                hook.catch_up_reader = None;
            }
            return Ok(());
        }
        let scanned_to = page.records.last().expect("non-empty page").record.sequence;
        let causal_candidates = if hook.manifest.filter.include_causal_descendants {
            Vec::new()
        } else {
            page.records
                .iter()
                .filter(|document| document.record.causation_id.is_some())
                .map(|document| document.record.event_id.clone())
                .collect::<Vec<_>>()
        };
        let causal_descendants =
            mux.journal_events_caused_by_hook(&hook.manifest.hook_id, &causal_candidates)?;
        let matches = page
            .records
            .iter()
            .filter(|document| {
                !causal_descendants.contains(&document.record.event_id)
                    && hook.filter.matches(&hook.manifest, document)
            })
            .map(|document| (document.record.event_id.clone(), document.record.sequence))
            .collect::<Vec<_>>();
        if !mux.schedule_journal_hook_deliveries(
            &hook.manifest.hook_id,
            hook.manifest.manifest_version,
            hook.cursor_sequence,
            scanned_to,
            &matches,
        )? {
            return Ok(());
        }
        hook.cursor_sequence = scanned_to;
        if scanned_to >= page.head_sequence {
            hook.catch_up_reader = None;
            return Ok(());
        }
    }
}

struct HookPage {
    head_sequence: u64,
    records: Vec<Arc<JournalDocument>>,
}

fn hook_page(mux: &Mux, hook: &mut CompiledHook) -> anyhow::Result<HookPage> {
    if let Some(reader) = &hook.catch_up_reader {
        return reader.after(hook.cursor_sequence, HOOK_SCAN_PAGE_SIZE).map(|page| HookPage {
            head_sequence: page.head_sequence,
            records: page.records.into_iter().map(JournalDocument::new).map(Arc::new).collect(),
        });
    }
    match mux.shared_journal_after(hook.cursor_sequence, HOOK_SCAN_PAGE_SIZE) {
        SharedJournalRead::Page(page) => {
            Ok(HookPage { head_sequence: page.head_sequence, records: page.records })
        }
        SharedJournalRead::Gap { .. } => {
            hook.catch_up_reader = mux.session_journal_reader()?;
            hook_page(mux, hook)
        }
        SharedJournalRead::Unavailable => anyhow::bail!("journal fanout is unavailable"),
    }
}

impl CompiledHookFilter {
    fn new(manifest: &JournalHookManifest) -> anyhow::Result<Self> {
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
        Ok(Self { regex })
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
        if !manifest.filter.kinds.is_empty()
            && !manifest.filter.kinds.iter().any(|filter| {
                filter.strip_suffix(".*").map_or(record.kind == *filter, |prefix| {
                    record.kind.strip_prefix(prefix).is_some_and(|suffix| suffix.starts_with('.'))
                })
            })
        {
            return false;
        }
        if !manifest.filter.classes.is_empty() && !manifest.filter.classes.contains(&record.class) {
            return false;
        }
        if !manifest.filter.subject_kinds.is_empty()
            && !record.subjects.iter().any(|subject| {
                manifest.filter.subject_kinds.iter().any(|kind| kind == &subject.kind)
            })
        {
            return false;
        }
        let maximum = manifest.filter.max_sensitivity.unwrap_or(JournalSensitivity::Metadata);
        if sensitivity_rank(record.sensitivity) > sensitivity_rank(maximum) {
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
            HookRegexField::Payload => self.matcher.is_match(document.payload_bytes()),
            HookRegexField::Record => self.matcher.is_match(document.record_bytes()),
        }
    }
}

fn spawn_delivery(
    mux: Weak<Mux>,
    delivery: JournalHookDelivery,
    attempt: JournalHookAttempt,
    key: DeliveryKey,
    completed: mpsc::Sender<DeliveryKey>,
) {
    let fallback_mux = mux.clone();
    let fallback_delivery = delivery.clone();
    let fallback_attempt = attempt.clone();
    let fallback_key = key.clone();
    let fallback_completed = completed.clone();
    let spawned = std::thread::Builder::new()
        .name(format!("journal-hook-{}", delivery.manifest.hook_id))
        .spawn(move || {
            let (exit_code, error) = execute_delivery(&delivery, &attempt);
            if let Some(mux) = mux.upgrade() {
                let _ = mux.finish_journal_hook_delivery(
                    &delivery,
                    attempt.attempt,
                    exit_code,
                    error.as_deref(),
                );
            }
            let _ = completed.send(key);
        });
    if let Err(error) = spawned {
        if let Some(mux) = fallback_mux.upgrade() {
            let _ = mux.finish_journal_hook_delivery(
                &fallback_delivery,
                fallback_attempt.attempt,
                None,
                Some(&format!("could not start hook worker: {error}")),
            );
        }
        let _ = fallback_completed.send(fallback_key);
    }
}

fn execute_delivery(
    delivery: &JournalHookDelivery,
    attempt: &JournalHookAttempt,
) -> (Option<i32>, Option<String>) {
    let argv = &delivery.manifest.exec.argv;
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
    let input = match serde_json::to_vec(&envelope) {
        Ok(input) => input,
        Err(error) => return (None, Some(format!("encode hook envelope: {error}"))),
    };
    let mut command = Command::new(&argv[0]);
    command
        .args(&argv[1..])
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
    #[cfg(unix)]
    command.process_group(0);
    if let Some(session_id) = session_id {
        command.env("CMUX_JOURNAL_SESSION_ID", session_id);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return (None, Some(format!("start hook executable: {error}"))),
    };
    let Some(mut stdin) = child.stdin.take() else {
        terminate_hook_child(&mut child);
        return (None, Some("hook stdin pipe is unavailable".into()));
    };
    let stdin_writer = match std::thread::Builder::new()
        .name("journal-hook-stdin".into())
        .spawn(move || stdin.write_all(&input).and_then(|_| stdin.write_all(b"\n")))
    {
        Ok(writer) => writer,
        Err(error) => {
            terminate_hook_child(&mut child);
            return (None, Some(format!("could not start hook stdin writer: {error}")));
        }
    };
    let timeout = Duration::from_millis(delivery.manifest.exec.timeout_ms);
    match child.wait_timeout(timeout) {
        Ok(Some(status)) => {
            let code = status.code();
            let stdin_error = match stdin_writer.join() {
                Ok(Ok(())) => None,
                Ok(Err(error)) if error.kind() == std::io::ErrorKind::BrokenPipe => None,
                Ok(Err(error)) => Some(format!("write hook envelope: {error}")),
                Err(_) => Some("hook stdin writer panicked".into()),
            };
            let error = if status.success() {
                stdin_error
            } else {
                Some(match code {
                    Some(code) => format!("hook exited with status {code}"),
                    None => "hook terminated without an exit status".into(),
                })
            };
            (code, error)
        }
        Ok(None) => {
            terminate_hook_child(&mut child);
            let _ = stdin_writer.join();
            (None, Some(format!("hook timed out after {} ms", timeout.as_millis())))
        }
        Err(error) => {
            terminate_hook_child(&mut child);
            let _ = stdin_writer.join();
            (None, Some(format!("wait for hook executable: {error}")))
        }
    }
}

fn terminate_hook_child(child: &mut std::process::Child) {
    #[cfg(unix)]
    if let Ok(process_group) = i32::try_from(child.id()) {
        // The command starts in a fresh process group, so a negative PID
        // targets only this hook and descendants that remain in its group.
        unsafe {
            libc::kill(-process_group, libc::SIGKILL);
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        JournalClass, JournalEventSchema, JournalHookDeliveryPolicy, JournalHookExec,
        JournalHookFilter, JournalHookRetry, JournalIngress, JournalProducer,
        JournalProducerManifest, JournalReplayPolicy, JournalSubject, SessionJournalRecord,
    };
    use serde_json::Value;

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
    fn hooks_do_not_reconsume_delivery_events_by_default() {
        let manifest = manifest();
        let filter = CompiledHookFilter::new(&manifest).unwrap();
        assert!(!filter.matches(&manifest, &document("hook.delivery.completed", json!({}))));
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

        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut cursor = 0;
        let mut epoch = mux.journal_event_epoch();
        let mut started = false;
        let mut completed = false;
        while std::time::Instant::now() < deadline && !completed {
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
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let started_event_id = loop {
            let page = mux.session_journal_after(0, 1024).unwrap();
            if let Some(record) = page.records.into_iter().find(|record| {
                record.kind == "hook.delivery.started"
                    && record.payload["source_event_id"].as_str() == Some(&source.event_id)
            }) {
                break record.event_id;
            }
            assert!(std::time::Instant::now() < deadline, "source delivery did not start");
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
            .journal_events_caused_by_hook("test_hook", std::slice::from_ref(&child.event_id))
            .unwrap();
        assert!(causal.contains(&child.event_id));

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
            assert!(std::time::Instant::now() < deadline, "hook cursor did not scan child event");
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
}

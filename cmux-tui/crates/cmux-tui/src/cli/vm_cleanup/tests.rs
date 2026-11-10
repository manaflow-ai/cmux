//! `cmux vm rm --wait --with-snapshots`, `vm snapshots --orphaned` and `vm snapshot rm`: what they
//! send and wait for, against fake app and VM API answers, degenerate ones included.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::cloud_start_chat::{Ran, Runner};
use super::{
    AppApi, Backend, CONFIRM_WAIT, Command, DEFAULT_TIMEOUT, DELETE_TRIES, MachineRow, Rm,
    SnapshotRow, VmApi, all_pages, error_code, execute, human, not_listed, parse, rm, snapshot_rm,
    snapshots, with_vm_api,
};

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn vm(n: usize) -> String {
    format!("vm_m{n:025}")
}

fn snap(n: usize) -> String {
    format!("snap_s{n:025}")
}

fn machine(id: &str, name: &str, status: &str) -> MachineRow {
    MachineRow { id: id.to_owned(), name: Some(name.to_owned()), status: status.to_owned() }
}

fn snapshot(id: &str, of: &str) -> SnapshotRow {
    SnapshotRow {
        id: id.to_owned(),
        machine: Some(of.to_owned()),
        name: None,
        status: Some("ready".to_owned()),
        created_at: json!(1_790_000_000_000i64),
        archive: false,
    }
}

/// How one snapshot's delete answers.
#[derive(Clone)]
enum OnDelete {
    /// Accepted; the snapshot leaves the list after this many list reads.
    Goes(u32),
    /// Refused every time with this error; it stays listed.
    Fails(Value),
}

/// A team's VMs and snapshots in memory, with a clock that moves only when the command pauses.
struct Fake {
    route: &'static str,
    needs_via: bool,
    machines: Vec<MachineRow>,
    snapshots: Vec<SnapshotRow>,
    page: usize,
    /// A deleted VM reads `deleting` this many times, then is gone.
    machine_reads_left: HashMap<String, u32>,
    /// The VM delete answers this error (it was gone already, or it vanishes then).
    machine_delete_error: Option<Value>,
    on_delete: HashMap<String, OnDelete>,
    /// Snapshot ids leaving the list: reads left before they do.
    leaving: HashMap<String, u32>,
    log: Vec<String>,
    start: Instant,
    waited: Duration,
    /// How long each snapshot delete takes (an Allow prompt, a slow request).
    delete_takes: Duration,
    /// A snapshot delete routed through this VM makes it vanish (deleted elsewhere meanwhile).
    vanishes: Option<String>,
}

impl Fake {
    fn new(route: &'static str) -> Self {
        Self {
            route,
            needs_via: route == "app",
            machines: Vec::new(),
            snapshots: Vec::new(),
            page: 100,
            machine_reads_left: HashMap::new(),
            machine_delete_error: None,
            on_delete: HashMap::new(),
            leaving: HashMap::new(),
            log: Vec::new(),
            start: Instant::now(),
            waited: Duration::ZERO,
            delete_takes: Duration::ZERO,
            vanishes: None,
        }
    }

    fn deletes(&self, prefix: &str) -> Vec<&String> {
        self.log.iter().filter(|line| line.starts_with(prefix)).collect()
    }

    fn page_of<T: Clone>(
        rows: &[T],
        page: usize,
        cursor: Option<&str>,
    ) -> (Vec<T>, Option<String>) {
        let at: usize = cursor.and_then(|cursor| cursor.parse().ok()).unwrap_or(0);
        let end = (at + page).min(rows.len());
        let next = (end < rows.len()).then(|| end.to_string());
        (rows.get(at..end).map(<[T]>::to_vec).unwrap_or_default(), next)
    }
}

impl Backend for Fake {
    fn route(&self) -> &'static str {
        self.route
    }

    fn machine_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<MachineRow>, Option<String>), Value> {
        self.log.push("list machines".into());
        Ok(Self::page_of(&self.machines, self.page, cursor))
    }

    fn machine_status(&mut self, id: &str) -> Result<Option<String>, Value> {
        self.log.push(format!("get {id}"));
        if let Some(left) = self.machine_reads_left.get_mut(id) {
            if *left == 0 {
                self.machines.retain(|row| row.id != id);
            } else {
                *left -= 1;
            }
        }
        Ok(self.machines.iter().find(|row| row.id == id).map(|row| row.status.clone()))
    }

    fn snapshot_page(
        &mut self,
        cursor: Option<&str>,
    ) -> Result<(Vec<SnapshotRow>, Option<String>), Value> {
        self.log.push("list snapshots".into());
        if cursor.is_none() {
            let mut gone = Vec::new();
            for (id, left) in &mut self.leaving {
                if *left == 0 {
                    gone.push(id.clone());
                } else {
                    *left -= 1;
                }
            }
            self.snapshots.retain(|row| !gone.contains(&row.id));
        }
        Ok(Self::page_of(&self.snapshots, self.page, cursor))
    }

    fn delete_snapshot(&mut self, id: &str, via: Option<&str>) -> Result<(), Value> {
        self.log.push(format!("delete snapshot {id} via {}", via.unwrap_or("-")));
        self.waited += self.delete_takes;
        if via.is_some() && via == self.vanishes.as_deref() {
            self.machines.retain(|row| Some(row.id.as_str()) != via);
        }
        if !self.snapshots.iter().any(|row| row.id == id) {
            return Err(json!({"code": "cloud.snapshot.not_found", "message": "gone"}));
        }
        match self.on_delete.get(id).cloned().unwrap_or(OnDelete::Goes(0)) {
            OnDelete::Goes(reads) => {
                self.leaving.entry(id.to_owned()).or_insert(reads);
                Ok(())
            }
            OnDelete::Fails(error) => Err(error),
        }
    }

    fn delete_machine(&mut self, id: &str) -> Result<(), Value> {
        self.log.push(format!("delete machine {id}"));
        if let Some(error) = self.machine_delete_error.clone() {
            self.machines.retain(|row| row.id != id);
            return Err(error);
        }
        if let Some(row) = self.machines.iter_mut().find(|row| row.id == id) {
            row.status = "deleting".into();
            self.machine_reads_left.entry(id.to_owned()).or_insert(2);
        }
        Ok(())
    }

    fn needs_via(&self) -> bool {
        self.needs_via
    }

    fn pause(&mut self, duration: Duration) {
        self.waited += duration;
    }

    fn now(&mut self) -> Instant {
        self.start + self.waited
    }
}

fn rm_request(named: &str) -> Rm {
    Rm { named: named.to_owned(), wait: true, with_snapshots: true, timeout: DEFAULT_TIMEOUT }
}

#[test]
fn parse_takes_only_the_new_forms() {
    let parsed = |list: &[&str]| parse(&words(list));
    assert_eq!(
        parsed(&["rm", "dev", "--confirm", "--wait", "--with-snapshots", "--timeout", "60"]),
        Some(Ok(Command::Rm(Rm {
            named: "dev".into(),
            wait: true,
            with_snapshots: true,
            timeout: Duration::from_secs(60),
        })))
    );
    assert_eq!(
        parsed(&["rm", "--target", "vm:vm_x", "--confirm", "--wait"]),
        Some(Ok(Command::Rm(Rm {
            named: "vm_x".into(),
            wait: true,
            with_snapshots: false,
            timeout: DEFAULT_TIMEOUT,
        })))
    );
    // Plain `vm rm` and `vm snapshot rm` without --confirm stay where they were.
    assert_eq!(parsed(&["rm", "dev", "--confirm"]), None);
    assert_eq!(parsed(&["snapshot", "rm", "snap_x"]), None);
    assert_eq!(parsed(&["snapshot", "ls"]), None);
    assert!(
        matches!(parsed(&["rm", "dev", "--wait"]), Some(Err(message)) if message.contains("--confirm"))
    );
    assert!(matches!(parsed(&["rm", "a", "b", "--confirm", "--wait"]), Some(Err(_))));
    assert!(matches!(parsed(&["rm", "a", "--confirm", "--wait", "--timeout", "0"]), Some(Err(_))));
    assert_eq!(
        parsed(&["snapshots", "--orphaned"]),
        Some(Ok(Command::Snapshots { orphaned: true }))
    );
    assert!(matches!(parsed(&["snapshots", "--bogus"]), Some(Err(_))));
    assert_eq!(
        parsed(&["snapshot", "rm", "snap_a", "snap_b", "snap_a", "--confirm"]),
        Some(Ok(Command::SnapshotRm {
            ids: words(&["snap_a", "snap_b"]),
            timeout: DEFAULT_TIMEOUT
        }))
    );
    assert!(matches!(parsed(&["snapshot", "rm", "--confirm"]), Some(Err(_))));
    assert!(matches!(parsed(&["snapshots", "--help"]), Some(Ok(Command::Help(_)))));
}

#[test]
fn rm_with_snapshots_is_one_step_and_leaves_nothing() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running"), machine(&vm(2), "other", "running")];
    fake.snapshots =
        vec![snapshot(&snap(1), &vm(1)), snapshot(&snap(2), &vm(2)), snapshot(&snap(3), &vm(1))];
    fake.on_delete.insert(snap(3), OnDelete::Goes(2));
    let answer = rm(&mut fake, &rm_request("dev")).expect("cleanup");
    assert_eq!(answer["machine_id"], json!(vm(1)));
    assert_eq!(answer["gone"], json!(true));
    assert_eq!(answer["already_gone"], json!(false));
    assert_eq!(answer["snapshots"]["deleted"], json!([snap(1), snap(3)]));
    assert_eq!(answer["snapshots"]["failed"], json!([]));
    assert_eq!(answer["leftovers"], json!([]));
    // The other VM's snapshot stays; the snapshots went first, through the VM itself.
    assert_eq!(fake.snapshots, vec![snapshot(&snap(2), &vm(2))]);
    let order: Vec<&String> = fake.log.iter().filter(|line| line.starts_with("delete ")).collect();
    assert_eq!(
        order,
        vec![
            &format!("delete snapshot {} via {}", snap(1), vm(1)),
            &format!("delete snapshot {} via {}", snap(3), vm(1)),
            &format!("delete machine {}", vm(1)),
        ]
    );
    assert!(fake.machines.iter().all(|row| row.id != vm(1)));
}

#[test]
fn rm_without_wait_sends_the_delete_and_answers() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    let request = Rm { wait: false, with_snapshots: false, ..rm_request("dev") };
    let answer = rm(&mut fake, &request).expect("rm");
    assert_eq!(answer["gone"], json!(false));
    assert_eq!(answer["next"], json!("cmux vm ls"));
    assert!(fake.deletes("get ").is_empty(), "no wait without --wait: {:?}", fake.log);
}

#[test]
fn an_already_gone_snapshot_counts_as_deleted() {
    // The app's route: no list shows it, so nothing is sent.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    let answer = snapshot_rm(&mut fake, &[snap(7)], DEFAULT_TIMEOUT).expect("gone is done");
    assert_eq!(answer["deleted"], json!([snap(7)]));
    assert!(fake.deletes("delete snapshot").is_empty());
    // The VM API's route: the delete answers not found, which is done too.
    let mut fake = Fake::new("vm_api");
    let answer = snapshot_rm(&mut fake, &[snap(7)], DEFAULT_TIMEOUT).expect("gone is done");
    assert_eq!(answer["deleted"], json!([snap(7)]));
    assert_eq!(fake.deletes("delete snapshot").len(), 1);
}

#[test]
fn rm_of_a_machine_that_disappears_mid_wait_is_done() {
    // The delete is accepted, then the VM goes while the command waits.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.machine_reads_left.insert(vm(1), 5);
    let answer = rm(&mut fake, &rm_request("dev")).expect("gone");
    assert_eq!(answer["gone"], json!(true));
    assert_eq!(fake.deletes("get ").len(), 6);
    // It vanished between the list and the delete: the delete's not-found is done, not an error.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.machine_delete_error = Some(json!({"code": "step.failed",
        "message": "cmux: cloud.machine.not_found: no such machine"}));
    let answer = rm(&mut fake, &rm_request("dev")).expect("gone");
    assert_eq!(answer["gone"], json!(true));
    // Any other error from a delete that raced another one: gone is still done.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.machine_delete_error = Some(json!({"code": "cloud.provider.unavailable", "message": "x"}));
    assert_eq!(rm(&mut fake, &rm_request("dev")).expect("gone")["gone"], json!(true));
}

#[test]
fn rm_of_a_vm_id_already_gone_cleans_its_snapshots() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(2), "other", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let answer = rm(&mut fake, &rm_request(&vm(1))).expect("rerun finishes");
    assert_eq!(answer["already_gone"], json!(true));
    assert_eq!(answer["snapshots"]["deleted"], json!([snap(1)]));
    // Its VM is gone, so the app's delete went through the other VM.
    assert_eq!(
        fake.deletes("delete snapshot"),
        vec![&format!("delete snapshot {} via {}", snap(1), vm(2))]
    );
    assert!(fake.deletes("delete machine").is_empty());
}

#[test]
fn a_snapshot_page_of_a_thousand() {
    let mut fake = Fake::new("app");
    fake.page = 1000;
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots =
        (0..1000).map(|n| snapshot(&snap(n), &vm(if n == 0 { 1 } else { 9 }))).collect();
    let listed = snapshots(&mut fake, true).expect("list");
    assert_eq!(listed["count"], json!(999));
    let next = listed["next"].as_str().unwrap_or_default();
    assert!(next.starts_with("cmux vm snapshot rm ") && next.ends_with(" --confirm"));
    assert!(!next.contains(&snap(0)));
    let all = snapshots(&mut fake, false).expect("list");
    assert_eq!(all["count"], json!(1000));
    assert_eq!(all["snapshots"][0]["orphaned"], json!(false));
    assert_eq!(all["snapshots"][1]["orphaned"], json!(true));
    // A VM with all thousand: one rm deletes every one, read back in one list per round.
    let mut fake = Fake::new("vm_api");
    fake.page = 1000;
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots = (0..1000).map(|n| snapshot(&snap(n), &vm(1))).collect();
    let answer = rm(&mut fake, &rm_request("dev")).expect("cleanup");
    assert_eq!(answer["snapshots"]["deleted"].as_array().map(Vec::len), Some(1000));
    assert_eq!(answer["leftovers"], json!([]));
    assert!(fake.snapshots.is_empty());
    assert!(
        fake.deletes("list snapshots").len() <= 3,
        "{} list reads",
        fake.deletes("list snapshots").len()
    );
}

#[test]
fn a_snapshot_whose_delete_keeps_failing_is_bounded_and_reported() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1)), snapshot(&snap(2), &vm(1))];
    fake.on_delete.insert(
        snap(2),
        OnDelete::Fails(json!({"code": "cloud.provider.unavailable", "message": "try later"})),
    );
    let error = rm(&mut fake, &rm_request("dev")).expect_err("one snapshot stays");
    assert_eq!(error_code(&error), "vm.cleanup_incomplete");
    assert_eq!(error["details"]["snapshots"], json!([snap(2)]));
    assert_eq!(
        error["details"]["next"],
        json!(format!("cmux vm snapshot rm {} --confirm", snap(2)))
    );
    let progress = &error["details"]["progress"];
    assert_eq!(progress["snapshots"]["deleted"], json!([snap(1)]));
    assert_eq!(progress["snapshots"]["failed"][0]["tries"], json!(DELETE_TRIES));
    assert_eq!(
        progress["snapshots"]["failed"][0]["error"]["code"],
        json!("cloud.provider.unavailable")
    );
    // Tried exactly DELETE_TRIES times, within the deadline; the VM itself is still deleted.
    let tries = fake.deletes(&format!("delete snapshot {}", snap(2))).len();
    assert_eq!(tries, DELETE_TRIES as usize);
    assert_eq!(progress["gone"], json!(true));
    assert!(fake.waited <= DEFAULT_TIMEOUT);
    // A snapshot accepted but never leaving the list is bounded the same way.
    let mut fake = Fake::new("vm_api");
    fake.snapshots = vec![snapshot(&snap(3), &vm(1))];
    fake.on_delete.insert(snap(3), OnDelete::Goes(u32::MAX));
    let error = snapshot_rm(&mut fake, &[snap(3)], DEFAULT_TIMEOUT).expect_err("still listed");
    assert_eq!(error["details"]["failed"][0]["error"]["code"], json!("vm.snapshot_still_listed"));
    assert_eq!(fake.deletes("delete snapshot").len(), DELETE_TRIES as usize);
    assert!(
        fake.waited <= CONFIRM_WAIT * DELETE_TRIES + Duration::from_secs(DELETE_TRIES.into()) * 2
    );
}

#[test]
fn a_person_saying_no_is_not_retried() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    fake.on_delete.insert(
        snap(1),
        OnDelete::Fails(json!({"code": "step.failed", "message": "cmux: approval.denied: no"})),
    );
    let error = snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect_err("denied");
    assert_eq!(error["details"]["failed"][0]["tries"], json!(1));
    assert_eq!(fake.deletes("delete snapshot").len(), 1);
}

#[test]
fn the_apps_dont_allow_is_not_retried() {
    // Don't Allow fails the app's action with `declined`, which it reports as a `daemon_error`.
    for denied in [
        json!({"code": "daemon_error", "message": "declined"}),
        json!({"code": "step.failed", "message": "cmux: daemon_error: declined"}),
    ] {
        let mut fake = Fake::new("app");
        fake.machines = vec![machine(&vm(1), "dev", "running")];
        fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
        fake.on_delete.insert(snap(1), OnDelete::Fails(denied.clone()));
        let error = snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect_err("denied");
        assert_eq!(error["details"]["failed"][0]["tries"], json!(1), "{denied}");
        assert_eq!(fake.deletes("delete snapshot").len(), 1, "{denied}");
    }
    // Another daemon_error is tried again.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let flaky = json!({"code": "daemon_error", "message": "Couldn't reach cmux Cloud"});
    fake.on_delete.insert(snap(1), OnDelete::Fails(flaky));
    snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect_err("still there");
    assert_eq!(fake.deletes("delete snapshot").len(), DELETE_TRIES as usize);
}

#[test]
fn slow_deletes_stop_at_the_deadline() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots = (0..10).map(|n| snapshot(&snap(n), &vm(1))).collect();
    fake.delete_takes = Duration::from_secs(60);
    let ids: Vec<String> = (0..10).map(snap).collect();
    let error = snapshot_rm(&mut fake, &ids, Duration::from_secs(120)).expect_err("timeout");
    assert_eq!(fake.deletes("delete snapshot").len(), 2);
    assert!(fake.waited <= Duration::from_secs(120 + 60), "waited {:?}", fake.waited);
    assert_eq!(error["details"]["deleted"].as_array().map(Vec::len), Some(2));
    assert_eq!(error["details"]["failed"].as_array().map(Vec::len), Some(8));
    assert_eq!(error["details"]["failed"][0]["error"]["code"], json!("vm.wait_timeout"));
}

#[test]
fn an_apps_not_found_for_a_listed_snapshot_is_not_deleted() {
    // The VM the delete went through is gone: the app answers not found, the snapshot stays.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running"), machine(&vm(2), "spare", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let missing = json!({"code": "step.failed", "message": "cmux: cloud.machine.not_found: gone"});
    fake.on_delete.insert(snap(1), OnDelete::Fails(missing));
    let error = snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect_err("still listed");
    assert_eq!(error["details"]["deleted"], json!([]));
    assert_eq!(error["details"]["failed"][0]["id"], json!(snap(1)));
    assert_eq!(fake.deletes("delete snapshot").len(), DELETE_TRIES as usize);
    // The routing VM goes during the first try: the next try routes through a VM still there.
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running"), machine(&vm(2), "spare", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    fake.vanishes = Some(vm(1));
    let missing = json!({"code": "step.failed", "message": "cmux: cloud.machine.not_found: gone"});
    fake.on_delete.insert(snap(1), OnDelete::Fails(missing));
    snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect_err("still listed");
    let routes = fake.deletes("delete snapshot");
    assert_eq!(
        routes.first().map(|line| line.as_str()),
        Some(&*format!("delete snapshot {} via {}", snap(1), vm(1)))
    );
    assert_eq!(
        routes.get(1).map(|line| line.as_str()),
        Some(&*format!("delete snapshot {} via {}", snap(1), vm(2)))
    );
}

#[test]
fn snapshots_the_app_does_not_list_go_to_the_vm_api() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let app = snapshot_rm(&mut fake, &[snap(1), snap(2)], DEFAULT_TIMEOUT);
    assert_eq!(not_listed(&app), vec![snap(2)]);
    // The VM API deletes it: counted once, as the VM API says.
    let api = Ok(json!({"route": "vm_api", "deleted": [snap(2)], "failed": []}));
    let merged = with_vm_api(app.clone(), &[snap(2)], api).expect("both deleted");
    assert_eq!(merged["deleted"], json!([snap(1), snap(2)]));
    assert_eq!(merged["route"], json!("app+vm_api"));
    assert!(merged.get("not_listed").is_none());
    // The VM API cannot delete it: reported, never called deleted.
    let refused = json!({"code": "vm_api.exit_11", "message": "no"});
    let api = Err(json!({"code": "vm.snapshot_delete_failed", "message": "1 of 1",
        "details": {"route": "vm_api", "deleted": [], "failed": [{"id": snap(2), "tries": 1,
        "error": refused}]}}));
    let error = with_vm_api(app.clone(), &[snap(2)], api).expect_err("one failed");
    assert_eq!(error["details"]["deleted"], json!([snap(1)]));
    assert_eq!(error["details"]["failed"][0]["id"], json!(snap(2)));
    // No VM API at all: failed with its error.
    let api = Err(json!({"code": "vm.client", "message": "cannot start"}));
    let error = with_vm_api(app, &[snap(2)], api).expect_err("no client");
    assert_eq!(error["details"]["failed"][0]["error"]["code"], json!("vm.client"));
}

#[test]
fn human_output_prints_server_text_inert() {
    let planted = "\u{1b}]52;c;aGVsbG8=\u{7}evil\u{1b}[2J\u{9b}31m\r\nnext";
    let snapshots = json!({"snapshots": [{"id": planted, "machine_id": planted, "name": planted,
        "status": planted, "orphaned": true, "archive": false}],
        "next": format!("cmux vm snapshot rm {planted} --confirm")});
    let removed = json!({"deleted": [planted]});
    let gone = json!({"machine_id": planted, "already_gone": true});
    let printed = [
        human(&Command::Snapshots { orphaned: true }, &snapshots),
        human(&Command::SnapshotRm { ids: Vec::new(), timeout: DEFAULT_TIMEOUT }, &removed),
        human(&Command::Rm(rm_request(planted)), &gone),
    ];
    for text in printed {
        assert!(text.contains("evil"), "{text:?}");
        let controls: Vec<char> = text
            .chars()
            .filter(|ch| *ch != '\n' && (ch.is_control() || ('\u{80}'..='\u{9f}').contains(ch)))
            .collect();
        assert!(controls.is_empty(), "{controls:?} in {text:?}");
        // Each value stays on its own line: the planted CR LF prints as a visible `\n`.
        assert!(!text.contains("\nnext"), "{text:?}");
    }
}

#[test]
fn an_orphan_goes_through_another_vm_or_is_reported() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(2), "busy", "deleting"), machine(&vm(3), "spare", "paused")];
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let answer = snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect("deleted");
    assert_eq!(answer["deleted"], json!([snap(1)]));
    assert_eq!(
        fake.deletes("delete snapshot"),
        vec![&format!("delete snapshot {} via {}", snap(1), vm(3))]
    );
    // No VM left to route the app's delete through: reported, nothing sent, never dropped.
    let mut fake = Fake::new("app");
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let error = snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect_err("no route");
    assert_eq!(error["details"]["failed"][0]["error"]["code"], json!("vm.snapshot_needs_machine"));
    assert!(fake.deletes("delete snapshot").is_empty());
    // The VM API needs no VM at all.
    let mut fake = Fake::new("vm_api");
    fake.snapshots = vec![snapshot(&snap(1), &vm(1))];
    let answer = snapshot_rm(&mut fake, &[snap(1)], DEFAULT_TIMEOUT).expect("deleted");
    assert_eq!(answer["deleted"], json!([snap(1)]));
}

#[test]
fn a_vm_that_never_goes_ends_at_the_deadline() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running")];
    fake.machine_reads_left.insert(vm(1), u32::MAX);
    let request = Rm { timeout: Duration::from_secs(30), ..rm_request("dev") };
    let error = rm(&mut fake, &request).expect_err("timeout");
    assert_eq!(error_code(&error), "vm.wait_timeout");
    assert_eq!(error["details"]["last"], json!("deleting"));
    assert!(fake.waited <= Duration::from_secs(32));
}

#[test]
fn names_resolve_or_refuse() {
    let mut fake = Fake::new("app");
    fake.machines = vec![machine(&vm(1), "dev", "running"), machine(&vm(2), "dev", "running")];
    let error = rm(&mut fake, &rm_request("dev")).expect_err("two named dev");
    assert_eq!(error_code(&error), "cloud.ambiguous_machine");
    let error = rm(&mut fake, &rm_request("nope")).expect_err("unknown");
    assert_eq!(error_code(&error), "cloud.unknown_machine");
    assert!(fake.deletes("delete").is_empty());
}

#[test]
fn lists_follow_cursors_and_refuse_a_loop() {
    let mut fake = Fake::new("app");
    fake.page = 2;
    fake.machines = (0..5).map(|n| machine(&vm(n), "x", "running")).collect();
    fake.snapshots = vec![snapshot(&snap(1), &vm(4))];
    let listed = snapshots(&mut fake, true).expect("list");
    assert_eq!(listed["count"], json!(0), "vm 4 is on the third page");
    let looped = all_pages(|_| Ok::<_, Value>((vec![1], Some("same".to_owned()))));
    assert_eq!(looped.map_err(|error| error_code(&error)), Err("vm.list_cursor_loop".to_owned()));
}

#[test]
fn error_codes_read_from_json_or_text() {
    assert_eq!(error_code(&json!({"code": "approval.denied"})), "approval.denied");
    assert_eq!(
        error_code(
            &json!({"code": "step.failed", "message": "cmux: cloud.machine.not_found: gone"})
        ),
        "cloud.machine.not_found"
    );
    assert_eq!(
        error_code(&json!({"code": "step.failed", "message": "cmux: the app said no"})),
        "step.failed"
    );
}

/// Answers `cmux` steps from a queue per first two words, and records them.
struct Steps {
    answers: HashMap<String, VecDeque<Ran>>,
    ran: Vec<Vec<String>>,
}

impl Steps {
    fn new(answers: Vec<(&str, Vec<Ran>)>) -> Self {
        Self {
            answers: answers.into_iter().map(|(key, list)| (key.to_owned(), list.into())).collect(),
            ran: Vec::new(),
        }
    }
}

fn ok(value: Value) -> Ran {
    Ran { code: 0, stdout: value.to_string(), stderr: String::new() }
}

fn err(text: &str) -> Ran {
    Ran { code: 1, stdout: String::new(), stderr: text.to_owned() }
}

impl Runner for Steps {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.ran.push(args.to_vec());
        let key = if args.first().map(String::as_str) == Some("apps") {
            args.get(3).cloned().unwrap_or_default()
        } else {
            args.iter().take(2).cloned().collect::<Vec<_>>().join(" ")
        };
        self.answers
            .get_mut(&key)
            .and_then(VecDeque::pop_front)
            .unwrap_or_else(|| err(&format!("unexpected step {key}")))
    }
    fn pause(&mut self, _duration: Duration) {}
    fn now(&mut self) -> Instant {
        Instant::now()
    }
    fn fresh_name(&mut self) -> String {
        String::new()
    }
}

#[test]
fn the_app_route_sends_the_cloud_apps_ops_and_actions() {
    let mut steps = Steps::new(vec![
        (
            "cloud.machine.list",
            vec![
                ok(
                    json!({"machines": [{"id": vm(1), "name": "dev", "status": "running"}], "next_cursor": "c2"}),
                ),
                ok(
                    json!({"machines": [{"id": vm(2), "name": "spare", "status": "paused"}], "next_cursor": null}),
                ),
            ],
        ),
        (
            "cloud.snapshot.list",
            vec![
                ok(
                    json!({"snapshots": [{"id": snap(1), "machine": vm(1), "name": null, "status": "ready",
                    "size_mb": 1, "created_at": 1, "revision": "1"}]}),
                ),
                ok(json!({"snapshots": []})),
                ok(json!({"snapshots": []})),
            ],
        ),
        ("cloud delete-snapshot", vec![ok(json!({"ok": true}))]),
        ("cloud kill-machine", vec![ok(json!({"ok": true}))]),
        ("cloud.machine.get", vec![err("cmux: cloud.machine.not_found: gone")]),
    ]);
    let answer = execute(&mut AppApi { runner: &mut steps }, &Command::Rm(rm_request("dev")))
        .expect("cleanup");
    assert_eq!(answer["route"], json!("app"));
    assert_eq!(answer["leftovers"], json!([]));
    let first = steps.ran.first().cloned().unwrap_or_default();
    assert_eq!(
        first.get(..5),
        Some(&words(&["apps", "run", "cmux/cloud", "cloud.machine.list", "--args"])[..])
    );
    let args = |step: Option<&Vec<String>>| -> Value {
        step.and_then(|words| words.get(5))
            .and_then(|text| serde_json::from_str(text).ok())
            .unwrap_or(Value::Null)
    };
    assert_eq!(args(steps.ran.first()), json!({"limit": 100}));
    assert_eq!(args(steps.ran.get(1)), json!({"cursor": "c2", "limit": 100}));
    let target = format!("machine:{}", vm(1));
    let snapshot_id = snap(1);
    assert!(steps.ran.contains(&words(&[
        "cloud",
        "delete-snapshot",
        "--target",
        &target,
        "--snapshot",
        &snapshot_id,
        "--confirm",
        "--json",
    ])));
    assert!(steps.ran.contains(&words(&[
        "cloud",
        "kill-machine",
        "--target",
        &target,
        "--confirm",
        "--json"
    ])));
}

#[test]
fn the_vm_api_route_reads_its_json_and_exit_codes() {
    let mut calls: Vec<Vec<String>> = Vec::new();
    let mut call = |args: &[String]| -> Ran {
        calls.push(args.to_vec());
        match args.get(1).map(String::as_str) {
            Some("list") => ok(
                json!({"items": [{"id": vm(1), "displayName": "dev", "state": "running"}], "nextCursor": null}),
            ),
            Some("snapshot") if args.get(2).map(String::as_str) == Some("list") => {
                ok(json!({"items": [
                {"id": snap(1), "sourceVmId": vm(9), "displayName": null, "createdAt": "2026-11-10T00:00:00Z"},
                {"id": snap(2), "sourceVmId": vm(1), "displayName": "base", "createdAt": "2026-11-10T00:00:00Z"}
            ], "nextCursor": null}))
            }
            // 14: the API answered 404.
            Some("snapshot") => Ran {
                code: 14,
                stdout: String::new(),
                stderr: r#"{"message":"no such snapshot"}"#.into(),
            },
            _ => err("unexpected"),
        }
    };
    let mut clock = Steps::new(Vec::new());
    let mut api = VmApi { call: &mut call, runner: &mut clock };
    let listed = snapshots(&mut api, true).expect("list");
    assert_eq!(listed["route"], json!("vm_api"));
    assert_eq!(listed["count"], json!(1));
    assert_eq!(listed["snapshots"][0]["id"], json!(snap(1)));
    let answer = snapshot_rm(&mut api, &[snap(1)], DEFAULT_TIMEOUT).expect("404 is gone");
    assert_eq!(answer["deleted"], json!([snap(1)]));
    assert!(calls.iter().all(|args| args.first().map(String::as_str) == Some("--json")));
    assert!(calls.contains(&words(&["--json", "snapshot", "delete", &snap(1), "--yes"])));
}

//! The app-lifetime coordinator. Ported from CloudCodexBrokerAdapterTests.swift: a fake holder
//! that signs in on its first `login` (a `signed-in` file in its home), and machines in memory.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use futures_util::FutureExt as _;

use super::*;
use crate::broker_files::OWN;
use crate::target::{ACCESS_PATH, MODE_PATH};
use crate::test_support::*;
use crate::types::Grant;

fn holder(short_grants: bool) -> String {
    let short = if short_grants { "yes" } else { "no" };
    format!(
        r#"holder="$3"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"login"'; then
    touch "$holder/signed-in"
    echo "{{\"id\":$id,\"result\":{{\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"TEST-CODE\"}}}}"
  elif [ -f "$holder/signed-in" ]; then
    expiry=2147483647; if [ "{short}" = yes ]; then expiry=$(($(date +%s) + 123)); fi
    echo "{{\"id\":$id,\"result\":{{\"accessToken\":\"short-access\",\"chatgptAccountId\":\"account\",\"expiresAt\":$expiry}}}}"
  else
    echo "{{\"id\":$id,\"error\":\"codex_auth_unavailable\"}}"
  fi
done
"#
    )
}

/// The machines of one test, with what they answer.
#[derive(Default)]
struct World {
    machines: Mutex<HashMap<String, Arc<Machine>>>,
    paused: AtomicBool,
    scripted_live: Mutex<VecDeque<bool>>,
    paused_checks: Counter,
    removal_gate: Mutex<Option<Arc<Gate>>>,
    removals: Counter,
    reject_capability: AtomicBool,
}

impl World {
    fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    fn machine(&self, id: &str) -> Arc<Machine> {
        self.machines.lock().unwrap().entry(id.into()).or_default().clone()
    }
    fn read(&self, id: &str, path: &str) -> Option<Vec<u8>> {
        self.machine(id).read(path)
    }
    fn write(&self, id: &str, path: &str, data: &[u8]) {
        self.machine(id).write(path, data);
    }
    fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
    }
    fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }
    fn is_live(&self) -> bool {
        if let Some(answer) = self.scripted_live.lock().unwrap().pop_front() {
            return answer;
        }
        let paused = self.paused.load(Ordering::SeqCst);
        if paused {
            self.paused_checks.add();
        }
        !paused
    }
    fn target(self: &Arc<Self>, id: &str) -> TargetRef {
        let mut fake = Fake::new(id, self.machine(id));
        let world = self.clone();
        fake.live = Some(live_fn(move || {
            let world = world.clone();
            async move { Ok(world.is_live()) }
        }));
        let world = self.clone();
        fake.before_remove = Some(hook_fn(move |_| {
            let world = world.clone();
            async move {
                let gate = world.removal_gate.lock().unwrap().take();
                if let Some(gate) = gate {
                    gate.pause().await;
                }
                world.removals.add();
                Ok(())
            }
        }));
        let world = self.clone();
        fake.capability = Some(hook_fn(move |_| {
            let world = world.clone();
            async move {
                if world.reject_capability.load(Ordering::SeqCst) {
                    return Err(BrokerError::UnsupportedMachine.into());
                }
                Ok(())
            }
        }));
        fake.arc()
    }
}

struct Fixture {
    root: tempfile::TempDir,
    launch: Launch,
    world: Arc<World>,
}

fn fixture(short_grants: bool) -> Fixture {
    let root = tempfile::tempdir().unwrap();
    let launch = launch(holder_script(root.path(), &holder(short_grants)));
    Fixture { root, launch, world: World::new() }
}

impl Fixture {
    fn adapter_in(
        &self,
        root: &Path,
        launch: &Launch,
        current: CurrentScope,
        registry: Arc<Registry>,
    ) -> Arc<Adapter> {
        let launch = launch.clone();
        let world = self.world.clone();
        Adapter::new(
            root.to_path_buf(),
            registry,
            current,
            Arc::new(move || {
                let launch = launch.clone();
                async move { Ok(launch) }.boxed()
            }),
            Arc::new(move |_: &Scope, id: &str| world.target(id)),
        )
    }
    fn adapter(&self, current: CurrentScope) -> Arc<Adapter> {
        self.adapter_in(self.root.path(), &self.launch, current, Arc::new(Registry::default()))
    }
}

fn personal() -> Scope {
    Scope::new("user", None)
}

fn present(answer: bool) -> PresentFn {
    Arc::new(move |_, _| async move { answer }.boxed())
}

fn counted_present(count: Arc<AtomicUsize>, answer: bool) -> PresentFn {
    Arc::new(move |_, _| {
        count.fetch_add(1, Ordering::SeqCst);
        async move { answer }.boxed()
    })
}

fn gated_present(gate: Arc<Gate>, count: Arc<AtomicUsize>) -> PresentFn {
    Arc::new(move |_, _| {
        count.fetch_add(1, Ordering::SeqCst);
        let gate = gate.clone();
        async move {
            gate.pause().await;
            true
        }
        .boxed()
    })
}

fn ask(answer: bool) -> Option<AskFn> {
    Some(Arc::new(move |_| async move { answer }.boxed()))
}

async fn run(
    adapter: &Arc<Adapter>,
    machine: &str,
    scope: &Scope,
    present: PresentFn,
) -> Result<(), Error> {
    adapter.run(&Cx::new(), machine, scope, true, false, None, present).await
}

fn spawn_run(
    adapter: &Arc<Adapter>,
    machine: &str,
    scope: &Scope,
    present: PresentFn,
) -> tokio::task::JoinHandle<Result<(), Error>> {
    let (adapter, machine, scope) = (adapter.clone(), machine.to_owned(), scope.clone());
    tokio::spawn(async move { run(&adapter, &machine, &scope, present).await })
}

fn mac_grant(token: &str, account: &str, expires_at: f64) -> Grant {
    Grant { access_token: token.into(), account: account.into(), expires_at }
}

fn local(source: impl Fn() -> Option<Grant> + Send + Sync + 'static) -> Option<LocalSignIn> {
    let source = Arc::new(source);
    Some(Arc::new(move || {
        let grant = source();
        async move { grant }.boxed()
    }))
}

fn text(data: Option<Vec<u8>>) -> String {
    String::from_utf8(data.unwrap_or_default()).unwrap()
}

#[test]
fn homes_are_stable_and_separate_for_every_account_scope() {
    let root = Path::new("/r");
    let scopes = [
        Scope::new("user", None),
        Scope::new("user", Some("")),
        Scope::new("user", Some("a/b")),
        Scope::new("user/a", Some("b")),
        Scope::new("other", None),
    ];
    let homes: HashSet<PathBuf> = scopes.iter().map(|s| home(root, s)).collect();
    assert_eq!(homes.len(), scopes.len());
    assert_eq!(home(root, &scopes[0]), home(root, &scopes[0]));
    assert_eq!(home(root, &scopes[0]).file_name().unwrap().len(), 64);
}

#[tokio::test(flavor = "multi_thread")]
async fn cancelled_first_login_preserves_vm_mode_and_stops_registration() {
    let f = fixture(false);
    let registry = Arc::new(Registry::default());
    let adapter = f.adapter_in(f.root.path(), &f.launch, fixed_scope(personal()), registry.clone());
    f.world.write("vm", MODE_PATH, b"team\n");
    assert_eq!(
        run(&adapter, "vm", &personal(), present(false)).await,
        Err(BrokerError::Cancelled.into())
    );
    assert_eq!(text(f.world.read("vm", MODE_PATH)), "team\n");
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    assert!(registry.existing(&personal()).unwrap().registered_machine_ids().is_empty());
    adapter.shutdown().await;
}

/// Leo, 2026-11-05: "those subscriptions should all be detectable". Once the person says yes, a
/// machine gets the access the Mac's own Codex holds: no device code, and the private holder
/// never signs in.
#[tokio::test(flavor = "multi_thread")]
async fn the_macs_own_codex_sign_in_replaces_the_device_code_once_allowed() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    let allowed = Arc::new(AtomicBool::new(false));
    let a = allowed.clone();
    adapter.set_local_sign_in(local(move || {
        a.load(Ordering::SeqCst)
            .then(|| mac_grant("mac-access", "account", crate::types::now() + 3600.0))
    }));
    let (asked, prompts) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
    let (q, al) = (asked.clone(), allowed.clone());
    let ask_once: AskFn = Arc::new(move |_| {
        q.fetch_add(1, Ordering::SeqCst);
        al.store(true, Ordering::SeqCst);
        async { true }.boxed()
    });
    adapter
        .run(
            &Cx::new(),
            "vm",
            &personal(),
            true,
            false,
            Some(ask_once.clone()),
            counted_present(prompts.clone(), false),
        )
        .await
        .unwrap();
    assert_eq!((asked.load(Ordering::SeqCst), prompts.load(Ordering::SeqCst)), (1, 0));
    let delivered = text(f.world.read("vm", ACCESS_PATH));
    assert!(delivered.contains("mac-access") && !delivered.contains("refresh"));
    // Silent after the yes: a second machine is asked nothing.
    adapter
        .run(
            &Cx::new(),
            "vm2",
            &personal(),
            true,
            false,
            Some(ask_once),
            counted_present(prompts.clone(), false),
        )
        .await
        .unwrap();
    assert_eq!((asked.load(Ordering::SeqCst), prompts.load(Ordering::SeqCst)), (1, 0));
    adapter.shutdown().await;
}

/// A grant from the Mac's Codex renews while a newer Mac token still qualifies (15 min left).
#[tokio::test(flavor = "multi_thread")]
async fn a_mac_grant_renews_before_the_local_cutoff() {
    let f = fixture(false);
    let registry = Arc::new(Registry::default());
    let adapter = f.adapter_in(f.root.path(), &f.launch, fixed_scope(personal()), registry.clone());
    let expiry = crate::types::now() + 3600.0;
    adapter.set_local_sign_in(local(move || Some(mac_grant("mac-access", "account", expiry))));
    adapter
        .run(&Cx::new(), "vm", &personal(), true, false, ask(true), present(false))
        .await
        .unwrap();
    let renewal = registry.existing(&personal()).unwrap().scheduled_renewal().unwrap();
    assert!(renewal <= expiry - crate::local_access::MINIMUM_LIFETIME);
    adapter.shutdown().await;
}

/// Taking the yes back stops the Mac's token at once: a later machine never gets the cached one.
#[tokio::test(flavor = "multi_thread")]
async fn a_taken_back_yes_never_delivers_the_cached_mac_token() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    let allowed = Arc::new(AtomicBool::new(true));
    let a = allowed.clone();
    adapter.set_local_sign_in(local(move || {
        a.load(Ordering::SeqCst)
            .then(|| mac_grant("mac-access", "account", crate::types::now() + 3600.0))
    }));
    adapter
        .run(&Cx::new(), "vm", &personal(), true, false, ask(true), present(false))
        .await
        .unwrap();
    allowed.store(false, Ordering::SeqCst);
    let prompts = Arc::new(AtomicUsize::new(0));
    adapter
        .run(
            &Cx::new(),
            "vm2",
            &personal(),
            true,
            false,
            ask(false),
            counted_present(prompts.clone(), true),
        )
        .await
        .unwrap();
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    assert!(!text(f.world.read("vm2", ACCESS_PATH)).contains("mac-access"));
    adapter.shutdown().await;
}

/// The Mac signed in to another Codex account: the first one's cached token is never delivered again.
#[tokio::test(flavor = "multi_thread")]
async fn another_mac_account_drops_the_cached_token() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    let switched = Arc::new(AtomicBool::new(false));
    let expiry = crate::types::now() + 3600.0;
    let s = switched.clone();
    adapter.set_local_sign_in(local(move || {
        Some(if s.load(Ordering::SeqCst) {
            mac_grant("mac-b", "b", expiry)
        } else {
            mac_grant("mac-a", "a", expiry)
        })
    }));
    adapter
        .run(&Cx::new(), "vm", &personal(), true, false, ask(true), present(false))
        .await
        .unwrap();
    switched.store(true, Ordering::SeqCst);
    adapter
        .run(&Cx::new(), "vm2", &personal(), true, false, ask(true), present(false))
        .await
        .unwrap();
    let delivered = text(f.world.read("vm2", ACCESS_PATH));
    assert!(delivered.contains("mac-b") && !delivered.contains("mac-a"));
    adapter.shutdown().await;
}

/// A no (or no Mac sign-in) keeps the device code exactly as before.
#[tokio::test(flavor = "multi_thread")]
async fn a_declined_mac_sign_in_falls_back_to_the_device_code() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    adapter.set_local_sign_in(local(|| None));
    let prompts = Arc::new(AtomicUsize::new(0));
    adapter
        .run(
            &Cx::new(),
            "vm",
            &personal(),
            true,
            false,
            ask(false),
            counted_present(prompts.clone(), true),
        )
        .await
        .unwrap();
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    assert!(text(f.world.read("vm", ACCESS_PATH)).contains("short-access"));
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn reuses_login_across_vms_and_app_restart_and_cleans_delivered_files() {
    let f = fixture(false);
    let scope = Scope::new("user", Some("team"));
    let adapter = f.adapter(fixed_scope(scope.clone()));
    let prompts = Arc::new(AtomicUsize::new(0));
    run(&adapter, "one", &scope, counted_present(prompts.clone(), true)).await.unwrap();
    run(&adapter, "two", &scope, counted_present(prompts.clone(), true)).await.unwrap();
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    assert!(
        f.world.read("one", ACCESS_PATH).is_some() && f.world.read("two", ACCESS_PATH).is_some()
    );
    adapter.shutdown().await;
    assert!(
        f.world.read("one", ACCESS_PATH).is_none() && f.world.read("two", ACCESS_PATH).is_none()
    );
    let restarted = f.adapter(fixed_scope(scope.clone()));
    run(&restarted, "three", &scope, counted_present(prompts.clone(), true)).await.unwrap();
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    restarted.shutdown().await;
}

/// #33482: a quit or an update leaves delivered access on each machine; the next run's sign-out
/// still erases it whole.
#[tokio::test(flavor = "multi_thread")]
async fn quit_leaves_delivered_access_and_the_next_runs_sign_out_erases_it() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    f.world.write("one", MODE_PATH, b"team\n");
    run(&adapter, "one", &personal(), present(true)).await.unwrap();
    run(&adapter, "two", &personal(), present(true)).await.unwrap();
    let delivered = f.world.read("one", ACCESS_PATH).unwrap();
    let removals = f.world.removals.get();
    adapter.detach_for_quit().await;
    assert_eq!(f.world.removals.get(), removals);
    assert_eq!(f.world.read("one", ACCESS_PATH), Some(delivered));
    assert!(f.world.read("two", ACCESS_PATH).is_some());
    assert_eq!(f.world.read("one", MODE_PATH).as_deref(), Some(OWN));
    assert!(adapter.pending_cleanup().is_empty());
    assert_eq!(
        run(&adapter, "one", &personal(), present(true)).await,
        Err(BrokerError::Cancelled.into())
    );
    // The relaunched app delivers again over the marker its last run left, then signs out: each
    // machine gets back the mode it had before the first run.
    let relaunched = f.adapter(fixed_scope(personal()));
    run(&relaunched, "one", &personal(), present(true)).await.unwrap();
    run(&relaunched, "two", &personal(), present(true)).await.unwrap();
    relaunched.sign_out().await;
    assert!(f.world.read("one", ACCESS_PATH).is_none());
    assert_eq!(text(f.world.read("one", MODE_PATH)), "team\n");
    assert!(f.world.read("two", ACCESS_PATH).is_none() && f.world.read("two", MODE_PATH).is_none());
    relaunched.shutdown().await;
}

/// cmux#33878: renewal picks back up after a relaunch on each machine the last run left access on.
#[tokio::test(flavor = "multi_thread")]
async fn relaunch_resumes_renewal_on_machines_the_last_run_left_access_on() {
    let f = fixture(true);
    let adapter = f.adapter(fixed_scope(personal()));
    f.world.write("one", MODE_PATH, b"team\n");
    run(&adapter, "one", &personal(), present(true)).await.unwrap();
    adapter.detach_for_quit().await;
    let left = f.world.read("one", ACCESS_PATH).unwrap();
    let commits = f.world.machine("one").commits.get();

    let relaunched = f.adapter(fixed_scope(personal()));
    assert!(!relaunched.delivers("one", &personal()));
    relaunched.resume(&Cx::new(), &personal(), &HashSet::from(["one".to_owned()])).await;
    assert!(relaunched.delivers("one", &personal()));
    // The left grant expires 123 s out, so its renewal is due within seconds.
    f.world.machine("one").commits.wait(commits + 1).await;
    assert_ne!(f.world.read("one", ACCESS_PATH), Some(left));
    assert_eq!(f.world.read("one", MODE_PATH).as_deref(), Some(OWN));
    // A renewal keeps the person's mode from before the first run, so a sign-out restores it.
    relaunched.sign_out().await;
    assert!(f.world.read("one", ACCESS_PATH).is_none());
    assert_eq!(text(f.world.read("one", MODE_PATH)), "team\n");
    assert!(Record::new(&relaunched.home(&personal())).entries().is_empty());
}

/// cmux#33877: after a relaunch a sign-out erases what an earlier run left. A machine paused at
/// the sign-out is erased, never renewed, once it is back.
#[tokio::test(flavor = "multi_thread")]
async fn sign_out_after_relaunch_erases_access_an_earlier_run_left() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    f.world.write("one", MODE_PATH, b"team\n");
    run(&adapter, "one", &personal(), present(true)).await.unwrap();
    run(&adapter, "two", &personal(), present(true)).await.unwrap();
    adapter.detach_for_quit().await;
    let record = Record::new(&adapter.home(&personal()));
    assert_eq!(record.entries(), HashMap::from([("one".into(), false), ("two".into(), false)]));

    let relaunched = f.adapter(fixed_scope(personal()));
    relaunched.resume(&Cx::new(), &personal(), &HashSet::from(["one".to_owned()])).await;
    relaunched.sign_out().await;
    assert!(f.world.read("one", ACCESS_PATH).is_none());
    assert_eq!(text(f.world.read("one", MODE_PATH)), "team\n");
    assert!(f.world.read("two", ACCESS_PATH).is_some());
    assert_eq!(record.entries(), HashMap::from([("two".into(), true)]));

    let later = f.adapter(fixed_scope(personal()));
    later
        .resume(&Cx::new(), &personal(), &HashSet::from(["one".to_owned(), "two".to_owned()]))
        .await;
    assert!(f.world.read("two", ACCESS_PATH).is_none() && f.world.read("two", MODE_PATH).is_none());
    assert!(!later.delivers("two", &personal()));
    assert!(record.entries().is_empty());
    later.shutdown().await;
}

/// cmux#33877: the off switch and an account or team switch erase what an earlier run left too;
/// a machine whose Codex the person signed in some other way since is left alone.
#[tokio::test(flavor = "multi_thread")]
async fn off_switch_and_switch_after_relaunch_erase_access_an_earlier_run_left() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    for machine in ["one", "two", "mine"] {
        run(&adapter, machine, &personal(), present(true)).await.unwrap();
    }
    adapter.detach_for_quit().await;
    // While cmux was quit the person signed Codex in on "mine" themselves.
    f.world.write("mine", MODE_PATH, b"personal\n");

    let off = f.adapter(fixed_scope(personal()));
    off.resume(&Cx::new(), &personal(), &HashSet::from(["one".to_owned(), "mine".to_owned()]))
        .await;
    assert!(f.world.read("mine", ACCESS_PATH).is_some());
    assert_eq!(text(f.world.read("mine", MODE_PATH)), "personal\n");
    off.set_available(false);
    off.shutdown().await;
    assert!(f.world.read("one", ACCESS_PATH).is_none() && f.world.read("one", MODE_PATH).is_none());
    let record = Record::new(&off.home(&personal()));
    assert_eq!(record.entries(), HashMap::from([("two".into(), true)]));

    // Cloud back on: one more run delivers to "three" and quits, and the next run switches teams.
    let again = f.adapter(fixed_scope(personal()));
    run(&again, "three", &personal(), present(true)).await.unwrap();
    again.detach_for_quit().await;
    let account = Account::new(personal());
    let switching = f.adapter(account.current());
    switching.resume(&Cx::new(), &personal(), &HashSet::from(["three".to_owned()])).await;
    assert!(f.world.read("three", ACCESS_PATH).is_some());
    account.set(Some(Scope::new("user", Some("team"))));
    switching.scope_did_change().await;
    assert!(
        f.world.read("three", ACCESS_PATH).is_none() && f.world.read("three", MODE_PATH).is_none()
    );
    assert_eq!(record.entries(), HashMap::from([("two".into(), true)]));
    switching.shutdown().await;
}

/// A relaunch takes back only this holder's delivery; another Mac's over it is left alone.
#[tokio::test(flavor = "multi_thread")]
async fn resume_leaves_another_holders_delivery_alone() {
    let f = fixture(false);
    let other_root = tempfile::tempdir().unwrap();
    let other_launch = launch(holder_script(other_root.path(), &holder(false)));
    let first = f.adapter(fixed_scope(personal()));
    run(&first, "vm", &personal(), present(true)).await.unwrap();
    first.detach_for_quit().await;
    let other_mac = f.adapter_in(
        other_root.path(),
        &other_launch,
        fixed_scope(personal()),
        Arc::new(Registry::default()),
    );
    run(&other_mac, "vm", &personal(), present(true)).await.unwrap();
    let theirs = f.world.read("vm", ACCESS_PATH);

    let relaunched = f.adapter(fixed_scope(personal()));
    relaunched.resume(&Cx::new(), &personal(), &HashSet::from(["vm".to_owned()])).await;
    assert!(!relaunched.delivers("vm", &personal()));
    assert!(Record::new(&relaunched.home(&personal())).entries().is_empty());
    relaunched.sign_out().await;
    assert_eq!(f.world.read("vm", ACCESS_PATH), theirs);
    other_mac.shutdown().await;
}

/// A sign-out before any machine list still marks what the record holds for erasure, and an
/// erase that fails (the machine paused mid-way) finishes on a later pass.
#[tokio::test(flavor = "multi_thread")]
async fn sign_out_before_any_list_and_a_failed_erase_still_erase() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    adapter.detach_for_quit().await;
    let relaunched = f.adapter(fixed_scope(personal()));
    relaunched.sign_out().await;
    let record = Record::new(&relaunched.home(&personal()));
    assert_eq!(record.entries(), HashMap::from([("vm".into(), true)]));

    let later = f.adapter(fixed_scope(personal()));
    // Live when the pass starts, paused by the time the erase reaches it.
    f.world.scripted_live.lock().unwrap().extend([true, false]);
    let live = HashSet::from(["vm".to_owned()]);
    assert_eq!(later.resume(&Cx::new(), &personal(), &live).await, live);
    assert!(f.world.read("vm", ACCESS_PATH).is_some());
    assert!(later.resume(&Cx::new(), &personal(), &live).await.is_empty());
    assert!(f.world.read("vm", ACCESS_PATH).is_none() && f.world.read("vm", MODE_PATH).is_none());
    assert!(record.entries().is_empty());
    later.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn revoke_restores_an_own_mode_the_person_chose() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    f.world.write("vm", MODE_PATH, OWN);
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    assert!(f.world.read("vm", ACCESS_PATH).is_some());
    adapter.sign_out().await;
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    assert_eq!(f.world.read("vm", MODE_PATH).as_deref(), Some(OWN));
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn coalesces_concurrent_first_login_and_device_code_presentation() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    let (gate, prompts) = (Gate::new(), Arc::new(AtomicUsize::new(0)));
    let first =
        spawn_run(&adapter, "one", &personal(), gated_present(gate.clone(), prompts.clone()));
    let second =
        spawn_run(&adapter, "two", &personal(), gated_present(gate.clone(), prompts.clone()));
    gate.entered().await;
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    gate.open();
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn task_cancellation_revokes_previously_delivered_access_with_uncancelled_transport() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    assert!(f.world.read("vm", ACCESS_PATH).is_some());
    // The fake provider asks for login again while a previous grant stays delivered.
    std::fs::remove_file(adapter.home(&personal()).join("signed-in")).unwrap();
    let gate = Gate::new();
    let cx = Cx::new();
    let pending = {
        let (adapter, cx, present) =
            (adapter.clone(), cx.clone(), gated_present(gate.clone(), Arc::default()));
        tokio::spawn(
            async move { adapter.run(&cx, "vm", &personal(), true, true, None, present).await },
        )
    };
    gate.entered().await;
    cx.cancel();
    gate.open();
    assert!(pending.await.unwrap().is_err());
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    assert!(adapter.pending_cleanup().is_empty());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn paused_renewal_does_not_issue_cleanup_file_requests() {
    let f = fixture(true);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    let before = f.world.removals.get();
    f.world.pause();
    // A second scheduled probe proves the renewal before it completed.
    f.world.paused_checks.wait(2).await;
    assert_eq!(f.world.removals.get(), before);
    adapter.shutdown().await;
    assert!(adapter.pending_cleanup().contains("vm"));
}

#[tokio::test(flavor = "multi_thread")]
async fn deleting_a_machine_cancels_its_pending_login_prompt() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    let gate = Gate::new();
    let pending =
        spawn_run(&adapter, "vm", &personal(), gated_present(gate.clone(), Arc::default()));
    gate.entered().await;
    adapter.revoke("vm", &personal()).await.unwrap();
    gate.open();
    assert!(pending.await.unwrap().is_err());
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn all_concurrent_transfers_wait_for_policy_teardown() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    let gate = Gate::new();
    *f.world.removal_gate.lock().unwrap() = Some(gate.clone());
    adapter.set_available(false);
    gate.entered().await;
    adapter.set_available(true);
    let finished = Arc::new(AtomicUsize::new(0));
    let runs: Vec<_> = (0..2)
        .map(|_| {
            let (adapter, finished) = (adapter.clone(), finished.clone());
            tokio::spawn(async move {
                let result = run(&adapter, "vm", &personal(), present(true)).await;
                finished.fetch_add(1, Ordering::SeqCst);
                result
            })
        })
        .collect();
    // Neither transfer may pass the old holder's deliberately blocked cleanup barrier.
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert_eq!(finished.load(Ordering::SeqCst), 0);
    gate.open();
    for run in runs {
        run.await.unwrap().unwrap();
    }
    assert!(f.world.read("vm", ACCESS_PATH).is_some());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn failed_shutdown_retains_previous_mode_until_cleanup_succeeds() {
    let f = fixture(false);
    let registry = Arc::new(Registry::default());
    let adapter = f.adapter_in(f.root.path(), &f.launch, fixed_scope(personal()), registry.clone());
    f.world.write("vm", MODE_PATH, b"team\n");
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    f.world.pause();
    adapter.shutdown().await;
    assert!(adapter.pending_cleanup().contains("vm"));
    let replacement = f.adapter_in(f.root.path(), &f.launch, fixed_scope(personal()), registry);
    assert_eq!(
        run(&replacement, "vm", &personal(), present(true)).await,
        Err(BrokerError::RemoteDeliveryFailed.into())
    );
    f.world.resume();
    run(&replacement, "vm", &personal(), present(true)).await.unwrap();
    replacement.shutdown().await;
    assert_eq!(text(f.world.read("vm", MODE_PATH)), "team\n");
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    assert!(replacement.pending_cleanup().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn confirmed_deletion_releases_failed_cleanup_for_future_vms() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "deleted", &personal(), present(true)).await.unwrap();
    f.world.pause();
    adapter.set_available(false);
    adapter.scope_did_change().await;
    adapter.set_available(true);
    assert_eq!(
        run(&adapter, "new", &personal(), present(true)).await,
        Err(BrokerError::RemoteDeliveryFailed.into())
    );
    adapter.machine_was_deleted("deleted", &personal());
    assert!(!adapter.pending_cleanup().contains("deleted"));
    f.world.resume();
    run(&adapter, "new", &personal(), present(true)).await.unwrap();
    assert!(f.world.read("new", ACCESS_PATH).is_some());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_successful_retirement_retry_clears_its_cleanup_warning() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    f.world.pause();
    adapter.set_available(false);
    adapter.set_available(true);
    assert_eq!(
        run(&adapter, "new", &personal(), present(true)).await,
        Err(BrokerError::RemoteDeliveryFailed.into())
    );
    assert!(adapter.pending_cleanup().contains("vm"));
    f.world.resume();
    run(&adapter, "new", &personal(), present(true)).await.unwrap();
    assert!(adapter.pending_cleanup().is_empty());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn quit_cleanup_is_parallel_and_bounded_when_transport_does_not_answer() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "one", &personal(), present(true)).await.unwrap();
    run(&adapter, "two", &personal(), present(true)).await.unwrap();
    let removals = f.world.removals.get();
    let gate = Gate::new();
    *f.world.removal_gate.lock().unwrap() = Some(gate.clone());
    let start = std::time::Instant::now();
    adapter.shutdown().await;
    assert!(start.elapsed() < Duration::from_secs(6));
    assert_eq!(adapter.pending_cleanup().len(), 1);
    let remaining = [f.world.read("one", ACCESS_PATH), f.world.read("two", ACCESS_PATH)];
    assert_eq!(remaining.iter().flatten().count(), 1);
    gate.open();
    // The bounded wait never cancelled the erase itself.
    f.world.removals.wait(removals + 3).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_transfer_cleanup_deadline_does_not_cancel_the_remote_mutation() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "vm", &personal(), present(true)).await.unwrap();
    let before = f.world.removals.get();
    let gate = Gate::new();
    f.world.reject_capability.store(true, Ordering::SeqCst);
    *f.world.removal_gate.lock().unwrap() = Some(gate.clone());
    let result = run(&adapter, "vm", &personal(), present(true)).await;
    assert_eq!(result, Err(BrokerError::UnsupportedMachine.into()));
    assert!(adapter.pending_cleanup().contains("vm"));
    gate.open();
    f.world.removals.wait(before + 1).await;
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_transfer_preserves_other_machines_pending_cleanup() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    run(&adapter, "old", &personal(), present(true)).await.unwrap();
    f.world.pause();
    assert_eq!(adapter.revoke("old", &personal()).await, Err(BrokerError::TargetOffline.into()));
    f.world.resume();
    run(&adapter, "new", &personal(), present(true)).await.unwrap();
    assert!(adapter.pending_cleanup().contains("old"));
    adapter.revoke("old", &personal()).await.unwrap();
    assert!(adapter.pending_cleanup().is_empty());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_scope_switch_cancels_a_pending_prompt_without_delivery() {
    let f = fixture(false);
    let account = Account::new(personal());
    let adapter = f.adapter(account.current());
    let gate = Gate::new();
    let pending =
        spawn_run(&adapter, "vm", &personal(), gated_present(gate.clone(), Arc::default()));
    gate.entered().await;
    account.set(Some(Scope::new("other", None)));
    adapter.scope_did_change().await;
    gate.open();
    assert!(pending.await.unwrap().is_err());
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    adapter.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_policy_fence_stops_a_pending_delivery_and_reenabling_reuses_the_holder() {
    let f = fixture(false);
    let adapter = f.adapter(fixed_scope(personal()));
    let (gate, prompts) = (Gate::new(), Arc::new(AtomicUsize::new(0)));
    let pending =
        spawn_run(&adapter, "vm", &personal(), gated_present(gate.clone(), prompts.clone()));
    gate.entered().await;
    adapter.set_available(false);
    gate.open();
    assert!(pending.await.unwrap().is_err());
    assert!(f.world.read("vm", ACCESS_PATH).is_none());
    adapter.set_available(true);
    run(&adapter, "vm", &personal(), counted_present(prompts.clone(), true)).await.unwrap();
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
    assert!(f.world.read("vm", ACCESS_PATH).is_some());
    adapter.shutdown().await;
}

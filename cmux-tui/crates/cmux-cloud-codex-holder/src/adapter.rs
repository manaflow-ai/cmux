//! The app-lifetime coordinator of confirmed Codex access delivery: one holder per account
//! scope (a [`Registry`]), the device-code sign-in only when the holder has no login, the
//! machines an earlier run delivered to taken back after a relaunch, and the ends of a scope
//! (a sign-out, an account or team switch, the Cloud off switch), each of which erases what it
//! delivered. The app supplies the current scope, its prompts and the machines.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures_util::FutureExt as _;
use futures_util::future::{BoxFuture, Shared};
use sha2::{Digest as _, Sha256};

use crate::broker::{Broker, CurrentScope, Launch, LocalSignIn};
use crate::cx::{Cx, Job};
use crate::error::{BrokerError, Error};
use crate::record::Record;
use crate::registry::Registry;
use crate::target::TargetRef;
use crate::types::{Prompt, Scope};

pub type LaunchFn = Arc<dyn Fn() -> BoxFuture<'static, Result<Launch, Error>> + Send + Sync>;
pub type TargetFn = Arc<dyn Fn(&Scope, &str) -> TargetRef + Send + Sync>;
/// Asks the person once whether the Mac's own Codex sign-in may be used (true: yes, and the Mac
/// has one).
pub type AskFn = Arc<dyn Fn(Cx) -> BoxFuture<'static, bool> + Send + Sync>;
/// Shows the device code; true once the person says they signed in.
pub type PresentFn = Arc<dyn Fn(Cx, Prompt) -> BoxFuture<'static, bool> + Send + Sync>;

/// A failed transfer's erase: the wait is bounded, never the erase.
#[cfg(not(test))]
const CLEANUP_BOUND: Duration = Duration::from_secs(30);
#[cfg(test)]
const CLEANUP_BOUND: Duration = Duration::from_secs(2);
const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

type Teardown = Shared<BoxFuture<'static, ()>>;

#[derive(Default)]
struct State {
    /// Machines whose delivered file could not be erased (a paused machine). Renewal is stopped
    /// regardless; issued access expires at the provider.
    cleanup_by_scope: HashMap<Scope, HashSet<String>>,
    scopes: HashSet<Scope>,
    runs: HashMap<u64, (Scope, String, Cx)>,
    next_run: u64,
    teardowns: HashMap<Scope, Teardown>,
    stopped: bool,
    unavailable: bool,
    signing_out: Option<Scope>,
    /// The pass `machines_listed` started; one at a time.
    resume_pass: Option<Job>,
    /// The scope seen last, so a switch retires it even before any pass registered it.
    observed: Option<Scope>,
    local_sign_in: Option<LocalSignIn>,
}

pub struct Adapter {
    root: PathBuf,
    registry: Arc<Registry>,
    current_scope: CurrentScope,
    launch: LaunchFn,
    target: TargetFn,
    state: Mutex<State>,
    scope_locks: Mutex<HashMap<Scope, Arc<tokio::sync::Mutex<()>>>>,
}

impl Adapter {
    /// Making the adapter reads no credential, starts no process and asks no machine.
    pub fn new(
        root: PathBuf,
        registry: Arc<Registry>,
        current_scope: CurrentScope,
        launch: LaunchFn,
        target: TargetFn,
    ) -> Arc<Self> {
        Arc::new(Self {
            root,
            registry,
            current_scope,
            launch,
            target,
            state: Mutex::new(State::default()),
            scope_locks: Mutex::new(HashMap::new()),
        })
    }

    fn st(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Where the Mac's own Codex access is read; every holder asks it first.
    pub fn set_local_sign_in(&self, source: Option<LocalSignIn>) {
        self.st().local_sign_in = source;
    }

    pub fn available(&self) -> bool {
        !self.st().unavailable
    }

    pub fn pending_cleanup(&self) -> HashSet<String> {
        self.st().cleanup_by_scope.values().flatten().cloned().collect()
    }

    /// A stable, opaque, unambiguous account and team folder. Personal accounts and a team with
    /// an empty id stay distinct. Never imports `~/.codex`.
    pub fn home(&self, scope: &Scope) -> PathBuf {
        home(&self.root, scope)
    }

    /// Finishes one confirmed transfer, showing the device code only when the local holder needs
    /// its first login. `ask_local` comes first then: the consent to use the Mac's own sign-in.
    #[allow(clippy::too_many_arguments, reason = "one transfer's whole ask, as the app makes it")]
    pub async fn run(
        self: &Arc<Self>,
        cx: &Cx,
        machine: &str,
        scope: &Scope,
        confirmed: bool,
        force_refresh: bool,
        ask_local: Option<AskFn>,
        present: PresentFn,
    ) -> Result<(), Error> {
        if !confirmed {
            return Err(BrokerError::ConsentRequired.into());
        }
        self.check(cx, scope)?;
        self.scope_did_change().await;
        self.check(cx, scope)?;
        let resolved = (self.launch)().await?;
        self.check(cx, scope)?;
        let teardown = self.st().teardowns.get(scope).cloned();
        if let Some(teardown) = teardown {
            teardown.await;
        }
        self.check(cx, scope)?;
        let broker = self.open_broker(scope, resolved).await?;
        self.check(cx, scope)?;
        let vm = (self.target)(scope, machine);
        let run_cx = cx.child();
        let id = {
            let mut state = self.st();
            state.scopes.insert(scope.clone());
            state.next_run = state.next_run.saturating_add(1);
            let id = state.next_run;
            state.runs.insert(id, (scope.clone(), machine.to_owned(), run_cx.clone()));
            id
        };
        let result = self
            .transfer_once(&run_cx, scope, &broker, &vm, force_refresh, ask_local, present)
            .await;
        self.st().runs.remove(&id);
        result?;
        self.check(cx, scope)
    }

    #[allow(clippy::too_many_arguments, reason = "the run's parts, passed down once")]
    async fn transfer_once(
        &self,
        cx: &Cx,
        scope: &Scope,
        broker: &Arc<Broker>,
        vm: &TargetRef,
        force_refresh: bool,
        ask_local: Option<AskFn>,
        present: PresentFn,
    ) -> Result<(), Error> {
        let _scope_lock = self.lock_scope(scope).await;
        self.check(cx, scope)?;
        let result: Result<(), Error> = async {
            match broker.transfer(cx, vm, true, force_refresh).await {
                Err(error) if error.is(BrokerError::NotAuthenticated) => {
                    self.check(cx, scope)?;
                    if let Some(ask) = ask_local
                        && ask(cx.clone()).await
                    {
                        self.check(cx, scope)?;
                        if broker.transfer(cx, vm, true, true).await.is_ok() {
                            return self.check(cx, scope);
                        }
                    }
                    self.check(cx, scope)?;
                    let prompt = broker.login(cx, vm, true).await?;
                    self.check(cx, scope)?;
                    if !present(cx.clone(), prompt).await {
                        return Err(BrokerError::Cancelled.into());
                    }
                    self.check(cx, scope)?;
                    broker.wait_for_login_and_transfer(cx, vm, true, LOGIN_TIMEOUT).await?;
                }
                other => {
                    other?;
                }
            }
            self.check(cx, scope)
        }
        .await;
        if let Err(error) = result {
            // Settle the failure before the next scoped transfer can register.
            if self.revoke_after_failure(broker, vm).await.is_err() {
                self.st()
                    .cleanup_by_scope
                    .entry(scope.clone())
                    .or_default()
                    .insert(vm.machine_id().to_owned());
            }
            return Err(error);
        }
        Ok(())
    }

    /// Each machine list the app reads: `resume` for the signed-in scope and its live machines.
    /// One pass at a time. A machine the pass could not take back yet (its owner link still
    /// connecting) is tried again after 15, 30 and 60 s. Stops: every machine done, the third
    /// retry, or a quit, sign-out, switch or off switch (which cancel the pass).
    pub fn machines_listed(self: &Arc<Self>, live: HashSet<String>) {
        let Some(scope) = (self.current_scope)() else { return };
        let mut state = self.st();
        if state.resume_pass.is_some() {
            return;
        }
        if state.observed.is_none() {
            state.observed = Some(scope.clone());
        }
        let weak = Arc::downgrade(self);
        state.resume_pass = Some(Job::spawn(move |cx| async move {
            let pass = |live: HashSet<String>| {
                let (weak, cx, scope) = (weak.clone(), cx.clone(), scope.clone());
                async move {
                    match weak.upgrade() {
                        Some(this) => this.resume(&cx, &scope, &live).await,
                        None => HashSet::new(),
                    }
                }
            };
            let mut left = pass(live).await;
            for delay in [15, 30, 60] {
                if left.is_empty() {
                    break;
                }
                // wakeup-allow: at most three bounded retries for machines whose owner link was not ready.
                if cx.sleep(Duration::from_secs(delay)).await.is_err() {
                    break;
                }
                left = pass(left).await;
            }
            if let Some(this) = weak.upgrade() {
                this.st().resume_pass = None;
            }
        }));
    }

    /// A holder started again while the app runs (the last one ended): the app replays what the
    /// last one knew, `scopes` it served and the `live` machines of the last list, under the
    /// scope it now holds as current. The current scope's live machines, and every one its
    /// delivery record names (one delivered after that list), are taken back: renewal goes on,
    /// and its next end erases them. Every other scope, or every scope while Cloud is off, ended
    /// while no holder ran: it ends now, and what its record holds on the live machines is
    /// erased. Each step is bounded by `CLEANUP_BOUND`; what it did not reach stays recorded and
    /// marked.
    pub async fn restore(self: &Arc<Self>, scopes: Vec<Scope>, mut live: HashSet<String>) {
        let current = (self.current_scope)();
        if let Some(scope) = &current {
            live.extend(Record::new(&self.home(scope)).entries().into_keys());
        }
        let fenced = {
            let mut state = self.st();
            if state.observed.is_none() {
                state.observed = current.clone();
            }
            state.scopes.extend(scopes);
            state.unavailable
        };
        if !fenced && let Some(scope) = current.clone() {
            let cx = Cx::new();
            let (this, pass_cx, pass_live) = (self.clone(), cx.clone(), live.clone());
            let pass = tokio::spawn(async move {
                this.resume(&pass_cx, &scope, &pass_live).await;
            });
            if tokio::time::timeout(CLEANUP_BOUND, pass).await.is_err() {
                cx.cancel();
            }
        }
        // A scope that ended while no holder ran (a switch or sign-out the last one never read,
        // or Cloud turned off) ends now; no holder of its own took its machines back, so what
        // its record holds on the live ones is erased here.
        let ending: Vec<Scope> = {
            let mut state = self.st();
            state.observed = current.clone();
            // An off switch read during the pass (it fences at once) ends the current scope too.
            let fenced = fenced || state.unavailable;
            if fenced {
                state.scopes.extend(current.clone());
            }
            state
                .scopes
                .iter()
                .filter(|scope| fenced || Some(*scope) != current.as_ref())
                .cloned()
                .collect()
        };
        for scope in ending {
            self.retire(&scope).await;
            let (this, live) = (self.clone(), live.clone());
            // The wait is bounded, never the erase.
            let erase = tokio::spawn(async move { this.erase_recorded(&scope, &live).await });
            let _ = tokio::time::timeout(CLEANUP_BOUND, erase).await;
        }
    }

    /// After a relaunch and each machine list: takes back the machines in `live` an earlier run
    /// delivered Codex access to for `scope` (the delivery record), so renewal picks back up
    /// (cmux#33878) and a sign-out, switch or off switch erases them (cmux#33877). One whose
    /// erase an earlier run could not finish is erased instead. Asks no consent and shows no
    /// prompt: each was confirmed when first delivered to. A registered machine is skipped.
    /// Returns the live recorded machines this pass could not take back or erase yet.
    pub async fn resume(
        self: &Arc<Self>,
        cx: &Cx,
        scope: &Scope,
        live: &HashSet<String>,
    ) -> HashSet<String> {
        let record = Record::new(&self.home(scope));
        let recorded = record.entries();
        if recorded.is_empty() {
            return HashSet::new();
        }
        let teardown = self.st().teardowns.get(scope).cloned();
        if let Some(teardown) = teardown {
            teardown.await;
        }
        if self.check(cx, scope).is_err() {
            return HashSet::new();
        }
        // Recorded machines belong to this scope now, so its retirement marks each for erasure.
        self.st().scopes.insert(scope.clone());
        let mut wanted: Vec<(String, bool)> =
            recorded.into_iter().filter(|(id, _)| live.contains(id)).collect();
        wanted.sort();
        if wanted.is_empty() {
            return HashSet::new();
        }
        let Ok(resolved) = (self.launch)().await else { return HashSet::new() };
        if self.check(cx, scope).is_err() {
            return HashSet::new();
        }
        let Ok(broker) = self.open_broker(scope, resolved).await else { return HashSet::new() };
        if self.check(cx, scope).is_err() {
            return HashSet::new();
        }
        let _scope_lock = self.lock_scope(scope).await;
        let registered = broker.registered_machine_ids();
        for (machine, erase) in &wanted {
            if registered.contains(machine) {
                continue;
            }
            if self.check(cx, scope).is_err() {
                return HashSet::new();
            }
            broker.resume(cx, &(self.target)(scope, machine), *erase).await;
        }
        let still = record.entries();
        let taken = broker.registered_machine_ids();
        wanted
            .into_iter()
            .map(|(id, _)| id)
            .filter(|id| still.contains_key(id) && !taken.contains(id))
            .collect()
    }

    async fn open_broker(
        self: &Arc<Self>,
        scope: &Scope,
        launch: Launch,
    ) -> Result<Arc<Broker>, Error> {
        let weak = Arc::downgrade(self);
        let available: CurrentScope = Arc::new(move || {
            let this = weak.upgrade()?;
            if this.st().unavailable {
                return None;
            }
            (this.current_scope)()
        });
        let retrying = self.registry.has_pending_cleanup(scope);
        let broker = self.registry.broker(scope, available, launch, self.home(scope)).await?;
        let mut state = self.st();
        if retrying {
            state.cleanup_by_scope.remove(scope);
        }
        broker.set_local_sign_in(state.local_sign_in.clone());
        Ok(broker)
    }

    /// Whether this scope's holder already delivers (and renews) access on `machine`. A new
    /// chat's start leaves such a machine alone: a failed repeat would revoke the access its
    /// other chats use (cmux#33489).
    pub fn delivers(&self, machine: &str, scope: &Scope) -> bool {
        self.registry.existing(scope).is_some_and(|b| b.registered_machine_ids().contains(machine))
    }

    /// Account and team observations call this even when the user stays signed in.
    pub async fn scope_did_change(self: &Arc<Self>) {
        let keep = (self.current_scope)();
        let retiring: Vec<Scope> = {
            let mut state = self.st();
            if keep != state.signing_out {
                state.signing_out = None;
            }
            // A scope left before any pass registered it still erases what its record holds (cmux#33877).
            if let Some(left) = state.observed.clone()
                && Some(&left) != keep.as_ref()
            {
                state.scopes.insert(left);
                if let Some(pass) = &state.resume_pass {
                    pass.cancel();
                }
            }
            state.observed = keep.clone();
            state.scopes.iter().filter(|s| Some(*s) != keep.as_ref()).cloned().collect()
        };
        for scope in retiring {
            self.retire(&scope).await;
        }
    }

    /// Fences holder use at once when Cloud policy is off. Turning it on again keeps the holder
    /// home on disk, so a later confirmed run reuses its login without another device code.
    /// The off switch's fence alone, at once: no request, renewal or write goes on, and running
    /// transfers and resume passes end. The retirement comes with ``set_available``.
    pub fn fence(&self) {
        Self::fence_in(&mut self.st());
    }

    fn fence_in(state: &mut State) {
        state.unavailable = true;
        for (_, _, cx) in state.runs.values() {
            cx.cancel();
        }
        if let Some(pass) = &state.resume_pass {
            pass.cancel();
        }
    }

    pub fn set_available(self: &Arc<Self>, enabled: bool) {
        let retiring: Vec<Scope> = {
            let mut state = self.st();
            // Off retires every scope each time it is said, so the outcome never depends on
            // whether an earlier line already fenced (a holder started under the fence, say).
            if enabled {
                state.unavailable = false;
                return;
            }
            Self::fence_in(&mut state);
            if let Some(scope) = (self.current_scope)() {
                state.scopes.insert(scope);
            }
            state.scopes.drain().collect()
        };
        for scope in retiring {
            self.begin_retirement(&scope);
        }
    }

    fn cancel_runs(&self, scope: Option<&Scope>, machine: Option<&str>) {
        for (run_scope, run_machine, cx) in self.st().runs.values() {
            if scope.is_none_or(|s| s == run_scope) && machine.is_none_or(|m| m == run_machine) {
                cx.cancel();
            }
        }
    }

    /// Called before deleting or unregistering a machine, while its transport still exists.
    pub async fn revoke(&self, machine: &str, scope: &Scope) -> Result<(), Error> {
        // End prompts and transfers first: accepting a prompt later must not register it again.
        self.cancel_runs(Some(scope), Some(machine));
        if !self.st().scopes.contains(scope) {
            return Ok(());
        }
        let Some(broker) = self.registry.existing(scope) else { return Ok(()) };
        let result = broker.revoke(&Cx::never(), &(self.target)(scope, machine), false).await;
        let mut state = self.st();
        let cleanup = state.cleanup_by_scope.entry(scope.clone()).or_default();
        match &result {
            Ok(()) => cleanup.remove(machine),
            Err(_) => cleanup.insert(machine.to_owned()),
        };
        result
    }

    /// Only a successful server deletion may discard a failed file cleanup.
    pub fn machine_was_deleted(&self, machine: &str, scope: &Scope) {
        self.cancel_runs(Some(scope), Some(machine));
        self.registry.discard_deleted_target(machine, scope);
        if let Some(cleanup) = self.st().cleanup_by_scope.get_mut(scope) {
            cleanup.remove(machine);
        }
    }

    /// Stops all renewal and processes and erases delivered files. Local rotating credentials
    /// stay for the next explicit, confirmed use.
    pub async fn shutdown(self: &Arc<Self>) {
        self.st().stopped = true;
        self.retire_all(None).await;
    }

    /// Quit and update: stops renewal and the local holders, but each Cloud machine keeps the
    /// access already delivered to it until the provider expires it, so an unattended Cloud
    /// Codex run outlives the quit (#33482). A sign-out, a switch, the off switch and a machine
    /// delete still erase it.
    pub async fn detach_for_quit(&self) {
        let (teardowns, scopes) = {
            let mut state = self.st();
            state.stopped = true;
            for (_, _, cx) in state.runs.values() {
                cx.cancel();
            }
            if let Some(pass) = &state.resume_pass {
                pass.cancel();
            }
            (state.teardowns.values().cloned().collect::<Vec<_>>(), state.scopes.clone())
        };
        // A sign-out or switch already under way erases, as it was asked to.
        for teardown in teardowns {
            teardown.await;
        }
        for scope in scopes {
            let Some(broker) = self.registry.existing(&scope) else { continue };
            let failed = broker.detach().await;
            if !failed.is_empty() {
                self.st().cleanup_by_scope.entry(scope).or_default().extend(failed);
            }
        }
    }

    /// Ends account access before Cloud signs out, without stopping this coordinator for good.
    pub async fn sign_out(self: &Arc<Self>) {
        let signing_out = (self.current_scope)();
        self.st().signing_out = signing_out.clone();
        self.retire_all(signing_out).await;
    }

    async fn retire_all(self: &Arc<Self>, also: Option<Scope>) {
        let retiring: Vec<Scope> = {
            let mut state = self.st();
            for (_, _, cx) in state.runs.values() {
                cx.cancel();
            }
            if let Some(pass) = &state.resume_pass {
                pass.cancel();
            }
            // Retired even before any pass registered it, so what its record holds is erased (cmux#33877).
            if let Some(scope) = also {
                state.scopes.insert(scope);
            }
            state
                .scopes
                .iter()
                .chain(state.teardowns.keys())
                .cloned()
                .collect::<HashSet<_>>()
                .into_iter()
                .collect()
        };
        for scope in &retiring {
            self.begin_retirement(scope);
        }
        for scope in &retiring {
            let teardown = self.st().teardowns.get(scope).cloned();
            if let Some(teardown) = teardown {
                teardown.await;
            }
        }
    }

    async fn revoke_after_failure(
        &self,
        broker: &Arc<Broker>,
        target: &TargetRef,
    ) -> Result<(), Error> {
        // Independent of the caller's cancel; the wait is bounded, the erase is not.
        let (broker, target) = (broker.clone(), target.clone());
        let erase = tokio::spawn(async move { broker.revoke(&Cx::never(), &target, false).await });
        match tokio::time::timeout(CLEANUP_BOUND, erase).await {
            Ok(Ok(result)) => result,
            _ => Err(BrokerError::RemoteDeliveryFailed.into()),
        }
    }

    fn begin_retirement(self: &Arc<Self>, scope: &Scope) {
        let mut state = self.st();
        if state.teardowns.contains_key(scope) {
            return;
        }
        for (run_scope, _, cx) in state.runs.values() {
            if run_scope == scope {
                cx.cancel();
            }
        }
        state.scopes.remove(scope);
        // Kept until teardown ends: every concurrent caller awaits it before a replacement opens.
        let record = Record::new(&self.home(scope));
        let (registry, weak, owned) = (self.registry.clone(), Arc::downgrade(self), scope.clone());
        let task = tokio::spawn(async move {
            let failed = registry.remove(&owned).await;
            if let Some(this) = weak.upgrade() {
                this.st().cleanup_by_scope.insert(owned.clone(), failed);
            }
            // What is still recorded (a paused machine, one this run never reached) is erased by
            // the next pass that reaches it, never renewed (cmux#33877).
            record.mark_all_for_erasure();
            if let Some(this) = weak.upgrade() {
                this.st().teardowns.remove(&owned);
            }
        });
        let teardown = async move {
            let _ = task.await;
        }
        .boxed()
        .shared();
        state.teardowns.insert(scope.clone(), teardown);
    }

    /// Erases this scope's access on every machine in `live` its delivery record names,
    /// through a holder of its own (no sign-in: an erase only removes this holder's own file).
    /// What it cannot reach stays marked for erasure.
    async fn erase_recorded(self: &Arc<Self>, scope: &Scope, live: &HashSet<String>) {
        let home = self.home(scope);
        let mut recorded: Vec<String> =
            Record::new(&home).entries().into_keys().filter(|id| live.contains(id)).collect();
        if recorded.is_empty() {
            return;
        }
        recorded.sort();
        let Ok(launch) = (self.launch)().await else { return };
        let eraser = Broker::new(
            scope.clone(),
            self.current_scope.clone(),
            launch,
            home,
            Duration::from_secs(15),
        );
        for machine in recorded {
            eraser.resume(&Cx::never(), &(self.target)(scope, &machine), true).await;
        }
        eraser.shutdown().await;
    }

    async fn retire(self: &Arc<Self>, scope: &Scope) {
        self.begin_retirement(scope);
        let teardown = self.st().teardowns.get(scope).cloned();
        if let Some(teardown) = teardown {
            teardown.await;
        }
    }

    async fn lock_scope(&self, scope: &Scope) -> tokio::sync::OwnedMutexGuard<()> {
        let lock = self
            .scope_locks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(scope.clone())
            .or_default()
            .clone();
        lock.lock_owned().await
    }

    fn check(&self, cx: &Cx, scope: &Scope) -> Result<(), Error> {
        {
            let state = self.st();
            if state.stopped
                || state.unavailable
                || state.signing_out.as_ref() == Some(scope)
                || cx.is_cancelled()
            {
                return Err(BrokerError::Cancelled.into());
            }
        }
        if (self.current_scope)().as_ref() != Some(scope) {
            return Err(BrokerError::ScopeChanged.into());
        }
        Ok(())
    }
}

/// `root/codex-holders/<sha256 of the length-prefixed user, kind and team>`.
pub fn home(root: &Path, scope: &Scope) -> PathBuf {
    let kind = if scope.team.is_none() { "personal" } else { "team" };
    let fields = [scope.user.as_str(), kind, scope.team.as_deref().unwrap_or_default()];
    let encoded: String = fields.iter().map(|f| format!("{}:{f}", f.len())).collect();
    let digest = Sha256::digest(encoded.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    root.join("codex-holders").join(hex)
}

#[cfg(test)]
#[path = "adapter_tests.rs"]
mod tests;

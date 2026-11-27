//! Fakes for the holder's tests: machines whose files live in memory, a gate a test opens, and
//! fake private holders written as shell scripts (the same ones the Swift tests used).

use std::collections::HashMap;
use std::future::Future;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures_util::FutureExt as _;
use futures_util::future::BoxFuture;
use tokio::sync::watch;

use crate::broker::{Broker, CurrentScope, Launch};
use crate::error::Error;
use crate::target::{Capability, Target, TargetRef};
use crate::types::Scope;

pub(crate) fn denied() -> Error {
    Error::Other("denied".into())
}

/// A pause a test opens once.
pub(crate) struct Gate {
    entered: watch::Sender<bool>,
    opened: watch::Sender<bool>,
}

impl Gate {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self { entered: watch::channel(false).0, opened: watch::channel(false).0 })
    }

    // `send_replace`, not `send`: a value sent before anyone subscribed is kept.
    pub(crate) async fn pause(&self) {
        self.entered.send_replace(true);
        let mut opened = self.opened.subscribe();
        let _ = opened.wait_for(|o| *o).await;
    }

    /// Waits until the work reached `pause` (or `passed` said it never will).
    pub(crate) async fn entered(&self) {
        let mut entered = self.entered.subscribe();
        let _ = entered.wait_for(|e| *e).await;
    }

    pub(crate) fn passed(&self) {
        self.entered.send_replace(true);
    }

    pub(crate) fn open(&self) {
        self.opened.send_replace(true);
    }
}

/// Counts up and lets a test wait for a value.
pub(crate) struct Counter(watch::Sender<usize>);

impl Counter {
    pub(crate) fn new() -> Self {
        Self(watch::channel(0).0)
    }
    pub(crate) fn add(&self) {
        self.0.send_modify(|n| *n += 1);
    }
    pub(crate) fn get(&self) -> usize {
        *self.0.borrow()
    }
    pub(crate) async fn wait(&self, at_least: usize) {
        let _ = self.0.subscribe().wait_for(|n| *n >= at_least).await;
    }
}

pub(crate) type Hook = Arc<dyn Fn(&str) -> BoxFuture<'static, Result<(), Error>> + Send + Sync>;
pub(crate) type LiveHook = Arc<dyn Fn() -> BoxFuture<'static, Result<bool, Error>> + Send + Sync>;

/// One machine's files and what it refuses.
#[derive(Default)]
pub(crate) struct Machine {
    pub(crate) files: Mutex<HashMap<String, Vec<u8>>>,
    pub(crate) flags: Mutex<Flags>,
    pub(crate) commits: Counter,
    pub(crate) removals: Counter,
    pub(crate) committed: Mutex<Option<[String; 4]>>,
}

#[derive(Default, Clone)]
pub(crate) struct Flags {
    pub(crate) refuse_restore: bool,
    pub(crate) refuse_commit: bool,
    pub(crate) refuse_directory: bool,
    pub(crate) refuse_removal: bool,
    pub(crate) refuse_access_read: bool,
    pub(crate) reject_capability: bool,
}

impl Default for Counter {
    fn default() -> Self {
        Self::new()
    }
}

impl Machine {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub(crate) fn read(&self, path: &str) -> Option<Vec<u8>> {
        self.files.lock().unwrap().get(path).cloned()
    }
    pub(crate) fn text(&self, path: &str) -> String {
        String::from_utf8(self.read(path).unwrap_or_default()).unwrap()
    }
    pub(crate) fn write(&self, path: &str, data: &[u8]) {
        self.files.lock().unwrap().insert(path.into(), data.to_vec());
    }
    pub(crate) fn paths(&self) -> Vec<String> {
        self.files.lock().unwrap().keys().cloned().collect()
    }
    pub(crate) fn staged(&self) -> usize {
        self.paths().iter().filter(|p| p.contains(".access-") || p.contains(".codex-")).count()
    }
    pub(crate) fn set(&self, change: impl FnOnce(&mut Flags)) {
        change(&mut self.flags.lock().unwrap());
    }
    fn flags(&self) -> Flags {
        self.flags.lock().unwrap().clone()
    }
}

/// A fake machine target: in-memory files plus optional async hooks.
#[derive(Clone)]
pub(crate) struct Fake {
    pub(crate) id: String,
    pub(crate) machine: Arc<Machine>,
    pub(crate) capability: Option<Hook>,
    pub(crate) write: Option<Hook>,
    pub(crate) before_commit: Option<Hook>,
    pub(crate) after_commit: Option<Hook>,
    pub(crate) before_remove: Option<Hook>,
    pub(crate) live: Option<LiveHook>,
    pub(crate) owner: bool,
}

impl Fake {
    pub(crate) fn new(id: &str, machine: Arc<Machine>) -> Self {
        Self {
            id: id.into(),
            machine,
            capability: None,
            write: None,
            before_commit: None,
            after_commit: None,
            before_remove: None,
            live: None,
            owner: true,
        }
    }
    pub(crate) fn arc(self) -> TargetRef {
        Arc::new(self)
    }
}

async fn hook(hook: &Option<Hook>, arg: &str) -> Result<(), Error> {
    match hook {
        Some(hook) => hook(arg).await,
        None => Ok(()),
    }
}

#[async_trait]
impl Target for Fake {
    fn machine_id(&self) -> &str {
        &self.id
    }
    async fn is_live(&self) -> Result<bool, Error> {
        match &self.live {
            Some(live) => live().await,
            None => Ok(true),
        }
    }
    async fn capability(&self) -> Result<Capability, Error> {
        hook(&self.capability, "").await?;
        if self.machine.flags().reject_capability {
            return Err(crate::error::BrokerError::UnsupportedMachine.into());
        }
        Ok(Capability {
            owner_vm: self.owner,
            protocol_version: 1,
            codex_external_access_token: true,
        })
    }
    async fn make_directory(&self, _: &str) -> Result<(), Error> {
        if self.machine.flags().refuse_directory {
            return Err(denied());
        }
        Ok(())
    }
    async fn read_file(&self, path: &str) -> Result<Option<Vec<u8>>, Error> {
        if self.machine.flags().refuse_access_read && path == crate::target::ACCESS_PATH {
            return Err(denied());
        }
        Ok(self.machine.read(path))
    }
    async fn write_file(&self, path: &str, data: &[u8], _: u32) -> Result<(), Error> {
        hook(&self.write, path).await?;
        if self.machine.flags().refuse_restore && path == crate::target::MODE_PATH {
            return Err(denied());
        }
        self.machine.write(path, data);
        Ok(())
    }
    async fn commit_files(&self, a: &str, b: &str, c: &str, d: &str) -> Result<(), Error> {
        hook(&self.before_commit, "").await?;
        if self.machine.flags().refuse_commit {
            return Err(crate::error::BrokerError::RemoteDeliveryFailed.into());
        }
        {
            let mut files = self.machine.files.lock().unwrap();
            if let Some(data) = files.get(a).cloned() {
                files.insert(b.into(), data);
            }
            if let Some(data) = files.get(c).cloned() {
                files.insert(d.into(), data);
            }
        }
        *self.machine.committed.lock().unwrap() = Some([a.into(), b.into(), c.into(), d.into()]);
        self.machine.commits.add();
        hook(&self.after_commit, "").await
    }
    async fn remove_file(&self, path: &str) -> Result<(), Error> {
        hook(&self.before_remove, path).await?;
        self.machine.removals.add();
        if self.machine.flags().refuse_removal {
            return Err(denied());
        }
        self.machine.files.lock().unwrap().remove(path);
        Ok(())
    }
}

pub(crate) fn hook_fn<F, Fut>(f: F) -> Hook
where
    F: Fn(String) -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<(), Error>> + Send + 'static,
{
    Arc::new(move |arg: &str| f(arg.to_owned()).boxed())
}

pub(crate) fn live_fn<F, Fut>(f: F) -> LiveHook
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: Future<Output = Result<bool, Error>> + Send + 'static,
{
    Arc::new(move || f().boxed())
}

/// A fake private holder: `script` is the body of a `/bin/sh` script.
pub(crate) fn holder_script(root: &Path, script: &str) -> PathBuf {
    let path = root.join(format!("broker-{}.sh", uuid::Uuid::new_v4()));
    std::fs::write(&path, format!("#!/bin/sh\n{script}")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}

/// Answers every access request with `access-N` and an expiry from `expiry` (shell, `$count` set).
pub(crate) fn counting_holder(expiry: &str) -> String {
    format!(
        r#"count=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  if printf '%s' "$line" | grep -q '"method":"access"'; then
    count=$((count + 1)); {expiry}
    echo "{{\"id\":$id,\"result\":{{\"accessToken\":\"access-$count\",\"chatgptAccountId\":\"acct-1\",\"expiresAt\":$expiry}}}}"
  fi
done
"#
    )
}

pub(crate) fn launch(executable: PathBuf) -> Launch {
    Launch {
        executable,
        prefix: Vec::new(),
        codex: PathBuf::from("/bin/false"),
        environment: std::env::vars().collect(),
        user_home: std::env::temp_dir(),
    }
}

pub(crate) fn fixed_scope(scope: Scope) -> CurrentScope {
    Arc::new(move || Some(scope.clone()))
}

/// A scope a test can sign out.
pub(crate) struct Account(Mutex<Option<Scope>>);

impl Account {
    pub(crate) fn new(scope: Scope) -> Arc<Self> {
        Arc::new(Self(Mutex::new(Some(scope))))
    }
    pub(crate) fn logout(&self) {
        *self.0.lock().unwrap() = None;
    }
    pub(crate) fn set(&self, scope: Option<Scope>) {
        *self.0.lock().unwrap() = scope;
    }
    pub(crate) fn current(self: &Arc<Self>) -> CurrentScope {
        let this = self.clone();
        Arc::new(move || this.0.lock().unwrap().clone())
    }
}

pub(crate) fn broker(
    root: &Path,
    script: &str,
    current: CurrentScope,
    retry_base: Duration,
) -> Arc<Broker> {
    let executable = holder_script(root, script);
    Broker::new(
        Scope::new("user-1", None),
        current,
        launch(executable),
        root.join("holder"),
        retry_base,
    )
}

//! Signing in enrolls this machine; signing out leaves only the join signing in made
//! (`cli/cloud_join/enroll.rs`). The app only says who is signed in now:
//! `_acpmux/machine_signed_in {userId|null, previous?, accessToken?, hub?, buildTag?}` ->
//! `{accepted, recorded?, leave, enroll}`. This daemon decides the rest:
//!
//! - The account signing out (or switched away from) is recorded at once, durably
//!   (`record_leave_intent`), before the reply and before anything waits: never queued behind an
//!   earlier change's enroll or its retry wait, which the app may not outlive.
//! - Then, one change after another: the leave (`leave_if_auto`, only that account's sign-in
//!   join), then the enroll for the person signed in, with one retry [`RETRY_WAIT`] later when the
//!   hub did not answer. A change while the retry waits ends the wait; the retry goes only while
//!   that person is still signed in.
//! - The first change this daemon sees decides with no history: signed out leaves as `previous`
//!   (the app's account before, if it knew one; else acpmux leaves as the accounts it recorded),
//!   and signed in only enrolls (an enroll that finds the last person's sign-in join finishes
//!   that leave itself). The same person again changes nothing.
//!
//! The app sends a change again when its acpmux connection comes back, so a daemon that restarted
//! before it took one still gets it.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{Notify, watch};
use zeroize::Zeroizing;

use super::Conn;
use crate::cli::cloud_join::{EnrollOutcome, EnrollRequest};
use crate::hub::Hub;
use crate::no_panic::LockExt;
use crate::rpc::RpcError;

/// The wait before an enroll the hub did not answer goes once more.
pub(crate) const RETRY_WAIT: Duration = Duration::from_secs(30);

type Boxed<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What a change does: the daemon's join (tests put their own).
pub(crate) trait Port: Send + Sync + 'static {
    /// Records durably that `account` signs out; false when it was not recorded.
    fn record(&self, account: String) -> Boxed<'_, bool>;
    /// Leaves only a join signing in made for `account` (none: the accounts recorded).
    fn leave(&self, account: Option<String>) -> Boxed<'_, ()>;
    /// Enrolls this machine for `user`.
    fn enroll(&self, user: String, access: Zeroizing<String>) -> Boxed<'_, EnrollOutcome>;
}

/// The signed-in person the app reports.
pub(crate) struct Change {
    /// Signed in now; None signed out.
    pub user_id: Option<String>,
    /// Who the app last reported before this, if it knew one.
    pub previous: Option<String>,
    /// The access token an enroll mints with; only with `user_id`.
    pub access: Option<Zeroizing<String>>,
}

/// What a change started.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Accepted {
    /// Whether the account signing out was recorded; None when none signs out.
    pub recorded: Option<bool>,
    pub leave: bool,
    pub enroll: bool,
}

#[derive(Default)]
struct State {
    /// Whether a change was seen since this daemon started.
    decided: bool,
    current: Option<String>,
    /// The last change's work: done once it holds true (or its task is gone).
    last: Option<watch::Receiver<bool>>,
}

/// The signed-in person as this daemon follows it, and its changes' work in order.
pub(crate) struct Follow {
    state: Mutex<State>,
    /// Woken on every change: an enroll's retry wait ends.
    changed: Notify,
    retry_wait: Duration,
}

/// This daemon's [`Follow`].
static FOLLOW: OnceLock<Arc<Follow>> = OnceLock::new();

/// Resolves once the work `done` tracks has ended.
async fn ended(done: Option<watch::Receiver<bool>>) {
    if let Some(mut done) = done {
        let _ = done.wait_for(|done| *done).await;
    }
}

impl Follow {
    pub(crate) fn new(retry_wait: Duration) -> Self {
        Self { state: Mutex::new(State::default()), changed: Notify::new(), retry_wait }
    }

    fn is_current(&self, user: &str) -> bool {
        self.state.lock_or_recover().current.as_deref() == Some(user)
    }

    /// Waits for every change so far.
    pub(crate) async fn settled(&self) {
        let last = self.state.lock_or_recover().last.clone();
        ended(last).await;
    }

    /// Takes `change`: records the account signing out now, then queues its leave and enroll on
    /// `scope` after the changes before it.
    pub(crate) async fn change(
        self: &Arc<Self>,
        scope: &cmux_scope::Scope,
        port: Arc<dyn Port>,
        change: Change,
    ) -> Accepted {
        let Change { user_id, previous, access } = change;
        let (leave, leaving, before, done) = {
            let mut state = self.state.lock_or_recover();
            if state.decided && state.current == user_id {
                return Accepted { recorded: None, leave: false, enroll: false };
            }
            let leave = if state.decided { state.current.is_some() } else { user_id.is_none() };
            let leaving = if state.decided {
                state.current.clone()
            } else {
                previous.filter(|previous| Some(previous) != user_id.as_ref())
            };
            state.decided = true;
            state.current = user_id.clone();
            let (done, watching) = watch::channel(false);
            let before = state.last.replace(watching);
            (leave, leaving, before, done)
        };
        // An enroll waiting to retry for the last person stops waiting.
        self.changed.notify_waiters();
        let recorded = match leaving.clone() {
            Some(account) => Some(port.record(account).await),
            None => None,
        };
        let enroll = user_id.is_some() && access.is_some();
        let follow = Arc::clone(self);
        // At most one leave and two enrolls, each bounded by the hub client's deadlines, and one
        // retry wait; ends with them, or with the daemon's scope.
        let _task = scope.spawn_named("machine-signed-in", async move {
            ended(before).await;
            if leave {
                port.leave(leaving).await;
            }
            if let (Some(user), Some(access)) = (user_id, access) {
                follow.enroll(port.as_ref(), user, access).await;
            }
            let _ = done.send(true);
        });
        Accepted { recorded, leave, enroll }
    }

    /// The enroll for `user`, once more after [`RETRY_WAIT`] when the hub did not answer, while
    /// `user` is still signed in.
    async fn enroll(&self, port: &dyn Port, user: String, access: Zeroizing<String>) {
        for attempt in 0..2 {
            if attempt > 0 {
                let changed = self.changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if !self.is_current(&user) {
                    return;
                }
                tokio::select! {
                    () = tokio::time::sleep(self.retry_wait) => {}
                    () = &mut changed => {}
                }
                if !self.is_current(&user) {
                    return;
                }
            }
            let outcome = port.enroll(user.clone(), access.clone()).await;
            tracing::info!(?outcome, "sign-in enroll");
            if outcome != EnrollOutcome::Unavailable {
                return;
            }
        }
    }
}

/// The daemon's join, for one change's hub and build tag.
struct Daemon {
    hub: Arc<Hub>,
    request: EnrollRequest,
}

impl Port for Daemon {
    fn record(&self, account: String) -> Boxed<'_, bool> {
        Box::pin(async move {
            let recorded = crate::cli::cloud_join::record_leave_intent(&account).await;
            if let Err(e) = &recorded {
                tracing::info!("sign-out: the account was not recorded: {e:#}");
            }
            recorded.is_ok()
        })
    }

    fn leave(&self, account: Option<String>) -> Boxed<'_, ()> {
        Box::pin(async move {
            let leave = crate::cli::cloud_join::leave_if_auto(account.as_deref());
            super::machine_enroll::leave_transition(&self.hub, leave).await;
        })
    }

    fn enroll(&self, user: String, access: Zeroizing<String>) -> Boxed<'_, EnrollOutcome> {
        Box::pin(async move {
            let request = EnrollRequest { user_id: Some(user), ..self.request.clone() };
            let enroll = crate::cli::cloud_join::enroll_self(request, access);
            let hub = &self.hub;
            super::machine_enroll::enroll_transition(hub, enroll, || {
                super::machine_enroll::relay_on_disk(hub)
            })
            .await
            .0
        })
    }
}

/// `_acpmux/machine_signed_in`: the app's signed-in person changed (see the module doc).
pub(super) async fn signed_in(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
) -> Result<Value, RpcError> {
    super::machine_enroll::local(conn, crate::rpc::method::MUX_MACHINE_SIGNED_IN)?;
    let text = |key: &str| {
        params.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
    };
    let id = |key: &str| -> Result<Option<String>, RpcError> {
        text(key)
            .map(|value| {
                crate::cli::cloud_join::safe_id(value)
                    .ok_or_else(|| RpcError::invalid_params(&format!("{key} is malformed")))
            })
            .transpose()
    };
    let change = Change {
        user_id: id("userId")?,
        previous: id("previous")?,
        access: text("accessToken").map(|token| Zeroizing::new(token.to_owned())),
    };
    let request = EnrollRequest {
        hub: text("hub").map(str::to_owned),
        user_id: None,
        build_tag: text("buildTag").map(str::to_owned),
    };
    let port = Arc::new(Daemon { hub: Arc::clone(hub), request });
    let follow = FOLLOW.get_or_init(|| Arc::new(Follow::new(RETRY_WAIT)));
    let accepted = follow.change(&hub.scope, port, change).await;
    Ok(json!({
        "accepted": true,
        "recorded": accepted.recorded,
        "leave": accepted.leave,
        "enroll": accepted.enroll,
    }))
}

#[cfg(test)]
#[path = "sign_in_follow_tests.rs"]
mod tests;

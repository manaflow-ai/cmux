//! Who answers an approval question on Windows and Linux
//! (docs/computer-use-approvals.md, "Collectors"): a local protected collector
//! when the machine has a desktop session (polkit, Windows Hello), and the
//! owner's other devices through the device hub ([`RemoteApprover`], which the
//! hub client implements). The first valid answer wins; the others are
//! cancelled by dropping their futures.

use std::sync::Arc;

use async_trait::async_trait;

use crate::approval::{ApprovalRequest, Decision};

/// One collector's answer, bound to the request's digest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApproverDecision {
    pub decision: Decision,
    pub digest: String,
    /// `polkit`, `windows-hello`, `phone`, `mac`, `cli`.
    pub via: String,
}

/// The owner's other devices ([`crate::hub::HubRemote`] over the device hub
/// client): `POST /v1/approvals`, then the decision a different device of the
/// account signed, applied only when signed by an approver the box owner pinned
/// (docs/computer-use-approvals.md, "Device hub approvals").
///
/// `ask` resolves to `None` when no device answers before
/// `request.answerable_until_ms`, the hub is unreachable, or the answer does
/// not verify. It must be cancel safe: the host drops the future when another
/// collector answers first or the worker cancels the question, and the
/// implementation then withdraws the hub request.
#[async_trait]
pub trait RemoteApprover: Send + Sync {
    async fn ask(&self, request: &ApprovalRequest) -> Option<ApproverDecision>;

    /// For status: `phone`, `mac`, or both, when the account has approver devices.
    fn describe(&self) -> Vec<String> {
        Vec::new()
    }
}

/// A protected collector on this machine. `offered` is the decision a person
/// confirms: the automatic prompt offers [`Decision::Session`];
/// `computer_use.approvals.prompt` re-opens it with `once` or `session`, never
/// `always` (any local caller reaches that method; Always is chosen on the
/// phone or Mac). A dismissed prompt answers `deny`; `None` means the
/// collector could not ask (no agent, no Hello) and the others keep waiting.
#[async_trait]
pub trait LocalCollector: Send + Sync {
    fn name(&self) -> &'static str;
    async fn ask(&self, request: &ApprovalRequest, offered: Decision) -> Option<ApproverDecision>;
}

/// The collectors this machine has.
#[derive(Clone, Default)]
pub struct Collectors {
    pub local: Option<Arc<dyn LocalCollector>>,
    pub remote: Option<Arc<dyn RemoteApprover>>,
}

impl Collectors {
    /// The machine's local collector, when it has a desktop session that can show one.
    pub fn detect() -> Self {
        Self { local: local_collector(), remote: None }
    }

    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.local.iter().map(|local| local.name().to_owned()).collect();
        if let Some(remote) = &self.remote {
            let described = remote.describe();
            if described.is_empty() {
                names.push("device-hub".into());
            } else {
                names.extend(described);
            }
        }
        names
    }

    /// Asks every collector at once; the first answer whose digest is the
    /// request's wins. None when every collector gave up.
    pub async fn ask(&self, request: &ApprovalRequest) -> Option<ApproverDecision> {
        use std::future::Future;
        use std::pin::Pin;
        type Asking<'a> = Pin<Box<dyn Future<Output = Option<ApproverDecision>> + Send + 'a>>;
        let mut asking: Vec<Asking<'_>> = Vec::new();
        if let Some(local) = &self.local {
            asking.push(Box::pin(local.ask(request, Decision::Session)));
        }
        if let Some(remote) = &self.remote {
            asking.push(Box::pin(remote.ask(request)));
        }
        first_valid(asking, &request.digest).await
    }
}

/// The first `Some` answer with the right digest among `futures`.
async fn first_valid<F>(futures: Vec<F>, digest: &str) -> Option<ApproverDecision>
where
    F: std::future::Future<Output = Option<ApproverDecision>> + Unpin + Send,
{
    let mut set = futures;
    while !set.is_empty() {
        let (answer, _index, rest) = select_all(set).await;
        if let Some(answer) = answer
            && crate::wire::same_secret(answer.digest.as_bytes(), digest.as_bytes())
        {
            return Some(answer);
        }
        set = rest;
    }
    None
}

/// `futures::future::select_all` without the dependency.
async fn select_all<F>(mut futures: Vec<F>) -> (F::Output, usize, Vec<F>)
where
    F: std::future::Future + Unpin,
{
    std::future::poll_fn(move |context| {
        for index in 0..futures.len() {
            if let std::task::Poll::Ready(output) = std::pin::Pin::new(&mut futures[index]).poll(context) {
                drop(futures.swap_remove(index));
                let rest = std::mem::take(&mut futures);
                return std::task::Poll::Ready((output, index, rest));
            }
        }
        std::task::Poll::Pending
    })
    .await
}

#[cfg(target_os = "linux")]
fn local_collector() -> Option<Arc<dyn LocalCollector>> {
    crate::platform::has_polkit_agent().then(|| Arc::new(crate::collectors::polkit::Polkit) as Arc<dyn LocalCollector>)
}

#[cfg(windows)]
fn local_collector() -> Option<Arc<dyn LocalCollector>> {
    crate::platform::interactive_session()
        .unwrap_or(false)
        .then(|| Arc::new(crate::collectors::hello::WindowsHello) as Arc<dyn LocalCollector>)
}

#[cfg(not(any(target_os = "linux", windows)))]
fn local_collector() -> Option<Arc<dyn LocalCollector>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::approval::{Question, Target};

    struct Fixed(Option<ApproverDecision>, &'static str);

    #[async_trait]
    impl LocalCollector for Fixed {
        fn name(&self) -> &'static str {
            self.1
        }
        async fn ask(&self, _request: &ApprovalRequest, _offered: Decision) -> Option<ApproverDecision> {
            self.0.clone()
        }
    }

    struct Hub(Option<ApproverDecision>);

    #[async_trait]
    impl RemoteApprover for Hub {
        async fn ask(&self, _request: &ApprovalRequest) -> Option<ApproverDecision> {
            self.0.clone()
        }
    }

    fn request() -> ApprovalRequest {
        ApprovalRequest::new(
            Question {
                client: "c".into(),
                machine: "m".into(),
                session: "s".into(),
                agent: "a".into(),
                workspace: "w".into(),
                target: Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() },
                tool: "click".into(),
                risk: "R1".into(),
            },
            1,
        )
        .unwrap()
    }

    #[tokio::test]
    async fn a_wrong_digest_never_wins_and_the_next_answer_does() {
        let request = request();
        let wrong = ApproverDecision { decision: Decision::Always, digest: "0".repeat(64), via: "polkit".into() };
        let right = ApproverDecision { decision: Decision::Once, digest: request.digest.clone(), via: "phone".into() };
        let collectors = Collectors {
            local: Some(Arc::new(Fixed(Some(wrong), "polkit"))),
            remote: Some(Arc::new(Hub(Some(right.clone())))),
        };
        assert_eq!(collectors.ask(&request).await, Some(right));
    }

    #[tokio::test]
    async fn no_collector_is_no_answer() {
        assert_eq!(Collectors::default().ask(&request()).await, None);
        let silent = Collectors { local: Some(Arc::new(Fixed(None, "polkit"))), remote: None };
        assert_eq!(silent.ask(&request()).await, None);
    }
}

//! A carrier session for remote exec (`cmux spill --to cloud`): the same dial
//! `cmux carrier dial` makes (a ticket and grant from cmux-platform with the
//! person's credential, the machine's relay slot, the pinned daemon key), but
//! the caller gets the session's multiplexer instead of its mux control
//! stream, and opens `workspace-rpc` and `process-stream` on it with
//! [`cmux_remote::client::WorkspaceClient`]. An owner's grant carries both
//! (cmux-platform `CARRIER_SERVICES`); a teammate's (`acpmux` only) does not,
//! and the workspace open is refused.

use std::sync::Arc;
use std::time::Duration;

use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::ClientConnection;
use cmux_remote::service::ServiceMultiplexer;
use zeroize::Zeroizing;

use super::{answer, client, contract, noise_key, route_log, ssh};

/// A connected carrier session and the workspace client on it.
pub(crate) struct WorkspaceSession {
    pub client: Arc<WorkspaceClient>,
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
}

impl WorkspaceSession {
    pub(crate) async fn close(self) {
        self.multiplexer.shutdown().await;
        let _ = self.connection.close().await;
    }
}

/// Dials Cloud machine `machine` through the platform at `api` (an origin
/// `secure_cloud_origin` accepts) with the person's `token`, in `team` when
/// the machine is a shared team's. `Err`: the step it did not get past and why.
pub(crate) async fn dial_workspace(
    machine: &str,
    api: &str,
    token: Zeroizing<String>,
    team: Option<String>,
    deadline: Duration,
) -> Result<WorkspaceSession, String> {
    let failed =
        |failure: contract::Failure| format!("{}: {}", failure.step.error_code(), failure.detail);
    let api = crate::cli::secure_cloud_origin(api.trim())?;
    let source = answer::HttpSource::new(api, answer::Credential::Value(token), team)?;
    let identity = noise_key::device_identity()?;
    let connect_log = route_log::default_path();
    let phases_log = connect_log.clone();
    let plan = client::DialPlan {
        machine: machine.to_owned(),
        source: Arc::new(source),
        identity,
        deadline: tokio::time::Instant::now() + deadline,
        prefetched: Arc::new(answer::Prefetched::new(None)),
        log: Arc::new(move |line| {
            if let Some(path) = &connect_log {
                route_log::append(path, &line);
            }
        }),
        phases: Arc::new(move |line| {
            if let Some(path) = &phases_log {
                route_log::append(path, &line);
            }
        }),
        fresh_sessions: contract::FreshSessions::default(),
        progress: None,
        ssh: Arc::new(ssh::SshSetup::from_env(None)),
        ssh_refusal: ssh::SshRefusal::default(),
        drill: false,
    };
    let dialed = client::dial(&plan).await.map_err(failed)?;
    let client::Dialed { connection, multiplexer, mux, .. } = dialed;
    // The dial opened the daemon's mux control stream to prove the session; exec needs none.
    mux.close().await;
    match WorkspaceClient::connect(multiplexer.clone()).await {
        Ok(client) => Ok(WorkspaceSession { client, connection, multiplexer }),
        Err(error) => {
            multiplexer.shutdown().await;
            let _ = connection.close().await;
            Err(format!("workspace: {error}"))
        }
    }
}

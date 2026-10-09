//! Host side of one client connection that touches no OS API (cx-ko2e
//! table A): the launch-owner barrier claim, the active-stream count that
//! wakes the accept loop, the client-setup rollback, client
//! authentication and renderer-capability minting. The connection loop
//! itself (`serve_client*`) follows once its stream calls use `HostStream`.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use super::super::*;
use super::clipboard_read::owner_rights_allowed;
use super::codec::constant_time_equal;
use super::host_shared::HostShared;

pub(crate) struct LaunchOwnerConnection {
    pub(crate) host: Arc<HostShared>,
    pub(crate) claimed: bool,
}

impl LaunchOwnerConnection {
    pub(crate) fn claim(host: Arc<HostShared>, granted_rights: CapabilityRights) -> Self {
        let claimed = granted_rights.contains(CapabilityRights::ADMIN)
            && host
                .launch_owner_claimed
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok();
        Self { host, claimed }
    }

    pub(crate) fn stream_ready(&self) {
        if !self.claimed {
            return;
        }
        self.host.mark_launch_owner_stream_ready();
    }
}

impl Drop for LaunchOwnerConnection {
    fn drop(&mut self) {
        if !self.claimed {
            return;
        }
        // A failed initial stream must release the same launch barrier as
        // a successful one. The launching daemon reports the handshake
        // failure, while the independently hosted process can still
        // publish or clean up its terminal exit.
        self.host.mark_launch_owner_stream_ready();
    }
}

pub(crate) struct ActiveClientStream {
    pub(crate) host: Arc<HostShared>,
}

impl ActiveClientStream {
    pub(crate) fn register(host: Arc<HostShared>) -> Self {
        host.active_client_streams.fetch_add(1, Ordering::AcqRel);
        Self { host }
    }
}

impl Drop for ActiveClientStream {
    fn drop(&mut self) {
        let previous = self.host.active_client_streams.fetch_sub(1, Ordering::AcqRel);
        debug_assert!(previous > 0, "active terminal-host stream underflow");
        if previous == 1 {
            self.host.accept_waker.wake();
        }
    }
}

pub(crate) struct ClientSetupRollback {
    pub(crate) host: Arc<HostShared>,
    pub(crate) client: u64,
    pub(crate) armed: bool,
}

impl ClientSetupRollback {
    pub(crate) fn new(host: Arc<HostShared>, client: u64) -> Self {
        Self { host, client, armed: true }
    }

    pub(crate) fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ClientSetupRollback {
    fn drop(&mut self) {
        if self.armed {
            self.host.remove_client(self.client);
        }
    }
}

pub(crate) fn authenticate_client(
    host: &HostShared,
    hello: &ClientHello,
) -> anyhow::Result<HostHello> {
    if hello.terminal_id != host.terminal_id {
        anyhow::bail!("terminal-host capability denied");
    }
    if constant_time_equal(hello.token.as_bytes(), host.owner_token.as_bytes()) {
        if hello.role != ClientRole::Admin
            || !owner_rights_allowed(hello.requested_rights)
            || hello.min_version > PROTOCOL_VERSION
            || hello.max_version < PROTOCOL_VERSION
        {
            anyhow::bail!("terminal-host owner capability denied");
        }
        return Ok(HostHello {
            selected_version: PROTOCOL_VERSION,
            granted_rights: hello.requested_rights,
            terminal_id: host.terminal_id,
            incarnation: host.incarnation,
        });
    }
    Ok(host.capabilities.accept(hello, PROTOCOL_VERSION..=PROTOCOL_VERSION, host.incarnation)?)
}

pub(crate) fn mint_renderer_capability(
    host: &HostShared,
    payload: &[u8],
) -> anyhow::Result<CapabilityToken> {
    if payload.len() != 8 {
        anyhow::bail!("bad renderer capability request");
    }
    let rights = CapabilityRights::from_bits(u32::from_le_bytes(
        payload[0..4].try_into().expect("fixed rights slice"),
    ))
    .ok_or_else(|| anyhow::anyhow!("unknown renderer capability rights"))?;
    if !rights.contains(CapabilityRights::READ) || !CapabilityRights::RENDERER.contains(rights) {
        anyhow::bail!("renderer capability rights are out of range");
    }
    let ttl_ms = u32::from_le_bytes(payload[4..8].try_into().expect("fixed TTL slice"));
    let ttl = Duration::from_millis(u64::from(ttl_ms));
    if ttl.is_zero() || ttl > MAX_RENDERER_CAPABILITY_TTL {
        anyhow::bail!("renderer capability TTL is out of range");
    }
    Ok(host.capabilities.mint(host.terminal_id, rights, ttl)?)
}

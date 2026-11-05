//! A stream that reaches a Cloud host's link (overlay TCP 4100): the hello
//! must carry a link token that the host's [`TokenVerifier`] accepts for
//! this host, its current epoch, the requested service and the WireGuard
//! key the stream came from (cloud-client-contract.md 1.7). Production remains
//! deny-all until the supervised listener and live authority owner are composed.
//!
//! `daemon` goes to the session's remote entry, stamped with the peer the
//! token names; `ssh` goes to the host's sshd on loopback (scp, sftp and
//! rsync with `cmux link` as ProxyCommand); `desktop` goes to the agent
//! display's `cmux.rd/1` host on its root-only Unix socket
//! ([`DESKTOP_SOCKET`], socket-activated by the image's `cmux-agent-rd.socket`).

use std::net::{IpAddr, SocketAddr};
use std::path::Path;

use cmux_link::dial::{MAX_HELLO_BYTES, Service, ServiceHello};
use cmux_link::overlay_addr::overlay_address;
use cmux_link::stamp::StampCheck;
use cmux_link::stream_lease::StreamLease;
use cmux_link::token::{Expected, TokenRefusal, TokenRefused, TokenVerifier};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt as _};

use super::inbound::{InboundRefused, Spliced, hand_to_entry_traced};
use super::lines::read_line;

/// This host as its link knows it.
pub(super) struct HostIdentity<'a> {
    pub host: &'a str,
    pub epoch: u64,
    pub session_socket: &'a Path,
    /// The host's sshd (127.0.0.1:22 on a Cloud VM).
    pub sshd: SocketAddr,
    /// The desktop host's socket ([`DESKTOP_SOCKET`] on a Cloud VM).
    pub desktop: &'a Path,
}

/// The `desktop` service's socket on a Cloud VM: `cmux-agent-rd.socket`
/// listens here (`SocketUser=root`, `SocketMode=0600`, in a 0700 root
/// directory), so only this root receiver can connect, never the agent.
pub(super) const DESKTOP_SOCKET: &str = "/run/cmux-rd/desktop.sock";

/// Why a host refused a stream (beyond [`InboundRefused`]).
#[derive(Debug, PartialEq, Eq)]
pub(super) enum HostRefused {
    Inbound(InboundRefused),
    /// The hello had no token, or the verifier refused it.
    Token,
    /// The hello names a lower epoch than this host's.
    StaleEpoch,
    /// The stream's source is not the overlay address of the install the
    /// token names.
    AddressMismatch,
    /// The host's sshd did not accept the connection.
    SshUnavailable,
    /// The machine serves no desktop: its socket is missing or refused the
    /// connection (`check: desktop_unavailable` on the refusal line).
    DesktopUnavailable,
    /// The authority owner revoked this stream, vanished, or its lease expired.
    Authority,
}

/// What one stream came to, for the receiver's journal line: the service its
/// hello asked for, the verifier's own reason when it refused the token, and
/// the byte counts once the stream reached the daemon entry or sshd.
#[derive(Debug, Default)]
pub(super) struct StreamTrace {
    pub service: Option<Service>,
    pub token: Option<TokenRefused>,
    /// The verifier's specific failed check (`issuer`, `audience`, ...).
    pub check: Option<TokenRefusal>,
    pub spliced: Option<Spliced>,
    /// The service connect or byte copy began: a refusal line can no longer
    /// be the first bytes the dialer reads.
    pub serving: bool,
}

/// How long a refused stream may spend writing its refusal line.
const REFUSAL_WRITE: std::time::Duration = std::time::Duration::from_secs(1);

/// The refusal line for `why` (`type: "refused"`, the daemon protocol's
/// refusal shape, read by [`super::refusal_watch`]), or `None` once the dialer may already have
/// read service bytes. Reasons and check names only, never a token.
pub(super) fn refusal_line(why: &HostRefused, trace: &StreamTrace) -> Option<String> {
    if trace.serving && matches!(why, HostRefused::Authority) {
        return None;
    }
    let mut line = serde_json::Map::new();
    line.insert("type".into(), "refused".into());
    line.insert("code".into(), super::refusal_watch::REFUSED_CODE.into());
    line.insert("reason".into(), format!("{why:?}").into());
    if matches!(why, HostRefused::DesktopUnavailable) {
        line.insert("check".into(), "desktop_unavailable".into());
    } else if let Some(check) = &trace.check {
        line.insert("check".into(), check.reason.into());
        if let Some(detail) = &check.detail {
            line.insert("detail".into(), detail.as_str().into());
        }
    } else if let Some(token) = trace.token {
        line.insert("check".into(), token.name().into());
    }
    let line = serde_json::Value::Object(line);
    Some(format!("{line}\n"))
}

/// Check the hello of `stream` (from the session with `peer_key`, overlay
/// source `peer_addr`) and serve the service it asks for.
#[cfg(test)]
pub(super) async fn serve_host_inbound<S>(
    stream: S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    verifier: &dyn TokenVerifier,
    me: &HostIdentity<'_>,
) -> Result<(), HostRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    serve_host_inbound_traced(
        stream,
        peer_key,
        peer_addr,
        verifier,
        me,
        &mut StreamTrace::default(),
    )
    .await
}

/// [`serve_host_inbound`], recording in `trace` what the stream came to. A
/// refused stream tells its dialer why in one line before it closes, so the
/// far end reads a reason instead of a bare EOF.
pub(super) async fn serve_host_inbound_traced<S>(
    mut stream: S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    verifier: &dyn TokenVerifier,
    me: &HostIdentity<'_>,
    trace: &mut StreamTrace,
) -> Result<(), HostRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let result = serve_checked(&mut stream, peer_key, peer_addr, verifier, me, trace).await;
    if let Err(why) = &result
        && let Some(line) = refusal_line(why, trace)
    {
        let _ = tokio::time::timeout(REFUSAL_WRITE, async {
            stream.write_all(line.as_bytes()).await?;
            stream.shutdown().await
        })
        .await;
    }
    result
}

async fn serve_checked<S>(
    stream: &mut S,
    peer_key: [u8; 32],
    peer_addr: SocketAddr,
    verifier: &dyn TokenVerifier,
    me: &HostIdentity<'_>,
    trace: &mut StreamTrace,
) -> Result<(), HostRefused>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut handshake = verifier.begin_handshake(me.host, me.epoch, &peer_key).map_err(|why| {
        trace.token = Some(why);
        HostRefused::Token
    })?;
    let read_hello = async {
        let line = read_line(&mut *stream, MAX_HELLO_BYTES)
            .await
            .map_err(|_| HostRefused::Inbound(InboundRefused::BadHello))?;
        ServiceHello::parse(&line).ok_or(HostRefused::Inbound(InboundRefused::BadHello))
    };
    let hello = tokio::select! {
        biased;
        ()=authority_ended(&mut handshake)=>return Err(HostRefused::Authority),
        hello=read_hello=>hello?,
    };
    // Release the pre-auth slot before JWT admission. The verifier atomically
    // rechecks current authority and acquires the authenticated service lease.
    drop(handshake);
    trace.service = Some(hello.service);
    let Some(token) = hello.link_token.as_deref() else {
        trace.token = Some(TokenRefused::Missing);
        return Err(HostRefused::Token);
    };
    // The hello, the token and this host must name the same epoch: a
    // restored or re-bound VM refuses older links, and a stale clone
    // refuses newer ones.
    if hello.epoch != Some(me.epoch) {
        return Err(HostRefused::StaleEpoch);
    }
    let expected =
        Expected { host: me.host, epoch: me.epoch, service: hello.service, peer_key: &peer_key };
    let verified = verifier.verify_explained(token, &expected).map_err(|why| {
        trace.token = Some(why.kind);
        trace.check = Some(why);
        HostRefused::Token
    })?;
    let peer = verified.peer;
    if peer_addr.ip() != IpAddr::V6(overlay_address(&peer.install)) {
        return Err(HostRefused::AddressMismatch);
    }
    let mut lease = verified.lease.ok_or(HostRefused::Authority)?;
    // Authority is checked before the first poll of the connect/handoff and
    // throughout the byte copy. Dropping that future closes both endpoints;
    // an accepted JWT cannot leave an independently authorized tunnel behind.
    trace.serving = true;
    let work = async {
        match hello.service {
            Service::Daemon => {
                // The verifier accepted a control-plane token for this stream:
                // the entry records it as the install's good check.
                hand_to_entry_traced(
                    &mut *stream,
                    &peer,
                    Some(StampCheck::NativeLinkToken {
                        issued_at_ms: verified.issued_at_ms,
                        vm_kind: verified.vm_kind,
                    }),
                    me.session_socket,
                    &mut trace.spliced,
                )
                .await
                .map_err(HostRefused::Inbound)
            }
            Service::Ssh => {
                let mut sshd = tokio::net::TcpStream::connect(me.sshd)
                    .await
                    .map_err(|_| HostRefused::SshUnavailable)?;
                trace.spliced =
                    Some(Spliced::of(tokio::io::copy_bidirectional(&mut *stream, &mut sshd).await));
                Ok(())
            }
            Service::Desktop => {
                let mut desktop = tokio::net::UnixStream::connect(me.desktop)
                    .await
                    .map_err(|_| HostRefused::DesktopUnavailable)?;
                trace.spliced = Some(Spliced::of(
                    tokio::io::copy_bidirectional(&mut *stream, &mut desktop).await,
                ));
                Ok(())
            }
            // A Cloud host has no owner session: its owner reaches it through the
            // token-checked daemon entry.
            Service::OwnerSession => Err(HostRefused::Inbound(InboundRefused::BadHello)),
        }
    };
    tokio::select! {
        biased;
        ()=authority_ended(&mut lease)=>Err(HostRefused::Authority),
        result=work=>result,
    }
}

async fn authority_ended(lease: &mut StreamLease) {
    loop {
        let Some(deadline) = lease.deadline() else { return };
        let elapsed = lease.elapsed_deadline();
        if deadline <= std::time::Instant::now() {
            return;
        }
        tokio::select! {
            biased;
            ()=lease.changed()=>{},
            ()=super::receiver_deadline::expired(deadline, elapsed)=>return,
        }
    }
}

#[cfg(test)]
#[path = "host_inbound_tests.rs"]
mod receiver_tests;

#[cfg(test)]
#[path = "host_native_token_tests.rs"]
mod native_token_tests;

#[cfg(test)]
#[path = "host_stream_lifetime_tests.rs"]
mod stream_lifetime_tests;

#[cfg(test)]
#[path = "host_handshake_lifetime_tests.rs"]
mod handshake_lifetime_tests;

#[cfg(test)]
#[path = "host_elapsed_transport_tests.rs"]
mod elapsed_transport_tests;

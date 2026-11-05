//! A stream that reaches a Cloud host's link (overlay TCP 4100): the hello
//! must carry a link token that the host's [`TokenVerifier`] accepts for
//! this host, its current epoch, the requested service and the WireGuard
//! key the stream came from (cloud-client-contract.md 1.7). Production remains
//! deny-all until the supervised listener and live authority owner are composed.
//!
//! `daemon` goes to the session's remote entry, stamped with the peer the
//! token names; `ssh` goes to the host's sshd on loopback (scp, sftp and
//! rsync with `cmux link` as ProxyCommand).

use std::net::{IpAddr, SocketAddr};
use std::path::Path;

use cmux_link::dial::{MAX_HELLO_BYTES, Service, ServiceHello};
use cmux_link::overlay_addr::overlay_address;
use cmux_link::stamp::StampCheck;
use cmux_link::stream_lease::StreamLease;
use cmux_link::token::{Expected, TokenRefused, TokenVerifier};
use tokio::io::{AsyncRead, AsyncWrite};

use super::inbound::{InboundRefused, Spliced, hand_to_entry_traced};
use super::lines::read_line_within;

/// This host as its link knows it.
pub(super) struct HostIdentity<'a> {
    pub host: &'a str,
    pub epoch: u64,
    pub session_socket: &'a Path,
    /// The host's sshd (127.0.0.1:22 on a Cloud VM).
    pub sshd: SocketAddr,
}

/// How long a dialer has to send its service hello once the stream is open.
/// A Cloud Mac opens the stream first and only then mints the hello's link
/// token, with up to `dial::DIAL_TIMEOUT` (5 s) for that mint, so this must
/// be well past it: at 5 s a slow mint on a busy control plane lost the race
/// and the stream ended "(no hello)" while the Mac was still writing it. The
/// pre-authentication lease still ends a waiting stream when authority does.
pub(super) const HELLO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

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
    pub spliced: Option<Spliced>,
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

/// [`serve_host_inbound`], recording in `trace` what the stream came to.
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
    let mut handshake = verifier.begin_handshake(me.host, me.epoch, &peer_key).map_err(|why| {
        trace.token = Some(why);
        HostRefused::Token
    })?;
    let read_hello = async {
        let line = read_line_within(&mut stream, MAX_HELLO_BYTES, HELLO_TIMEOUT)
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
    let verified = verifier.verify(token, &expected).map_err(|why| {
        trace.token = Some(why);
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
    let work = async {
        match hello.service {
            Service::Daemon => {
                // The verifier accepted a control-plane token for this stream:
                // the entry records it as the install's good check.
                hand_to_entry_traced(
                    stream,
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
                    Some(Spliced::of(tokio::io::copy_bidirectional(&mut stream, &mut sshd).await));
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

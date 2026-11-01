//! Pre-hello connections share bounded policy authority, without spending JWTs.
use super::{
    MAX_STREAMS, NativeTokenVerifier, StreamAuthority, StreamLease, StreamProof, TokenRefused,
    elapsed_deadline, reconcile_streams, stream_deadline, wake_streams,
};

pub(super) fn begin(
    verifier: &NativeTokenVerifier,
    host: &str,
    epoch: u64,
    peer_key: &[u8; 32],
) -> Result<StreamLease, TokenRefused> {
    let (mut state, now) = verifier.current()?;
    let policy = state.policy.as_ref().ok_or(TokenRefused::NoVerifier)?;
    if !policy.valid(now) {
        state.policy = None;
        let wake = reconcile_streams(&mut state, None);
        drop(state);
        wake_streams(wake);
        return Err(TokenRefused::Expired);
    }
    if policy.host != host || policy.epoch != epoch {
        return Err(TokenRefused::Invalid);
    }
    let peer = policy
        .peers
        .iter()
        .find(|peer| peer.binding.key().as_ref() == Some(peer_key))
        .ok_or(TokenRefused::Invalid)?;
    let deadline = stream_deadline(policy, now).ok_or(TokenRefused::Expired)?;
    let elapsed = elapsed_deadline(&state, policy).ok_or(TokenRefused::Expired)?;
    let (lease, control) = StreamLease::with_budget(deadline, elapsed);
    let authority = StreamAuthority {
        issuer: policy.issuer.clone(),
        host: policy.host.clone(),
        epoch: policy.epoch,
        team: policy.team.clone(),
        authority_version: policy.authority_version.clone(),
        peer: peer.clone(),
        proof: StreamProof::Handshake { keys: state.keys.keys.clone() },
        lease: control,
    };
    state.streams.retain(|stream| stream.lease.deadline().is_some());
    if state.streams.len() >= MAX_STREAMS {
        return Err(TokenRefused::Invalid);
    }
    state.streams.push(authority);
    Ok(lease)
}

//! The shared repo actions on local sockets and authenticated Cloud links.
use super::{ClientTransport, MessageWriter, Mux};
use serde_json::{Value, json};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
static WORKERS: AtomicUsize = AtomicUsize::new(0);
const MAX_WORKERS: usize = 16;

pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    line: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    let cmd = crate::cloud_repos::frame_command(line)?;
    let request: Value = serde_json::from_str(line).ok()?;
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let permitted = permitted(mux, client, &cmd, &request);
    if !permitted {
        return Some(writer.send_control(&json!({"id":id,"ok":false,"error_code":"remote_denied","error":"permission denied"})).is_ok());
    }
    if WORKERS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < MAX_WORKERS).then_some(n + 1))
        .is_err()
    {
        return Some(writer.send_control(&json!({"id":id,"ok":true,"data":{"code":"seed.clone_failed","message":"Repository actions are busy. Retry after the current action finishes."}})).is_ok());
    }
    let mux = mux.clone();
    let writer = writer.clone();
    let fallback = writer.clone();
    let fallback_id = id.clone();
    match std::thread::Builder::new().name("cloud-repo".into()).spawn(move || {
        struct Done;
        impl Drop for Done {
            fn drop(&mut self) {
                WORKERS.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _done = Done;
        let result = crate::cloud_repos::handle(&mux, &cmd, &request);
        let _ = writer.send_control(&json!({"id":id,"ok":true,"data":result}));
    }) {
        Ok(_) => Some(true),
        Err(_) => {
            WORKERS.fetch_sub(1, Ordering::AcqRel);
            Some(fallback.send_control(&json!({"id":fallback_id,"ok":false,"error_code":"seed.clone_failed","error":"Retry the repository action; the worker could not start."})).is_ok())
        }
    }
}

/// Local user and linked Mac requests retain their existing access. A
/// presented agent identity, however, may address only its own chat.
fn permitted(mux: &Mux, client: u64, cmd: &str, request: &Value) -> bool {
    let transport = mux.control_clients.transport_of(client);
    if !matches!(transport, Some(ClientTransport::Unix | ClientTransport::Remote))
        || mux.frame_principal(client).is_none()
        || (matches!(cmd, "cloud.repo.local" | "cloud.repo.remember")
            && !matches!(transport, Some(ClientTransport::Unix)))
    {
        return false;
    }
    let credential = match request.get("credential") {
        None => None,
        Some(Value::String(value)) if !value.is_empty() => Some(value.as_str()),
        Some(_) => return false,
    };
    match mux.request_actor(super::origin_gate::connection_actor(mux, client), credential) {
        Ok(crate::Actor::AcpSession { id, .. }) => request["session"].as_str() == Some(id.as_str()),
        Ok(_) => true,
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::{BoundedOutbound, QueuedSink};

    fn client(mux: &Mux, transport: ClientTransport) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        (mux.control_clients.register(transport, writer.clone()), writer, outbound)
    }

    #[test]
    fn cloud_repo_agent_credential_cannot_target_another_chat() {
        let mux = Mux::new_for_test("repo-auth", crate::SurfaceOptions::default());
        let (client, writer, outbound) = client(&mux, ClientTransport::Unix);
        let minted = mux.mint_acp_session_credential("own-chat", None).unwrap();
        let request = json!({"id":1,"cmd":"cloud.repo.add","session":"other-chat",
            "repo":"org/repo","credential":minted["credential"]});
        assert_eq!(try_handle(&mux, client, &request.to_string(), &writer), Some(true));
        let reply: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(reply["error_code"], "remote_denied");
        let own = json!({"session":"own-chat","credential":minted["credential"]});
        assert!(permitted(&mux, client, "cloud.repo.add", &own));
        for credential in [Value::Null, json!(12), json!("forged"), json!("")] {
            assert!(!permitted(
                &mux,
                client,
                "cloud.repo.add",
                &json!({"session":"own-chat","credential":credential})
            ));
        }
        assert!(!permitted(
            &mux,
            client,
            "cloud.repo.sync",
            &json!({"credential":minted["credential"]})
        ));
    }

    #[test]
    fn cloud_repo_local_user_and_authenticated_mac_keep_access() {
        let mux = Mux::new_for_test("repo-auth-routes", crate::SurfaceOptions::default());
        let (local, _, _) = client(&mux, ClientTransport::Unix);
        let request = json!({"session":"any-chat"});
        assert!(permitted(&mux, local, "cloud.repo.add", &request));
        assert!(permitted(&mux, local, "cloud.repo.local", &json!({})));
        let (remote, _, _) = client(&mux, ClientTransport::Remote);
        assert!(!permitted(&mux, remote, "cloud.repo.add", &request));
        let peer = crate::remote_relay_state::LinkPeer {
            install: "repo-mac".into(),
            user: "user".into(),
            team: "team".into(),
        };
        mux.record_remote_check(&peer.install).unwrap();
        mux.bind_remote_peer(remote, &peer).unwrap();
        assert!(permitted(&mux, remote, "cloud.repo.add", &request));
        assert!(permitted(&mux, remote, "cloud.repo.sync", &json!({})));
        assert!(!permitted(&mux, remote, "cloud.repo.local", &json!({})));
        let minted = mux.mint_acp_session_credential("any-chat", None).unwrap();
        assert!(!permitted(
            &mux,
            remote,
            "cloud.repo.add",
            &json!({"session":"any-chat","credential":minted["credential"]})
        ));
        mux.revoke_remote_install(&peer.install).unwrap();
        assert!(!permitted(&mux, remote, "cloud.repo.add", &request));
        let (web, _, _) = client(&mux, ClientTransport::WebSocket);
        assert!(!permitted(&mux, web, "cloud.repo.add", &request));
    }
}

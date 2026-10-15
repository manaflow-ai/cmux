//! `page-credential` (`page-credential-v1`, cx-hnmbt.4): the verified cmux app
//! asks for a credential for its own page. It is a pairing-store credential
//! (the same lifetime and bound as an approved pairing), so a WebSocket
//! connection that presents it is the person's own client and may use the
//! Cloud lease the app set (`ws-cloud-conversations-v1`). The file token next
//! to the socket never is: any same-user process can read that file.

use serde_json::{Value, json};

use super::Mux;

pub const PAGE_CREDENTIAL_CAPABILITY: &str = "page-credential-v1";

pub(super) fn page_credential(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    anyhow::ensure!(
        matches!(super::origin_gate::connection_actor(mux, client), crate::Actor::Frontend { .. }),
        "page-credential requires the verified cmux app connection"
    );
    let (credential, expires_in) = mux.issue_page_credential()?;
    Ok(json!({"credential": credential, "expires_in": expires_in}))
}

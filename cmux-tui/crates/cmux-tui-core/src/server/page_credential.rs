//! `page-credential` (`page-credential-v1`, cx-hnmbt.4): the verified cmux app
//! asks for a credential for its own page. It is a pairing-store credential
//! (the same lifetime and bound as an approved pairing), so a WebSocket
//! connection that presents it is the person's own client and may use the
//! Cloud lease the app set (`ws-cloud-conversations-v1`). The file token next
//! to the socket never is: any same-user process can read that file.
//!
//! `page-credential {page}` (`page-credential-scoped-v1`): a trusted local
//! (Unix) connection asks for a credential bound to one page of the
//! page-router table, for an owner whose app connection is not the verified
//! app (the Chief home's conversation owner). It is single use and lasts 2 min
//! like the person's, but it admits only a WebSocket handshake whose Origin
//! names that page, the connection gets only that page's commands
//! (client_hello.rs `scope_to_page`: its raw commands and its
//! `cmux.protocol/2` allow list), and it is never the person: no Cloud lease.
//! It is narrower than the file token any trusted local process can already
//! read.

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;

pub const PAGE_CREDENTIAL_CAPABILITY: &str = "page-credential-v1";
/// `page-credential {page}`: a credential bound to one page.
pub const SCOPED_PAGE_CREDENTIAL_CAPABILITY: &str = "page-credential-scoped-v1";

/// `page-credential`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PageCredentialParams {
    /// A page id of the page-router table: the credential admits only that
    /// page's Origin and never carries the person's Cloud lease.
    #[serde(default)]
    page: Option<String>,
}

pub(super) fn page_credential(
    mux: &Mux,
    client: u64,
    params: PageCredentialParams,
) -> anyhow::Result<Value> {
    if let Some(page) = params.page {
        anyhow::ensure!(
            mux.control_clients.is_unix(client),
            "page-credential with page requires a trusted local connection"
        );
        anyhow::ensure!(
            crate::request_origin::page_router_table::known_page(&page),
            "bad request: page {page:?} is not in the page-router table"
        );
        let (credential, expires_in) = mux.issue_scoped_page_credential(&page)?;
        return Ok(json!({"credential": credential, "expires_in": expires_in, "page": page}));
    }
    anyhow::ensure!(
        matches!(super::origin_gate::connection_actor(mux, client), crate::Actor::Frontend { .. }),
        "page-credential requires the verified cmux app connection"
    );
    let (credential, expires_in) = mux.issue_page_credential()?;
    Ok(json!({"credential": credential, "expires_in": expires_in}))
}

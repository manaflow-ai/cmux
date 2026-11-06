//! A Cloud machine's live previews on cmux-platform (`/v1/cloud/machines/{machine}/previews/...`),
//! through the generated client: refresh the listener catalog, create and revoke anonymous links.

use serde_json::{Map, Value, json};

use super::{Failure, Request, optional_int, text};

pub(super) async fn run(
    request: &Request,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    super::http::base_url(&request.api).map_err(Failure::Transport)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = cmux_cloud_client::client(
        &request.api,
        &request.credential,
        request.team.as_deref().filter(|t| !t.is_empty()),
        concat!("cmux/", env!("CARGO_PKG_VERSION")),
    )
    .map_err(|e| Failure::Transport(e.to_string()))?;
    let machine = text(args, "machine")?;
    let answer = match call {
        "previews.refresh" => {
            client.cloud_previews_refresh(machine).await.map(|r| json!(r.into_inner()))
        }
        "previews.create_link" => {
            let port = port(args)?;
            let body = cmux_cloud_client::types::CloudPreviewsCreateLinkBody {
                expires_at: positive(args, "expiresAt"),
                max_uses: positive(args, "maxUses"),
            };
            client
                .cloud_previews_create_link(machine, &port, &body)
                .await
                .map(|r| json!(r.into_inner()))
        }
        "previews.revoke_link" => {
            let port = port(args)?;
            let link = text(args, "linkId")?;
            client
                .cloud_previews_revoke_link(machine, &port, link)
                .await
                .map(|r| json!(r.into_inner()))
        }
        other => return Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    };
    match answer {
        Ok(body) => Ok(body),
        Err(error) => {
            let error = cmux_cloud_client::ApiError::from_api(error).await;
            Err(match error.status {
                Some(status) => Failure::http(status, error.code, Some(error.message)),
                None => Failure::Transport(error.message),
            })
        }
    }
}

fn port(args: &Map<String, Value>) -> Result<String, Failure> {
    optional_int(args, "port")
        .map(|p| p.to_string())
        .ok_or_else(|| Failure::Transport("the call needs port".into()))
}

/// A positive whole number field of `args`; absent, zero or negative is none.
fn positive(args: &Map<String, Value>, name: &str) -> Option<std::num::NonZeroU64> {
    args.get(name).and_then(Value::as_u64).and_then(std::num::NonZeroU64::new)
}

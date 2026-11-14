//! A Cloud machine's live previews on cmux-platform (`/v1/cloud/machines/{machine}/previews/...`),
//! through the generated client: refresh the listener catalog, create and revoke anonymous links.

use serde_json::{Map, Value, json};

use super::{Failure, Request, optional_int, text};

/// How long a preview call (refresh, create or revoke a link) may take.
pub(crate) const PREVIEW_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

pub(crate) async fn run(
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
    if !matches!(call, "previews.refresh" | "previews.create_link" | "previews.revoke_link") {
        return Err(Failure::Transport(format!("no cloud api call {call:?}")));
    }
    let port = if call == "previews.refresh" { String::new() } else { port(args)? };
    let link = if call == "previews.revoke_link" { text(args, "linkId")? } else { "" };
    let path = format!("/v1/cloud/machines/{machine}/previews");
    let sent = async {
        match call {
            "previews.refresh" => {
                client.cloud_previews_refresh(machine).await.map(|r| json!(r.into_inner()))
            }
            "previews.create_link" => {
                let body = cmux_cloud_client::types::CloudPreviewsCreateLinkBody {
                    expires_at: positive(args, "expiresAt"),
                    max_uses: positive(args, "maxUses"),
                };
                client
                    .cloud_previews_create_link(machine, &port, &body)
                    .await
                    .map(|r| json!(r.into_inner()))
            }
            _ => client
                .cloud_previews_revoke_link(machine, &port, link)
                .await
                .map(|r| json!(r.into_inner())),
        }
    };
    // One deadline for the whole call, its refusal's body included, not the generated
    // client's longer default.
    let now = tokio::time::Instant::now();
    let deadline = now.checked_add(PREVIEW_TIMEOUT).unwrap_or(now);
    within(deadline, path, sent, |error| async move {
        match error {
            cmux_cloud_client::Error::CommunicationError(error)
                if request.local_only && error.is_connect() =>
            {
                Failure::NoBackend
            }
            error => {
                let error = cmux_cloud_client::ApiError::from_api(error).await;
                match error.status {
                    Some(status) => Failure::http(status, error.code, Some(error.message)),
                    None => Failure::Transport(error.message),
                }
            }
        }
    })
    .await
}

/// `sent`'s answer, its error read by `refusal`, both before `deadline` (else `TimedOut(path)`).
pub(crate) async fn within<E, R>(
    deadline: tokio::time::Instant,
    path: String,
    sent: impl Future<Output = Result<Value, E>>,
    refusal: impl FnOnce(E) -> R,
) -> Result<Value, Failure>
where
    R: Future<Output = Failure>,
{
    let timed_out = || Failure::TimedOut(path.clone());
    match tokio::time::timeout_at(deadline, sent).await {
        Err(_) => Err(timed_out()),
        Ok(Ok(body)) => Ok(body),
        Ok(Err(error)) => match tokio::time::timeout_at(deadline, refusal(error)).await {
            Err(_) => Err(timed_out()),
            Ok(failure) => Err(failure),
        },
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

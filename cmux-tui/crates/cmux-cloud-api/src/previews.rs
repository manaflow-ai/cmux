//! A Cloud machine's live previews on cmux-platform (`/v1/cloud/machines/{machine}/previews/...`),
//! through the generated client: refresh the listener catalog, create and revoke anonymous links,
//! and the publications, their API keys and domains (`vm.domains`, `vm.publications`,
//! `vm.provision_api`, `vm.publication_api_keys`, `vm.revoke_publication_api_key`: the names
//! classic's `/api/vm` calls had, now the platform's `/v1/cloud/...` routes; a publication is one
//! machine port's preview, `vm_…:port`).

use serde_json::{Map, Value, json};

use super::{Failure, Request, optional_int, optional_text, text};

/// How long a preview call (refresh, create or revoke a link) may take.
pub(crate) const PREVIEW_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
/// A key's create may first refresh the machine's previews (a guest inventory and ingress writes).
const PROVISION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

type ClientError = cmux_cloud_client::Error<cmux_cloud_client::ByteStream>;

/// The publication calls ([`publications`]).
pub(crate) const PUBLICATION_CALLS: [&str; 5] = [
    "vm.domains",
    "vm.publications",
    "vm.provision_api",
    "vm.publication_api_keys",
    "vm.revoke_publication_api_key",
];

fn client(request: &Request) -> Result<cmux_cloud_client::Client, Failure> {
    super::http::base_url(&request.api).map_err(Failure::Transport)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_cloud_client::client(
        &request.api,
        &request.credential,
        request.team.as_deref().filter(|t| !t.is_empty()),
        concat!("cmux/", env!("CARGO_PKG_VERSION")),
    )
    .map_err(|e| Failure::Transport(e.to_string()))
}

pub(crate) async fn run(
    request: &Request,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    let client = client(request)?;
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
    answered(request, PREVIEW_TIMEOUT, path, sent).await
}

/// The publication calls: `vm.domains` and `vm.publications` list; `vm.provision_api` (`machine`
/// or `vmId`, `port`, optional `keyName`, `expiresAt`) mints a key; `vm.publication_api_keys` and
/// `vm.revoke_publication_api_key` (`keyId`) name the publication by `machine` and `port`, or by
/// `publication`, its id or hostname, which the caller's publication list resolves.
pub(crate) async fn publications(
    request: &Request,
    call: &str,
    args: &Map<String, Value>,
) -> Result<Value, Failure> {
    let client = client(request)?;
    match call {
        "vm.domains" => {
            let sent =
                async { client.cloud_publications_domains().await.map(|r| json!(r.into_inner())) };
            let list = answered(request, PREVIEW_TIMEOUT, "Cloud domains".into(), sent).await?;
            super::classic::field(list, "domains", "Cloud domains")
        }
        "vm.publications" => listed(request, &client).await,
        "vm.provision_api" => {
            let machine = text(args, "machine").or_else(|_| text(args, "vmId"))?;
            let port = port(args)?;
            let body = cmux_cloud_client::types::CloudPreviewsCreateApiKeyBody {
                name: optional_text(args, "keyName").map(str::to_owned),
                expires_at: optional_text(args, "expiresAt").map(str::to_owned),
            };
            let path = format!("the API keys of {machine}:{port}");
            let sent = async {
                client
                    .cloud_previews_create_api_key(machine, &port, &body)
                    .await
                    .map(|r| json!(r.into_inner()))
            };
            answered(request, PROVISION_TIMEOUT, path, sent).await
        }
        "vm.publication_api_keys" | "vm.revoke_publication_api_key" => {
            let (machine, port) = target(request, &client, args).await?;
            let path = format!("the API keys of {machine}:{port}");
            if call == "vm.publication_api_keys" {
                let sent = async {
                    let keys = client.cloud_previews_api_keys(&machine, &port).await;
                    keys.map(|r| json!(r.into_inner()))
                };
                let list = answered(request, PREVIEW_TIMEOUT, path.clone(), sent).await?;
                return super::classic::field(list, "apiKeys", &path);
            }
            let key = text(args, "keyId")?;
            let sent = async {
                client
                    .cloud_previews_revoke_api_key(&machine, &port, key)
                    .await
                    .map(|r| json!(r.into_inner()))
            };
            let revoked = answered(request, PREVIEW_TIMEOUT, path.clone(), sent).await?;
            super::classic::field(revoked, "apiKey", &path)
        }
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

/// The caller's publications (`GET /v1/cloud/previews`).
async fn listed(request: &Request, client: &cmux_cloud_client::Client) -> Result<Value, Failure> {
    let sent =
        async { client.cloud_publications_publications().await.map(|r| json!(r.into_inner())) };
    let list = answered(request, PREVIEW_TIMEOUT, "Cloud publications".into(), sent).await?;
    super::classic::field(list, "previews", "Cloud publications")
}

/// The machine and port a key call names: `machine` and `port`, or the listed publication whose id
/// or hostname is `publication`.
async fn target(
    request: &Request,
    client: &cmux_cloud_client::Client,
    args: &Map<String, Value>,
) -> Result<(String, String), Failure> {
    if let Some(machine) = optional_text(args, "machine") {
        return Ok((machine.to_owned(), port(args)?));
    }
    let publication = text(args, "publication")?;
    let list = listed(request, client).await?;
    list.as_array()
        .into_iter()
        .flatten()
        .find(|p| {
            [p.get("id"), p.get("hostname")]
                .into_iter()
                .any(|v| v.and_then(Value::as_str) == Some(publication))
        })
        .and_then(|p| {
            Some((p.get("vmId")?.as_str()?.to_owned(), p.get("port")?.as_i64()?.to_string()))
        })
        .ok_or_else(|| {
            Failure::http(
                404,
                Some("cloud.preview.not_found".into()),
                Some(format!("no such publication: {publication}")),
            )
        })
}

/// `sent`'s answer within `limit`, its refusal read as the app's failure (a local stack that is
/// not running is `NoBackend`).
async fn answered(
    request: &Request,
    limit: std::time::Duration,
    path: String,
    sent: impl Future<Output = Result<Value, ClientError>>,
) -> Result<Value, Failure> {
    // One deadline for the whole call, its refusal's body included, not the generated
    // client's longer default.
    let now = tokio::time::Instant::now();
    let deadline = now.checked_add(limit).unwrap_or(now);
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

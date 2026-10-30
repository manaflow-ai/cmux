//! Attachments of cloud conversations through the daemon (`cloud-attachments-v1`,
//! home-messaging.md section 10.1). The Worker's attachment routes need the
//! lease (the intent, the presigned commit and the download URL mint) and
//! answer no cross-origin request, so a page cannot call them: the daemon
//! calls them with the lease and carries the bytes. The upload slot URL, a
//! presigned object URL and a signed download URL are their own credentials
//! (no bearer is sent with them).

use serde_json::{Value, json};

use super::CloudError;
use super::contract::{mutation_data, require_conversation};
use super::service::{CloudConversations, PutBody, RangeReply, TransportError};
use cmux_json::JsonSet as _;

/// Largest ranged read in one call (the local owner's read cap).
pub const MAX_RANGE_BYTES: u64 = 4 * 1024 * 1024;

/// The owner's `value` of an `{ok, value}` route reply (refusals as cloud errors).
fn route_value(reply: super::service::HttpReply) -> Result<Value, CloudError> {
    mutation_data(reply).map(|mut data| data.get_mut("value").map(Value::take).unwrap_or_default())
}

fn unavailable(TransportError(detail): TransportError) -> CloudError {
    CloudError::Unavailable(detail)
}

fn is_loopback(url: &url::Url) -> bool {
    matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
}

/// A URL the owner returned: on the lease's origin when `same_origin`;
/// otherwise `https` and not loopback (a presigned object URL), unless the
/// lease itself is a loopback development Worker.
fn transport_url(raw: &str, api_origin: &str, same_origin: bool) -> Result<url::Url, CloudError> {
    let bad = |why: &str| CloudError::Unavailable(format!("the owner returned {why}"));
    let url = url::Url::parse(raw).map_err(|_| bad("a malformed URL"))?;
    if url.origin().ascii_serialization() == api_origin {
        return Ok(url);
    }
    if same_origin {
        return Err(bad("a URL that is not on the cloud API origin"));
    }
    let api_loopback = url::Url::parse(api_origin).is_ok_and(|api| is_loopback(&api));
    if (url.scheme() == "https" && !is_loopback(&url)) || api_loopback {
        Ok(url)
    } else {
        Err(bad("a URL that is not https"))
    }
}

impl CloudConversations {
    /// `POST /v1/home/attachments/intent`: `{state: "exists", attachment}` or
    /// `{state: "upload", mode, upload_url, headers?, slot, poster_upload?|preview_upload?}`.
    pub fn attachment_intent(
        &self,
        conversation: &str,
        declaration: &Value,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        let mut body = declaration.clone();
        body.set("conversation", json!(conversation));
        route_value(self.post("/v1/home/attachments/intent", &body)?)
    }

    /// `POST /v1/home/attachments/commit` after a presigned PUT: `{state, attachment}`.
    pub fn attachment_commit(&self, conversation: &str, slot: &str) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        route_value(self.post(
            "/v1/home/attachments/commit",
            &json!({"conversation": conversation, "slot": slot}),
        )?)
    }

    /// `POST /v1/home/attachments/url`: a signed GET URL of one variant, on the lease's origin.
    pub fn attachment_url(
        &self,
        conversation: &str,
        hash: &str,
        variant: Option<&str>,
    ) -> Result<String, CloudError> {
        require_conversation(conversation)?;
        let mut body = json!({"conversation": conversation, "hash": hash});
        if let Some(variant) = variant {
            body.set("variant", json!(variant));
        }
        let value = route_value(self.post("/v1/home/attachments/url", &body)?)?;
        let url = value
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| CloudError::Unavailable("a URL reply without a url".into()))?;
        // A signed download URL comes from the Worker itself: its origin must be the lease's.
        transport_url(url, &self.api_origin()?, true)?;
        Ok(url.to_string())
    }

    /// `PUT` a body to a slot URL the owner returned (`same_origin`: a Worker
    /// slot on the lease's origin; else a presigned object URL). A Worker slot
    /// answers `{ok, value}`; an object store answers no JSON (`Null` on 2xx).
    pub fn attachment_put(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: PutBody,
        same_origin: bool,
    ) -> Result<Value, CloudError> {
        transport_url(url, &self.api_origin()?, same_origin)?;
        let reply = self.backend().put(url, headers, body).map_err(unavailable)?;
        if reply.body.get("ok").is_some() {
            return route_value(reply);
        }
        match reply.status {
            200..=299 => Ok(Value::Null),
            status => Err(CloudError::Unavailable(format!("upload answered HTTP {status}"))),
        }
    }

    /// Bytes `offset..offset+length` (at most [`MAX_RANGE_BYTES`]) of a signed URL.
    pub fn attachment_range(
        &self,
        url: &str,
        offset: u64,
        length: u64,
    ) -> Result<RangeReply, CloudError> {
        transport_url(url, &self.api_origin()?, true)?;
        let length = length.clamp(1, MAX_RANGE_BYTES);
        let reply = self.backend().get_range(url, offset, length).map_err(unavailable)?;
        match reply.status {
            200 | 206 => Ok(reply),
            416 => Err(CloudError::Rejected {
                code: "attachment.range".into(),
                message: "range not satisfiable".into(),
                retryable: false,
            }),
            // An expired or re-keyed signature: the caller mints one new URL.
            401 | 403 => Err(CloudError::Rejected {
                code: "attachment.url_expired".into(),
                message: "the download URL is no longer valid".into(),
                retryable: true,
            }),
            404 => Err(CloudError::Rejected {
                code: "attachment.not_found".into(),
                message: "no such attachment".into(),
                retryable: false,
            }),
            status => Err(CloudError::Unavailable(format!("download answered HTTP {status}"))),
        }
    }
}

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
use super::service::{CloudConversations, RangeReply, TransportError};

/// Largest ranged read in one call (the local owner's read cap).
pub const MAX_RANGE_BYTES: u64 = 4 * 1024 * 1024;

/// The owner's `value` of an `{ok, value}` route reply (refusals as cloud errors).
fn route_value(reply: super::service::HttpReply) -> Result<Value, CloudError> {
    mutation_data(reply).map(|mut data| data["value"].take())
}

fn unavailable(TransportError(detail): TransportError) -> CloudError {
    CloudError::Unavailable(detail)
}

/// An `https` URL, or `http` to a loopback host (development Workers).
fn transport_url(raw: &str) -> Result<url::Url, CloudError> {
    let url = url::Url::parse(raw)
        .map_err(|_| CloudError::Unavailable("the owner returned a malformed URL".into()))?;
    let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if url.scheme() == "https" || (url.scheme() == "http" && loopback) {
        Ok(url)
    } else {
        Err(CloudError::Unavailable("the owner returned a URL that is not https".into()))
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
        body["conversation"] = json!(conversation);
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
            body["variant"] = json!(variant);
        }
        let value = route_value(self.post("/v1/home/attachments/url", &body)?)?;
        let url = value
            .get("url")
            .and_then(Value::as_str)
            .ok_or_else(|| CloudError::Unavailable("a URL reply without a url".into()))?;
        let parsed = transport_url(url)?;
        // A signed download URL comes from the Worker itself: its origin must be the lease's.
        if parsed.origin().ascii_serialization() != self.api_origin()? {
            return Err(CloudError::Unavailable(
                "the download URL is not on the cloud API origin".into(),
            ));
        }
        Ok(url.to_string())
    }

    /// `PUT` bytes to a slot URL the owner returned. A Worker slot answers
    /// `{ok, value}`; a presigned object store answers no JSON (`Null` on 2xx).
    pub fn attachment_put(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: Vec<u8>,
    ) -> Result<Value, CloudError> {
        transport_url(url)?;
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
        transport_url(url)?;
        let length = length.clamp(1, MAX_RANGE_BYTES);
        let reply = self.backend().get_range(url, offset, length).map_err(unavailable)?;
        match reply.status {
            200 | 206 => Ok(reply),
            416 => Err(CloudError::Rejected {
                code: "attachment.range".into(),
                message: "range not satisfiable".into(),
                retryable: false,
            }),
            401 | 403 | 404 => Err(CloudError::Rejected {
                code: "attachment.url_expired".into(),
                message: "the download URL is no longer valid".into(),
                retryable: true,
            }),
            status => Err(CloudError::Unavailable(format!("download answered HTTP {status}"))),
        }
    }
}

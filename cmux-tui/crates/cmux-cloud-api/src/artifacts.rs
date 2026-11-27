//! `artifacts.read`: one of the Artifacts page's three reads of cmux-platform's `/v1/artifacts`
//! (`args.route`: `tree`, `history` or `file`), as the person's session (`worker` auth). The
//! macOS app made these GETs from Swift (`ArtifactsPageProvider.platformFetch`); the request, its
//! checks and its 60 s deadline live here.
//!
//! Args: `ref` (at most 256 bytes) and `path` (at most 4096 bytes), neither with a line break;
//! `limit` (history only) 1 to 100. A file read needs a `path`. Each query value is encoded whole
//! (`&`, `=`, `+`, `;` and `#` included), so a path never adds a param.
//!
//! The bearer goes only to the call's API origin ([`super::http::base_url`]: https, or http on
//! loopback, no user, query or fragment); no redirect is followed, nothing is cached and no cookie
//! is kept ([`Http`]).
//!
//! The answer is `{status, content_type, commit, size, body_base64}` for every status (the app
//! reads 401, 403 and 404 itself): `commit` is `X-Artifacts-Commit`, `size` the body's length.
//! A body longer than the route's limit ([`FILE_BODY_LIMIT`] for a file, which the page shows as
//! too large to preview, [`BODY_LIMIT`] else) comes back without `body_base64`, at any length: it
//! is counted, never kept, so it is not a failure. A param the page may not send is a 400
//! `artifacts.invalid_params`, before any request.

use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Map, Value, json};

use super::http::Http;
use super::{Failure, optional_text};

/// The read's deadline, the app's own.
const TIMEOUT: Duration = Duration::from_secs(60);
/// A ref's longest name, in bytes.
const REF_LIMIT: usize = 256;
/// A path's longest, in bytes.
const PATH_LIMIT: usize = 4096;
/// The history page sizes the platform takes.
const LIMIT_RANGE: std::ops::RangeInclusive<i64> = 1..=100;
/// A file body longer than this is not sent back: the page previews at most this much.
pub(crate) const FILE_BODY_LIMIT: usize = 4 * 1024 * 1024;
/// A tree or history body longer than this is not sent back (its base64 stays under the daemon's
/// reply limit).
pub(crate) const BODY_LIMIT: usize = 8 * 1024 * 1024;

/// The route and query `args` name, or the refusal of a param that is not one.
pub(crate) fn query(
    args: &Map<String, Value>,
) -> Result<(&'static str, Vec<(&'static str, String)>), Failure> {
    let invalid = |message: String| {
        Failure::http(400, Some("artifacts.invalid_params".to_owned()), Some(message))
    };
    let text = |name: &'static str, max: usize| -> Result<Option<&str>, Failure> {
        match args.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(text)) if text.len() <= max && !text.chars().any(is_line_break) => {
                Ok(Some(text.as_str()))
            }
            Some(_) => Err(invalid(format!("{name} must be a string of at most {max} bytes"))),
        }
    };
    let reference = text("ref", REF_LIMIT)?;
    let path = text("path", PATH_LIMIT)?.filter(|p| !p.is_empty());
    let route = match optional_text(args, "route") {
        Some("tree") => "tree",
        Some("history") => "history",
        Some("file") => "file",
        _ => return Err(invalid("not an artifacts route".into())),
    };
    let mut query = Vec::new();
    if let Some(reference) = reference {
        query.push(("ref", reference.to_owned()));
    }
    match route {
        "file" => {
            let path = path.ok_or_else(|| invalid("path is required".into()))?;
            query.push(("path", path.to_owned()));
        }
        _ => {
            if let Some(path) = path {
                query.push(("path", path.to_owned()));
            }
        }
    }
    // A tree or file read takes no limit; one sent is ignored, as the page always did.
    match args.get("limit").filter(|_| route == "history") {
        None | Some(Value::Null) => {}
        Some(value) => {
            let limit = value.as_i64().filter(|l| LIMIT_RANGE.contains(l)).ok_or_else(|| {
                invalid(format!(
                    "limit must be an integer from {} to {}",
                    LIMIT_RANGE.start(),
                    LIMIT_RANGE.end()
                ))
            })?;
            query.push(("limit", limit.to_string()));
        }
    }
    Ok((route, query))
}

/// A line break as Swift's `Character.isNewline` reads one.
fn is_line_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `GET /v1/artifacts/{route}` with the checked query; the answer for every status.
pub(crate) async fn read(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let (route, query) = query(args)?;
    let segments = ["v1", "artifacts", route];
    let path = format!("/{}", segments.join("/"));
    let limit = if route == "file" { FILE_BODY_LIMIT } else { BODY_LIMIT };
    let (reply, size) =
        http.send_counted(http.url(&segments, &query), TIMEOUT, &path, limit).await?;
    let mut answer = json!({
        "status": reply.status,
        "content_type": reply.content_type,
        "commit": reply.commit,
        "size": size,
    });
    if size <= limit {
        answer["body_base64"] = json!(BASE64.encode(&reply.body));
    }
    Ok(answer)
}

#[cfg(test)]
#[path = "artifacts_tests.rs"]
mod tests;

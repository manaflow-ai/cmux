//! `GET /attachments/<token>` on the daemon's WebSocket listener
//! (`ws-attachments-v1`): the bytes of one attachment variant through a
//! short-lived download link (`conversation-attachment-link`,
//! conversation_attachment_links.rs), so a browser page shows images and
//! plays video with seeking (one byte range per request, as the cloud
//! owner's signed GET).
//!
//! The request passes the listener's Host/Origin rule first, like a page
//! file. The token is the credential: it names nothing, and every request
//! checks the participant and the record again. Responses never render as
//! a document: raster images are `inline`, everything else `attachment`
//! (the cloud `contentDisposition` rule), with `nosniff` and a sandbox CSP;
//! text types are served as `text/plain`.

use std::io::Write;
use std::net::TcpStream;
use std::time::Duration;

use super::Mux;
use super::page_files::RequestHead;
use crate::conversation_store::attachments::MAX_CHUNK_BYTES;
use crate::conversation_store::attachments::links::{Link, valid_token};

/// The path prefix of download links.
pub(super) const PREFIX: &str = "/attachments/";
/// Longest wait for a slow reader before the response is dropped.
const WRITE_TIMEOUT: Duration = Duration::from_secs(60);

/// Answers one download request and closes the connection.
pub(super) fn serve(
    mut stream: TcpStream,
    head: &RequestHead,
    policy: &cmux_local_auth::ListenerPolicy,
    mux: &Mux,
) {
    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
    let _ = respond(&mut stream, head, policy, mux);
    let _ = stream.flush();
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

fn respond(
    stream: &mut TcpStream,
    head: &RequestHead,
    policy: &cmux_local_auth::ListenerPolicy,
    mux: &Mux,
) -> std::io::Result<()> {
    if policy.check(&head.values("host"), &head.values("origin")).is_err() {
        return stream.write_all(&plain(403, "Forbidden"));
    }
    if head.method != "GET" && head.method != "HEAD" {
        return stream.write_all(&plain(405, "Method Not Allowed"));
    }
    let path = head.target.split(['?', '#']).next().unwrap_or_default();
    let token = path.strip_prefix(PREFIX).unwrap_or_default();
    if !valid_token(token) {
        return stream.write_all(&plain(404, "Not Found"));
    }
    let Ok(Some(link)) = mux.with_conversations(|store| Ok(store.attachment_link_target(token)))
    else {
        return stream.write_all(&plain(404, "Not Found"));
    };
    if link.cloud {
        return respond_cloud(stream, head, mux, &link);
    }
    // A zero-length read checks the participant and the record, and names
    // the variant's type and size.
    let Ok(probe) = mux.with_conversations(|store| store.attachment_link_read(&link, 0, 0)) else {
        return stream.write_all(&plain(404, "Not Found"));
    };
    let total = probe.byte_count;
    let range = match head.values("range").first() {
        None => None,
        Some(value) => match parse_range(value, total) {
            Range::Satisfiable(start, end) => Some((start, end)),
            Range::Ignore => None,
            Range::Unsatisfiable => {
                let mut reply = plain(416, "Range Not Satisfiable");
                // `Content-Range: bytes */<total>` before the blank line.
                let split = reply.windows(4).position(|w| w == b"\r\n\r\n").unwrap_or(0);
                reply.splice(split..split, format!("\r\nContent-Range: bytes */{total}").bytes());
                return stream.write_all(&reply);
            }
        },
    };
    let (start, end) = range.unwrap_or((0, total.saturating_sub(1)));
    let length = if total == 0 { 0 } else { end - start + 1 };
    let mut response = if range.is_some() {
        format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{total}\r\n")
    } else {
        "HTTP/1.1 200 OK\r\n".to_owned()
    };
    response.push_str(&format!(
        "Content-Type: {}\r\nContent-Length: {length}\r\nAccept-Ranges: bytes\r\n\
         Content-Disposition: {}\r\nX-Content-Type-Options: nosniff\r\n\
         Content-Security-Policy: sandbox; default-src 'none'\r\n\
         Cache-Control: private, max-age=600\r\nReferrer-Policy: no-referrer\r\n\
         Cross-Origin-Resource-Policy: cross-origin\r\nConnection: close\r\n\r\n",
        served_content_type(&probe.mime_type),
        content_disposition(&probe.mime_type, &link),
    ));
    stream.write_all(response.as_bytes())?;
    if head.method == "HEAD" || length == 0 {
        return Ok(());
    }
    let mut offset = start;
    while offset <= end {
        let want = usize::try_from(end - offset + 1).unwrap_or(usize::MAX).min(MAX_CHUNK_BYTES);
        // Each slice takes the store lock alone, so a long download never
        // holds other conversation work behind it.
        let Ok(slice) =
            mux.with_conversations(|store| store.attachment_link_read(&link, offset, want))
        else {
            return Ok(());
        };
        if slice.data.is_empty() {
            return Ok(());
        }
        stream.write_all(&slice.data)?;
        offset += slice.data.len() as u64;
    }
    Ok(())
}

/// A cloud conversation's attachment through the owner's signed URL, with
/// the lease the app set (the link's minter was the person's own client).
fn respond_cloud(
    stream: &mut TcpStream,
    head: &RequestHead,
    mux: &Mux,
    link: &Link,
) -> std::io::Result<()> {
    // The app's lease, of the same person the link was made for.
    let Some(service) = mux.cloud_conversations().filter(|service| {
        service.app_holds_lease()
            && super::cloud_attachments::lease_identity(service)
                .is_ok_and(|lease| lease == link.lease)
    }) else {
        return stream.write_all(&plain(404, "Not Found"));
    };
    let read = |offset: u64, length: u64| {
        super::cloud_attachments::cloud_range(
            mux,
            service,
            &link.conversation,
            &link.hash,
            link.piece,
            offset,
            length,
        )
    };
    // One byte names the size and the type.
    let Ok(probe) = read(0, 1) else { return stream.write_all(&plain(404, "Not Found")) };
    let Some(total) = probe.total else { return stream.write_all(&plain(502, "Bad Gateway")) };
    let content_type = probe.content_type.unwrap_or_else(|| "application/octet-stream".into());
    let mut mime = content_type.split(';').next().unwrap_or("").trim().to_string();
    // Only a type on the allow list keeps its name (text types come back as
    // text/plain); anything else downloads as bytes.
    if cmux_conversation::attachment_class(&mime).is_none() && mime != "text/plain" {
        mime = "application/octet-stream".into();
    }
    let range = match head.values("range").first() {
        None => None,
        Some(value) => match parse_range(value, total) {
            Range::Satisfiable(start, end) => Some((start, end)),
            Range::Ignore => None,
            Range::Unsatisfiable => {
                let mut reply = plain(416, "Range Not Satisfiable");
                let split = reply.windows(4).position(|w| w == b"\r\n\r\n").unwrap_or(0);
                reply.splice(split..split, format!("\r\nContent-Range: bytes */{total}").bytes());
                return stream.write_all(&reply);
            }
        },
    };
    let (start, end) = range.unwrap_or((0, total.saturating_sub(1)));
    let length = if total == 0 { 0 } else { end - start + 1 };
    let mut response = if range.is_some() {
        format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {start}-{end}/{total}\r\n")
    } else {
        "HTTP/1.1 200 OK\r\n".to_owned()
    };
    response.push_str(&format!(
        "Content-Type: {}\r\nContent-Length: {length}\r\nAccept-Ranges: bytes\r\n\
         Content-Disposition: {}\r\nX-Content-Type-Options: nosniff\r\n\
         Content-Security-Policy: sandbox; default-src 'none'\r\n\
         Cache-Control: private, max-age=600\r\nReferrer-Policy: no-referrer\r\n\
         Cross-Origin-Resource-Policy: cross-origin\r\nConnection: close\r\n\r\n",
        served_content_type(&mime),
        content_disposition(&mime, link),
    ));
    stream.write_all(response.as_bytes())?;
    if head.method == "HEAD" || length == 0 {
        return Ok(());
    }
    let mut offset = start;
    while offset <= end {
        let want = (end - offset + 1).min(MAX_CHUNK_BYTES as u64);
        let Ok(slice) = read(offset, want) else { return Ok(()) };
        if slice.body.is_empty() {
            return Ok(());
        }
        let take = slice.body.len().min(usize::try_from(want).unwrap_or(usize::MAX));
        stream.write_all(slice.body.get(..take).unwrap_or_default())?;
        offset += take as u64;
    }
    Ok(())
}

enum Range {
    Satisfiable(u64, u64),
    /// Not a single byte range: answer the whole body (RFC 9110 lets a
    /// server ignore a range it does not serve).
    Ignore,
    Unsatisfiable,
}

/// One `bytes=` range: `a-b`, `a-` or `-n`, clamped to `total`.
fn parse_range(value: &str, total: u64) -> Range {
    let Some(spec) = value.trim().strip_prefix("bytes=") else { return Range::Ignore };
    if spec.contains(',') {
        return Range::Ignore;
    }
    let Some((first, last)) = spec.trim().split_once('-') else { return Range::Ignore };
    let number = |text: &str| -> Option<u64> {
        (!text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()))
            .then(|| text.parse().ok())
            .flatten()
    };
    match (first.trim(), last.trim()) {
        ("", suffix) => match number(suffix) {
            Some(0) => Range::Unsatisfiable,
            Some(n) if total > 0 => Range::Satisfiable(total.saturating_sub(n), total - 1),
            Some(_) => Range::Unsatisfiable,
            None => Range::Ignore,
        },
        (from, "") => match number(from) {
            Some(start) if start < total => Range::Satisfiable(start, total - 1),
            Some(_) => Range::Unsatisfiable,
            None => Range::Ignore,
        },
        (from, to) => match (number(from), number(to)) {
            (Some(start), Some(end)) if start <= end && start < total => {
                Range::Satisfiable(start, end.min(total - 1))
            }
            (Some(start), Some(end)) if start <= end => Range::Unsatisfiable,
            _ => Range::Ignore,
        },
    }
}

/// Text types download as `text/plain` (the cloud `servedContentType`).
fn served_content_type(mime: &str) -> String {
    if mime.starts_with("text/") || mime == "application/json" {
        "text/plain; charset=utf-8".to_owned()
    } else {
        mime.to_owned()
    }
}

/// Raster images inline, everything else as a download (the cloud
/// `contentDisposition`), with a header-safe ASCII name and the UTF-8 name.
fn content_disposition(mime: &str, link: &Link) -> String {
    let inline = matches!(
        cmux_conversation::attachment_class(mime),
        Some(cmux_conversation::AttachmentClass::Image)
    ) || link.piece != crate::conversation_store::attachments::Piece::Original;
    let kind = if inline { "inline" } else { "attachment" };
    let name = link.name.as_deref().unwrap_or("attachment");
    let ascii: String = name
        .chars()
        .map(|c| if (' '..='~').contains(&c) && c != '"' && c != '\\' { c } else { '_' })
        .collect();
    let encoded: String = name
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect();
    format!("{kind}; filename=\"{ascii}\"; filename*=UTF-8''{encoded}")
}

fn plain(status: u16, reason: &str) -> Vec<u8> {
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\n\
         Content-Length: {}\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n{reason}",
        reason.len()
    )
    .into_bytes()
}

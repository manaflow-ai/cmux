//! `net.fetch` on CDP engines (HOST-FETCH path 2; the spike ruled out
//! `Network.loadNetworkResource`): a `fetch()` in the host world of the
//! tab's main frame, which agent code cannot reach or patch. The engine
//! sends the tab's cookies per `credentials`, follows redirects (each hop
//! passes the session's request filter) and stores Set-Cookie in its jar.
//! The body is read in the page and pulled in chunks.

use super::driver::Inner;
use crate::protocol::{DriverError, timeout_of};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// Runs the request; keeps the body in the host world under an id.
const START: &str = "async (req) => { \
    const store = globalThis.__cmuxFetch || (globalThis.__cmuxFetch = new Map()); \
    const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), req.timeoutMs); \
    try { \
      const headers = new Headers(); for (const [k, v] of req.headers || []) headers.append(k, v); \
      let body; if (req.bodyBase64) { const bin = atob(req.bodyBase64); body = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) body[i] = bin.charCodeAt(i); } \
      const r = await fetch(req.url, { method: req.method || 'GET', headers, body, credentials: req.credentials || 'include', redirect: 'follow', signal: ctl.signal }); \
      const chunks = []; let size = 0; const reader = r.body ? r.body.getReader() : null; \
      if (reader) for (;;) { const { done, value } = await reader.read(); if (done) break; size += value.length; \
        if (size > req.maxBytes) { ctl.abort(); throw new Error('the response body is larger than 64 MiB; download it in a tab'); } chunks.push(value); } \
      const all = new Uint8Array(size); let at = 0; for (const c of chunks) { all.set(c, at); at += c.length; } \
      const id = crypto.randomUUID(); store.set(id, all); \
      return { id, size, url: r.url, status: r.status, statusText: r.statusText, redirected: r.redirected, headers: [...r.headers] }; \
    } finally { clearTimeout(timer); } }";

/// One base64 chunk of a stored body (a multiple of 3 bytes, so chunks
/// concatenate into one base64 text).
const CHUNK: &str = "(id, start, length) => { const b = globalThis.__cmuxFetch.get(id); \
    const part = b.subarray(start, start + length); let s = ''; \
    for (let i = 0; i < part.length; i += 0x8000) s += String.fromCharCode.apply(null, part.subarray(i, i + 0x8000)); \
    return btoa(s); }";

const DROP: &str =
    "(id) => { globalThis.__cmuxFetch && globalThis.__cmuxFetch.delete(id); return true; }";

/// Bytes per pulled chunk: 1 MiB rounded down to a multiple of 3.
const CHUNK_BYTES: u64 = 1_048_575;

/// The default and the longest a fetch may take.
const DEFAULT_FETCH_TIMEOUT_MS: u64 = 30_000;

impl Inner {
    pub(super) fn net_fetch(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let timeout_ms =
            params.get("timeoutMs").and_then(Value::as_u64).unwrap_or(DEFAULT_FETCH_TIMEOUT_MS);
        let max_bytes = params.get("maxBytes").and_then(Value::as_u64).unwrap_or(u64::MAX);
        let request = json!({
            "url": params.get("url").cloned().unwrap_or(Value::Null),
            "method": params.get("method").cloned().unwrap_or(json!("GET")),
            "headers": params.get("headers").cloned().unwrap_or(json!([])),
            "bodyBase64": params.get("bodyBase64").cloned().unwrap_or(Value::Null),
            "credentials": params.get("credentials").cloned().unwrap_or(json!("include")),
            "maxBytes": max_bytes,
            "timeoutMs": timeout_ms,
        });
        let host = |source: &str, args: Value| {
            self.evaluate(&json!({
                "targetId": session.target_id, "world": "host", "source": source, "args": args,
                "awaitPromise": true, "timeoutMs": timeout_ms + 5_000,
            }))
        };
        let head = host(START, json!([request]))
            .map_err(|error| DriverError::new(error.code, format!("fetch: {}", error.message)))?;
        let id = head["id"].as_str().unwrap_or("").to_owned();
        let size = head["size"].as_u64().unwrap_or(0);
        let mut body = String::new();
        let mut pulled = Ok(());
        let mut start = 0;
        while start < size {
            match host(CHUNK, json!([id, start, CHUNK_BYTES])) {
                Ok(chunk) => body.push_str(chunk.as_str().unwrap_or("")),
                Err(error) => {
                    pulled = Err(error);
                    break;
                }
            }
            start += CHUNK_BYTES;
        }
        let _ = host(DROP, json!([id]));
        pulled?;
        let url = head["url"].as_str().unwrap_or("").to_owned();
        // The address the final response came from (the gate's DNS
        // rebinding check); the Network event may trail the body a little.
        let deadline = Instant::now() + Duration::from_secs(1).min(timeout_of(params));
        let remote_ip = self
            .wait_for(&session.target_id, deadline, "the response's address", |tab| {
                tab.responses
                    .iter()
                    .rev()
                    .find(|(seen, _)| *seen == url)
                    .map(|(_, ip)| Ok(ip.clone()))
            })
            .ok();
        let mut result = json!({
            "url": url,
            "status": head["status"],
            "statusText": head["statusText"],
            "redirected": head["redirected"],
            "headers": head["headers"],
            "bodyBase64": body,
        });
        if let Some(ip) = remote_ip.filter(|ip| !ip.is_empty()) {
            result["remoteIPAddress"] = json!(ip);
        }
        Ok(result)
    }
}

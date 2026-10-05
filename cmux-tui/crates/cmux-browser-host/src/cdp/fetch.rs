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

/// The path of a fetch shell document (answered by the host, never sent).
const SHELL_PATH: &str = "/.well-known/cmux-fetch-shell";

/// The default and the longest a fetch may take.
const DEFAULT_FETCH_TIMEOUT_MS: u64 = 30_000;

impl Inner {
    /// A fetch with no tab (a lazy page) runs in a background shell tab: a
    /// document at the fetch URL's origin that the host answers locally
    /// (no request reaches the server), so the fetch has a real origin and
    /// first-party cookies. The tab closes after the fetch.
    pub(super) fn net_fetch(&self, params: &Value) -> Result<Value, DriverError> {
        if params.get("targetId").is_some_and(Value::is_string) {
            return self.net_fetch_in_tab(params);
        }
        let url = url::Url::parse(params.get("url").and_then(Value::as_str).unwrap_or(""))
            .ok()
            .filter(|url| matches!(url.scheme(), "http" | "https"))
            .ok_or_else(|| DriverError::invalid("fetch: url: expected an http or https URL"))?;
        let shell = format!("{}{SHELL_PATH}", url.origin().ascii_serialization());
        let opened = self.tabs_open(&json!({"url": "about:blank", "background": true}))?;
        let target = opened["targetId"].as_str().unwrap_or("").to_owned();
        self.cors
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .add_shell(&target, &shell);
        let navigated = self
            .navigate(&json!({"targetId": target, "url": shell, "waitUntil": "domcontentloaded"}));
        let result = navigated.and_then(|_| {
            let mut params = params.clone();
            params["targetId"] = json!(target);
            self.net_fetch_in_tab(&params)
        });
        self.cors.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove_shell(&target);
        let _ = self.tabs_close(&json!({"targetId": target}));
        result
    }

    /// One host fetch with its HOST-FETCH-CORS token: issued before, revoked
    /// with the fetch on every path; the relaxations go to the gate's log.
    fn net_fetch_in_tab(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let token = super::cors::fresh_token();
        let url = params.get("url").and_then(Value::as_str).unwrap_or("");
        let method = params.get("method").and_then(Value::as_str).unwrap_or("GET");
        let names: Vec<String> = params
            .get("headers")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|pair| pair.get(0).and_then(Value::as_str).map(str::to_owned))
            .collect();
        let started = {
            let mut cors = self.cors.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let was = cors.active();
            cors.issue(token.clone(), &session.target_id, url, method, &names);
            !was
        };
        if started {
            self.refresh_interception();
        }
        let result = self.fetch_with_token(&session, params, &token);
        let (relaxed, ended) = {
            let mut cors = self.cors.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            cors.revoke(&token);
            (cors.take_log(&token), !cors.active())
        };
        if ended {
            self.refresh_interception();
        }
        let mut value = result?;
        if !relaxed.is_empty() {
            value["corsRelaxed"] = Value::Array(
                relaxed.into_iter().map(|r| json!({"url": r.url, "what": r.what})).collect(),
            );
        }
        Ok(value)
    }

    fn fetch_with_token(
        &self,
        session: &super::driver::Session,
        params: &Value,
        token: &str,
    ) -> Result<Value, DriverError> {
        let timeout_ms =
            params.get("timeoutMs").and_then(Value::as_u64).unwrap_or(DEFAULT_FETCH_TIMEOUT_MS);
        let max_bytes = params.get("maxBytes").and_then(Value::as_u64).unwrap_or(u64::MAX);
        // The token goes as a header; the request worker removes it.
        let mut headers = params.get("headers").cloned().unwrap_or(json!([]));
        if let Some(list) = headers.as_array_mut() {
            list.push(json!([super::cors::TOKEN_HEADER, token]));
        }
        let request = json!({
            "url": params.get("url").cloned().unwrap_or(Value::Null),
            "method": params.get("method").cloned().unwrap_or(json!("GET")),
            "headers": headers,
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

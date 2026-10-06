//! `net.fetch` on CDP engines (HOST-FETCH path 2; the spike ruled out
//! `Network.loadNetworkResource`): a `fetch()` in the host world of the
//! tab's main frame, which agent code cannot reach or patch. The engine
//! sends the tab's cookies per `credentials`, follows redirects (each hop
//! passes the session's request filter) and stores Set-Cookie in its jar.
//! The body is read in the page and pulled in chunks.
//!
//! A fetch with no tab runs in a fetch shell (a9 shell-tab conditions,
//! 2026-10-04): (a) its document is empty, `Cache-Control: no-store`, with
//! the CSP `default-src 'none'; connect-src http: https:; base-uri 'none';
//! form-action 'none'` (cors.rs); (b) its service workers are bypassed
//! before its navigation; (c) it is hidden: not listed, no events, no page
//! agent, every session call refused; (d) it closes on every exit path and
//! the session's end, and counts under the gate's 16 fetches per session;
//! (e) a signed-in profile refuses it (gate). The CSP probe (headless
//! Chromium 143.0.7499.4, Testbox): an isolated world takes the main
//! world's CSP, so `default-src 'none'` alone failed the host world's
//! same-origin fetch ("Failed to fetch"); with `connect-src http: https:`
//! (or `*`) it succeeded. `sandbox` is not used: it makes the origin opaque.

use super::driver::{INTERNAL_TIMEOUT, Inner};
use crate::protocol::{DriverError, timeout_of};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::PoisonError;
use std::time::{Duration, Instant};

/// Runs the request; keeps the body in the host world under an id.
const START: &str = "async (req) => { \
    const store = globalThis.__cmuxFetch || (globalThis.__cmuxFetch = new Map()); \
    const ctls = globalThis.__cmuxFetchCtl || (globalThis.__cmuxFetchCtl = new Map()); \
    const ctl = new AbortController(); if (req.fetchId) ctls.set(req.fetchId, ctl); \
    const timer = req.timeoutMs > 0 ? setTimeout(() => ctl.abort(new Error('fetch: timed out')), req.timeoutMs) : 0; \
    let idle = 0; const touch = () => { if (!(req.idleTimeoutMs > 0)) return; clearTimeout(idle); \
      idle = setTimeout(() => ctl.abort(new Error('fetch: no data arrived for ' + req.idleTimeoutMs + ' ms')), req.idleTimeoutMs); }; \
    touch(); \
    try { \
      const headers = new Headers(); for (const [k, v] of req.headers || []) headers.append(k, v); \
      let body; if (req.bodyBase64) { const bin = atob(req.bodyBase64); body = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) body[i] = bin.charCodeAt(i); } \
      const r = await fetch(req.url, { method: req.method || 'GET', headers, body, credentials: req.credentials || 'include', redirect: req.redirect || 'follow', signal: ctl.signal }); \
      touch(); const chunks = []; let size = 0; const reader = r.body ? r.body.getReader() : null; \
      if (reader) for (;;) { const { done, value } = await reader.read(); if (done) break; touch(); size += value.length; \
        if (size > req.maxBytes) { ctl.abort(); throw new Error('the response body is larger than 64 MiB; download it in a tab'); } chunks.push(value); } \
      const all = new Uint8Array(size); let at = 0; for (const c of chunks) { all.set(c, at); at += c.length; } \
      const id = crypto.randomUUID(); store.set(id, all); \
      return { id, size, type: r.type, url: r.url, status: r.status, statusText: r.statusText, redirected: r.redirected, headers: [...r.headers] }; \
    } finally { clearTimeout(timer); clearTimeout(idle); if (req.fetchId) ctls.delete(req.fetchId); } }";

/// Aborts one running fetch of this world (a cancel from the host).
const ABORT: &str = "(id) => { /* cmux-fetch-cancel */ \
    const c = globalThis.__cmuxFetchCtl && globalThis.__cmuxFetchCtl.get(id); \
    if (c) c.abort(new Error('fetch: cancelled')); return !!c; }";

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

/// The URL a fetch shell is created with: a fresh token after it, so the
/// target is known as a shell at its attach (a page cannot guess one).
const SHELL_MARKER: &str = "about:blank#cmux-shell-";

/// Fetch shells that are open, and whether the session ended (a9 shell-tab
/// condition d: a shell closes on every exit path).
#[derive(Debug, Default)]
pub(crate) struct Shells {
    live: HashSet<String>,
    ended: bool,
    /// Running fetches by the gate's `fetchId` (cancels).
    runs: super::fetch_runs::Runs,
}

/// A running fetch's entry: removed when the fetch returns.
struct RunEntry<'a> {
    inner: &'a Inner,
    id: String,
}

impl Drop for RunEntry<'_> {
    fn drop(&mut self) {
        self.inner.shells.lock().unwrap_or_else(PoisonError::into_inner).runs.finish(&self.id);
    }
}

fn cancelled() -> DriverError {
    DriverError::closed("fetch: cancelled")
}

/// An open fetch shell: closed when dropped (success, error, timeout,
/// unwinding), unless the session's end closed it first.
struct ShellTab<'a> {
    inner: &'a Inner,
    target: String,
    marker: String,
    /// Kept for the fetch's next hops to its origin; `net.fetch.done`,
    /// a cancel or the session's end closes it.
    kept: bool,
}

impl Drop for ShellTab<'_> {
    fn drop(&mut self) {
        let inner = self.inner;
        inner.lock().shell_markers.remove(&self.marker);
        inner.cors.lock().unwrap_or_else(PoisonError::into_inner).remove_shell(&self.target);
        if self.kept {
            return;
        }
        if inner.shells.lock().unwrap_or_else(PoisonError::into_inner).live.remove(&self.target) {
            inner.close_target(&self.target);
        }
    }
}

impl Inner {
    /// A fetch with no tab (a lazy page) runs in a background shell tab: a
    /// document at the fetch URL's origin that the host answers locally
    /// (no request reaches the server), so the fetch has a real origin and
    /// first-party cookies. The shell is hidden from the session and closes
    /// after the fetch.
    pub(super) fn net_fetch(&self, params: &Value) -> Result<Value, DriverError> {
        // The gate's id for this fetch, so it can be cancelled (a cancel
        // that came first fails it at once).
        let run = match params.get("fetchId").and_then(Value::as_str) {
            Some(id) => {
                let started = self
                    .shells
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .runs
                    .start(id, Instant::now());
                if !started {
                    return Err(cancelled());
                }
                Some(RunEntry { inner: self, id: id.to_owned() })
            }
            None => None,
        };
        let run_id = run.as_ref().map(|entry| entry.id.as_str());
        if let Some(target) = params.get("targetId").and_then(Value::as_str) {
            self.run_in(run_id, target)?;
            return self.net_fetch_in_tab(params, run_id);
        }
        let url = url::Url::parse(params.get("url").and_then(Value::as_str).unwrap_or(""))
            .ok()
            .filter(|url| matches!(url.scheme(), "http" | "https"))
            .ok_or_else(|| DriverError::invalid("fetch: url: expected an http or https URL"))?;
        let origin = url.origin().ascii_serialization();
        let shell_url = format!("{origin}{SHELL_PATH}");
        // One shell per origin within one fetch: a redirect hop back to an
        // origin reuses its shell.
        let reused = run_id.and_then(|id| {
            let shells = self.shells.lock().unwrap_or_else(PoisonError::into_inner);
            shells.runs.kept_shell(id, &origin).filter(|target| shells.live.contains(target))
        });
        let mut opened = None;
        let target = match reused {
            Some(target) => target,
            None => {
                let deadline = Instant::now() + timeout_of(params);
                let mut shell = self.open_shell(&shell_url, deadline)?;
                self.run_in(run_id, &shell.target)?;
                let left =
                    deadline.saturating_duration_since(Instant::now()).as_millis().max(1) as u64;
                self.navigate(&json!({"targetId": shell.target, "url": shell_url,
                    "waitUntil": "domcontentloaded", "timeoutMs": left}))?;
                if let Some(id) = run_id {
                    let mut shells = self.shells.lock().unwrap_or_else(PoisonError::into_inner);
                    shells.runs.keep_shell(id, &origin, &shell.target);
                    shell.kept = true;
                }
                let target = shell.target.clone();
                opened = Some(shell);
                target
            }
        };
        self.run_in(run_id, &target)?;
        let mut params = params.clone();
        params["targetId"] = json!(target);
        let result = self.net_fetch_in_tab(&params, run_id);
        drop(opened);
        result
    }

    /// `net.fetch.done {fetchId}`: the gate finished a fetch (every hop);
    /// the shells it kept close.
    pub(super) fn net_fetch_done(&self, params: &Value) -> Result<Value, DriverError> {
        let id = crate::protocol::required_str(params, "fetchId")?;
        let closing: Vec<String> = {
            let mut shells = self.shells.lock().unwrap_or_else(PoisonError::into_inner);
            let kept = shells.runs.done(id);
            kept.into_iter().filter(|target| shells.live.remove(target)).collect()
        };
        for target in closing {
            self.close_target(&target);
        }
        Ok(Value::Null)
    }

    /// Records the tab a fetch runs in; fails when it was cancelled.
    fn run_in(&self, run: Option<&str>, target: &str) -> Result<(), DriverError> {
        let Some(id) = run else { return Ok(()) };
        let cancelled_now =
            self.shells.lock().unwrap_or_else(PoisonError::into_inner).runs.set_target(id, target);
        if cancelled_now { Err(cancelled()) } else { Ok(()) }
    }

    fn run_cancelled(&self, run: Option<&str>) -> bool {
        run.is_some_and(|id| {
            self.shells.lock().unwrap_or_else(PoisonError::into_inner).runs.is_cancelled(id)
        })
    }

    /// `net.fetch.cancel {fetchId}`: the gate cancels a running fetch (its
    /// cell timed out, or the session ended). A shell fetch closes its shell
    /// (the detached session fails the pending call at once); an in-tab
    /// fetch is aborted in the host world.
    pub(super) fn net_fetch_cancel(&self, params: &Value) -> Result<Value, DriverError> {
        let id = crate::protocol::required_str(params, "fetchId")?;
        let (target, shell) = {
            let mut shells = self.shells.lock().unwrap_or_else(PoisonError::into_inner);
            let target = shells.runs.cancel(id, Instant::now());
            let shell = target.as_ref().is_some_and(|t| shells.live.remove(t));
            (target, shell)
        };
        match target {
            Some(target) if shell => self.close_target(&target),
            Some(target) => {
                let _ = self
                    .evaluate(&json!({"targetId": target, "world": "host", "source": ABORT,
                    "args": [id], "timeoutMs": INTERNAL_TIMEOUT.as_millis() as u64}));
            }
            None => {}
        }
        Ok(Value::Null)
    }

    /// Creates a hidden shell tab, set up and ready to navigate: its service
    /// workers are bypassed before its first navigation (condition b).
    fn open_shell(&self, shell_url: &str, deadline: Instant) -> Result<ShellTab<'_>, DriverError> {
        if self.shells.lock().unwrap_or_else(PoisonError::into_inner).ended {
            return Err(DriverError::closed("fetch: the session ended"));
        }
        let marker = format!("{SHELL_MARKER}{}", super::cors::fresh_token());
        self.lock().shell_markers.insert(marker.clone());
        let created = self.conn.call(
            None,
            "Target.createTarget",
            json!({"url": marker, "background": true}),
            INTERNAL_TIMEOUT,
        );
        let target = match created {
            Ok(reply) => reply.get("targetId").and_then(Value::as_str).map(str::to_owned),
            Err(error) => {
                self.lock().shell_markers.remove(&marker);
                return Err(error);
            }
        }
        .ok_or_else(|| DriverError::invalid("Target.createTarget returned no targetId"))?;
        {
            let mut state = self.lock();
            state.shell_targets.insert(target.clone());
            if let Some(tab) = state.tabs.get_mut(&target) {
                tab.hidden = true;
            }
        }
        let ended = {
            let mut shells = self.shells.lock().unwrap_or_else(PoisonError::into_inner);
            shells.live.insert(target.clone());
            shells.ended
        };
        // From here every exit closes the tab.
        let shell = ShellTab { inner: self, target, marker, kept: false };
        if ended {
            return Err(DriverError::closed("fetch: the session ended"));
        }
        self.cors
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .add_shell(&shell.target, shell_url);
        let left = deadline.saturating_duration_since(Instant::now()).as_millis().max(1) as u64;
        let session = self.session(&json!({"targetId": shell.target, "timeoutMs": left}))?;
        self.send(&session, "Network.setBypassServiceWorker", json!({"bypass": true}))?;
        Ok(shell)
    }

    /// The session ends: its open shells close now (a fetch in one fails)
    /// and no new one opens.
    pub(super) fn end_shells(&self) {
        let live: Vec<String> = {
            let mut shells = self.shells.lock().unwrap_or_else(PoisonError::into_inner);
            shells.ended = true;
            shells.live.drain().collect()
        };
        for target in live {
            self.close_target(&target);
        }
    }

    fn close_target(&self, target: &str) {
        let _ = self.conn.call(
            None,
            "Target.closeTarget",
            json!({"targetId": target}),
            INTERNAL_TIMEOUT,
        );
    }

    /// A shell is the host's own tab: the session cannot name it (or a
    /// dialog in it); it reads as gone.
    pub(super) fn shell_refusal(&self, params: &Value) -> Result<(), DriverError> {
        let state = self.lock();
        if let Some(target) = params.get("targetId").and_then(Value::as_str)
            && state.is_hidden(target)
        {
            return Err(DriverError::not_found(format!("No tab {target}")));
        }
        if let Some(dialog) = params.get("dialogId").and_then(Value::as_str)
            && state.dialogs.get(dialog).is_some_and(|(owner, _)| state.is_hidden(owner))
        {
            return Err(DriverError::not_found(format!("Dialog {dialog} is gone")));
        }
        Ok(())
    }

    /// One host fetch with its HOST-FETCH-CORS token: issued before, revoked
    /// with the fetch on every path; the relaxations go to the gate's log.
    fn net_fetch_in_tab(&self, params: &Value, run: Option<&str>) -> Result<Value, DriverError> {
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
            let mut cors = self.cors.lock().unwrap_or_else(PoisonError::into_inner);
            let was = cors.active();
            cors.issue(token.clone(), &session.target_id, url, method, &names);
            !was
        };
        if started {
            self.refresh_interception();
        }
        let result = self.fetch_with_token(&session, params, &token, run);
        let (relaxed, ended) = {
            let mut cors = self.cors.lock().unwrap_or_else(PoisonError::into_inner);
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
        run: Option<&str>,
    ) -> Result<Value, DriverError> {
        // 0: no total limit (the gate's default, as classic); the idle limit
        // still applies.
        let timeout_ms =
            params.get("timeoutMs").and_then(Value::as_u64).unwrap_or(DEFAULT_FETCH_TIMEOUT_MS);
        let call_timeout_ms = if timeout_ms == 0 { 0 } else { timeout_ms + 5_000 };
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
            "idleTimeoutMs": params.get("idleTimeoutMs").cloned().unwrap_or(json!(0)),
            "fetchId": run,
            "redirect": params.get("redirect").cloned().unwrap_or(json!("follow")),
        });
        let host = |source: &str, args: Value| {
            self.evaluate(&json!({
                "targetId": session.target_id, "world": "host", "source": source, "args": args,
                "awaitPromise": true, "timeoutMs": call_timeout_ms,
            }))
        };
        let head = host(START, json!([request]))
            .map_err(|error| DriverError::new(error.code, format!("fetch: {}", error.message)))?;
        // `redirect: "manual"`: the host follows the redirect itself; its
        // status and Location were read at the response stage.
        if head["type"] == "opaqueredirect" {
            let (status, location) = self
                .cors
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take_redirect(token)
                .ok_or_else(|| DriverError::invalid("fetch: a redirect without a Location"))?;
            let url = params.get("url").and_then(Value::as_str).unwrap_or("").to_owned();
            let mut result = json!({"url": url, "status": status, "statusText": "",
                "redirected": false, "headers": [], "bodyBase64": "",
                "redirect": {"status": status, "location": location}});
            if let Some(ip) = self.response_address(session, &url, params) {
                result["remoteIPAddress"] = json!(ip);
            }
            return Ok(result);
        }
        let id = head["id"].as_str().unwrap_or("").to_owned();
        let size = head["size"].as_u64().unwrap_or(0);
        let mut body = String::new();
        let mut pulled = Ok(());
        let mut start = 0;
        while start < size {
            if self.run_cancelled(run) {
                pulled = Err(cancelled());
                break;
            }
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
        let remote_ip = self.response_address(session, &url, params);
        let mut result = json!({
            "url": url,
            "status": head["status"],
            "statusText": head["statusText"],
            "redirected": head["redirected"],
            "headers": head["headers"],
            "bodyBase64": body,
        });
        if let Some(ip) = remote_ip {
            result["remoteIPAddress"] = json!(ip);
        }
        Ok(result)
    }

    /// The address a response for `url` came from (the gate's DNS
    /// rebinding check); the Network event may trail the body a little.
    fn response_address(
        &self,
        session: &super::driver::Session,
        url: &str,
        params: &Value,
    ) -> Option<String> {
        let deadline = Instant::now() + Duration::from_secs(1).min(timeout_of(params));
        self.wait_for(&session.target_id, deadline, "the response's address", |tab| {
            tab.responses.iter().rev().find(|(seen, _)| *seen == url).map(|(_, ip)| Ok(ip.clone()))
        })
        .ok()
        .filter(|ip| !ip.is_empty())
    }
}

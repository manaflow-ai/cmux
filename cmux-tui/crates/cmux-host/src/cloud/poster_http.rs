//! The Cloud agent's HTTPS transport: [`Http`] over cmux-server's poster.
//! Moved out of `role.rs` as it was; the worker and its threads each hold one.

use cmux_server::cloud_http::{JsonPoster, RawRequest, RequestDeadline, Response};
use serde_json::Value;

use super::client::Http;

/// [`Http`] over cmux-server's HTTPS poster.
pub struct PosterHttp(pub JsonPoster);

impl PosterHttp {
    /// Runs `send` on this poster and `url`. Tests: while [`TEST_ORIGIN`] is
    /// set, every request goes to its path at that plain-HTTP origin instead,
    /// on a poster of the calling thread (the before/after harness).
    fn via<T>(&self, url: &str, send: impl FnOnce(&JsonPoster, &str) -> T) -> T {
        #[cfg(test)]
        let send = match test_route(url, send) {
            Ok(answer) => return answer,
            Err(send) => send,
        };
        send(&self.0, url)
    }
}

/// [`PosterHttp::via`] while [`TEST_ORIGIN`] is set; `Err(send)` otherwise.
#[cfg(test)]
fn test_route<T, F: FnOnce(&JsonPoster, &str) -> T>(url: &str, send: F) -> Result<T, F> {
    let Some(origin) =
        TEST_ORIGIN.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    else {
        return Err(send);
    };
    thread_local! {
        static POSTER: Option<JsonPoster> = JsonPoster::allowing_http().ok();
    }
    let path = url
        .split_once("://")
        .and_then(|(_, rest)| rest.find('/').map(|at| rest.split_at(at).1))
        .unwrap_or("/");
    let routed = format!("{origin}{path}");
    POSTER.with(|poster| match poster {
        Some(poster) => Ok(send(poster, &routed)),
        None => Err(send),
    })
}

/// Tests: the origin every Cloud request goes to ([`PosterHttp::via`]).
#[cfg(test)]
pub(crate) static TEST_ORIGIN: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

impl Http for PosterHttp {
    fn get(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.via(url, |poster, url| poster.get(url, bearer))
    }

    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.via(url, |poster, url| poster.post(url, body, bearer))
    }

    fn post_empty(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.via(url, |poster, url| poster.post_empty(url, bearer))
    }

    fn send(
        &self,
        method: &str,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        headers: &[(&str, &str)],
    ) -> Result<(u16, Value), String> {
        self.via(url, |poster, url| poster.send_with_headers(method, url, body, bearer, headers))
    }

    fn request_with_deadline(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        self.via(url, |poster, url| poster.request_with_deadline(url, body, bearer, deadline))
    }

    fn request_with_headers(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<Response, String> {
        self.via(url, |poster, url| {
            poster.request_with_deadline_headers(url, body, bearer, deadline)
        })
    }

    fn raw(&self, request: &RawRequest<'_>) -> Result<Response, String> {
        self.via(request.url, |poster, url| poster.request_raw(&RawRequest { url, ..*request }))
    }

    fn reset(&self) {
        self.0.reset();
        #[cfg(test)]
        let _ = test_route("/", |poster, _| poster.reset());
    }

    fn fresh(&self) -> Option<Self> {
        self.0.twin().ok().map(PosterHttp)
    }
}

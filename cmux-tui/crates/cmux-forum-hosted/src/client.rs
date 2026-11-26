//! `ForumClient`: one team's calls to `/v1/forum/*` over a [`Transport`].

use std::fmt;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde::de::DeserializeOwned;
use url::form_urlencoded;

use crate::auth::{Clock, Credential, SystemClock, TokenCache};
use crate::model::{
    ApiErrorBody, Comment, FeedPage, SearchHit, SearchResult, Space, Thread, TokenGrant,
};
use crate::transport::{Method, Request, Response, Transport, TransportError};
use crate::{HOST_TEAM_HEADER, REPORTED_HOST_HEADER, SESSION_HEADER, TEAM_HEADER};

const BASE: &str = "/v1/forum";
/// Threads per page of [`ForumClient::threads`].
pub const THREADS_PER_PAGE: u32 = 50;
const COMMENTS_PER_PAGE: usize = 100;
/// At most this many comment pages per [`ForumClient::comments`] call.
const MAX_COMMENT_PAGES: u32 = 50;

/// A call that did not succeed. Branch on the variant; messages are the server's, for display.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ForumError {
    /// 404 `forum.not_found`: the forum is off on this server or for this team.
    NotEnabled { message: String },
    /// 401: the credential is missing, invalid or expired.
    Unauthorized { code: String, message: String },
    /// 403: no forum access (`forum.forbidden`, `team.not_member`, `auth.sso_required`, `client.too_old`).
    Forbidden { code: String, message: String },
    /// 404 from the store: no such thread or space.
    NotFound { message: String },
    /// 400: the request was refused as invalid.
    Invalid { code: String, message: String },
    /// 409: a conflict; on the feed, a cursor past the newest event.
    Conflict { message: String },
    /// 410: on the feed, a cursor older than the log. Reload the list and restart from its head.
    Gone { message: String },
    /// 5xx: the forum could not be reached; retry.
    Unavailable { status: u16, message: String },
    /// Any other status.
    Api { status: u16, code: String, message: String },
    /// No HTTP answer.
    Transport(String),
    /// A 2xx whose body did not parse.
    Decode(String),
}

impl fmt::Display for ForumError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ForumError::NotEnabled { message } => write!(f, "forum not enabled: {message}"),
            ForumError::Unauthorized { code, message } => {
                write!(f, "unauthorized ({code}): {message}")
            }
            ForumError::Forbidden { code, message } => write!(f, "forbidden ({code}): {message}"),
            ForumError::NotFound { message } => write!(f, "not found: {message}"),
            ForumError::Invalid { code, message } => write!(f, "invalid ({code}): {message}"),
            ForumError::Conflict { message } => write!(f, "conflict: {message}"),
            ForumError::Gone { message } => write!(f, "gone: {message}"),
            ForumError::Unavailable { status, message } => {
                write!(f, "unavailable ({status}): {message}")
            }
            ForumError::Api { status, code, message } => {
                write!(f, "forum error {status} ({code}): {message}")
            }
            ForumError::Transport(m) => write!(f, "transport: {m}"),
            ForumError::Decode(m) => write!(f, "decode: {m}"),
        }
    }
}

impl std::error::Error for ForumError {}

impl From<TransportError> for ForumError {
    fn from(e: TransportError) -> Self {
        ForumError::Transport(e.message)
    }
}

impl ForumError {
    /// Maps a non-2xx response to its error.
    pub fn from_response(response: &Response) -> Self {
        let body: ApiErrorBody = serde_json::from_slice(&response.body).unwrap_or_default();
        let code = body.code.unwrap_or_default();
        let message = body.message.or(body.error).unwrap_or_default();
        match response.status {
            400 => ForumError::Invalid { code, message },
            401 => ForumError::Unauthorized { code, message },
            403 => ForumError::Forbidden { code, message },
            404 if code == "forum.not_found" => ForumError::NotEnabled { message },
            404 => ForumError::NotFound { message },
            409 => ForumError::Conflict { message },
            410 => ForumError::Gone { message },
            status @ 500..=599 => ForumError::Unavailable { status, message },
            status => ForumError::Api { status, code, message },
        }
    }
}

/// Which threads a list shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum StateFilter {
    #[default]
    Open,
    Closed,
    All,
}

impl StateFilter {
    fn as_str(self) -> &'static str {
        match self {
            StateFilter::Open => "open",
            StateFilter::Closed => "closed",
            StateFilter::All => "all",
        }
    }
}

/// One `GET /feed` answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FeedResponse {
    /// 304: nothing after the cursor since the etag sent.
    NotModified,
    Page {
        page: FeedPage,
        etag: Option<String>,
    },
}

/// A client for one team's forum.
pub struct ForumClient<T> {
    transport: T,
    team: String,
    host_team: Option<String>,
    reported: Option<(String, String)>,
    credential: Mutex<Credential>,
    tokens: TokenCache,
    clock: Arc<dyn Clock>,
}

impl<T> fmt::Debug for ForumClient<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let credential = self.credential.lock().unwrap_or_else(|e| e.into_inner()).clone();
        f.debug_struct("ForumClient")
            .field("team", &self.team)
            .field("host_team", &self.host_team)
            .field("credential", &credential)
            .field("tokens", &self.tokens)
            .finish_non_exhaustive()
    }
}

impl<T: Transport> ForumClient<T> {
    pub fn new(transport: T, team: impl Into<String>, credential: Credential) -> Self {
        Self {
            transport,
            team: team.into(),
            host_team: None,
            reported: None,
            credential: Mutex::new(credential),
            tokens: TokenCache::default(),
            clock: Arc::new(SystemClock),
        }
    }

    pub fn with_clock(mut self, clock: Arc<dyn Clock>) -> Self {
        self.clock = clock;
        self
    }

    /// Act in another team's space shared with this one.
    pub fn with_host_team(mut self, host_team: impl Into<String>) -> Self {
        self.host_team = Some(host_team.into());
        self
    }

    /// The agent's session and host, shown next to its posts (display only).
    pub fn with_reported(mut self, session: impl Into<String>, host: impl Into<String>) -> Self {
        self.reported = Some((session.into(), host.into()));
        self
    }

    pub fn team(&self) -> &str {
        &self.team
    }

    /// Swaps the credential (a refreshed session token); drops any exchanged token.
    pub fn set_credential(&self, credential: Credential) {
        *self.credential.lock().unwrap_or_else(|e| e.into_inner()) = credential;
        self.tokens.clear();
    }

    pub async fn spaces(&self) -> Result<Vec<Space>, ForumError> {
        self.get_json(&path("/spaces", &[])).await
    }

    /// One page (1-based) of threads, most recently updated first.
    pub async fn threads(
        &self,
        space: Option<&str>,
        state: StateFilter,
        page: u32,
    ) -> Result<Vec<Thread>, ForumError> {
        let page = page.max(1).to_string();
        let per_page = THREADS_PER_PAGE.to_string();
        let mut q = vec![
            ("state", state.as_str()),
            ("sort", "updated"),
            ("direction", "desc"),
            ("per_page", per_page.as_str()),
            ("page", page.as_str()),
        ];
        if let Some(space) = space {
            q.push(("space", space));
        }
        self.get_json(&path("/threads", &q)).await
    }

    pub async fn thread(&self, number: u64) -> Result<Thread, ForumError> {
        self.get_json(&path(&format!("/threads/{number}"), &[])).await
    }

    /// Every comment on a thread, oldest first.
    pub async fn comments(&self, number: u64) -> Result<Vec<Comment>, ForumError> {
        let per_page = COMMENTS_PER_PAGE.to_string();
        let mut all = Vec::new();
        for page in 1..=MAX_COMMENT_PAGES {
            let page = page.to_string();
            let q = [("per_page", per_page.as_str()), ("page", page.as_str())];
            let batch: Vec<Comment> =
                self.get_json(&path(&format!("/threads/{number}/comments"), &q)).await?;
            let done = batch.len() < COMMENTS_PER_PAGE;
            all.extend(batch);
            if done {
                break;
            }
        }
        Ok(all)
    }

    pub async fn post_thread(
        &self,
        space: &str,
        title: &str,
        body: &str,
        labels: &[String],
    ) -> Result<Thread, ForumError> {
        #[derive(Serialize)]
        struct New<'a> {
            space: &'a str,
            title: &'a str,
            body: &'a str,
            labels: &'a [String],
        }
        self.write_json(Method::Post, &path("/threads", &[]), &New { space, title, body, labels })
            .await
    }

    pub async fn reply(&self, number: u64, body: &str) -> Result<Comment, ForumError> {
        #[derive(Serialize)]
        struct Reply<'a> {
            body: &'a str,
        }
        self.write_json(
            Method::Post,
            &path(&format!("/threads/{number}/comments"), &[]),
            &Reply { body },
        )
        .await
    }

    pub async fn close(&self, number: u64) -> Result<Thread, ForumError> {
        self.write_json(
            Method::Post,
            &path(&format!("/threads/{number}/close"), &[]),
            &serde_json::json!({}),
        )
        .await
    }

    pub async fn search(&self, q: &str, space: Option<&str>) -> Result<Vec<SearchHit>, ForumError> {
        let mut query = vec![("q", q)];
        if let Some(space) = space {
            query.push(("space", space));
        }
        let result: SearchResult = self.get_json(&path("/search", &query)).await?;
        Ok(result.hits)
    }

    /// One feed page after `after`. With `if_none_match`, a 304 is [`FeedResponse::NotModified`].
    pub async fn feed(
        &self,
        after: u64,
        space: Option<&str>,
        limit: u32,
        if_none_match: Option<&str>,
    ) -> Result<FeedResponse, ForumError> {
        let after = after.to_string();
        let limit = limit.to_string();
        let mut q = vec![("after", after.as_str()), ("limit", limit.as_str())];
        if let Some(space) = space {
            q.push(("space", space));
        }
        let extra: Vec<(String, String)> = if_none_match
            .map(|e| vec![("if-none-match".to_owned(), e.to_owned())])
            .unwrap_or_default();
        let resp = self.call(Method::Get, &path("/feed", &q), None, &extra).await?;
        if resp.status == 304 {
            return Ok(FeedResponse::NotModified);
        }
        let etag = resp.header("etag").map(str::to_owned);
        let page = decode(&resp)?;
        Ok(FeedResponse::Page { page, etag })
    }

    async fn get_json<R: DeserializeOwned>(&self, path_and_query: &str) -> Result<R, ForumError> {
        let resp = self.call(Method::Get, path_and_query, None, &[]).await?;
        decode(&resp)
    }

    async fn write_json<B: Serialize, R: DeserializeOwned>(
        &self,
        method: Method,
        path_and_query: &str,
        body: &B,
    ) -> Result<R, ForumError> {
        let body = serde_json::to_vec(body).map_err(|e| ForumError::Decode(e.to_string()))?;
        let resp = self.call(method, path_and_query, Some(body), &[]).await?;
        decode(&resp)
    }

    /// Sends with the bearer; an agent key's token refused with 401 is exchanged again once.
    async fn call(
        &self,
        method: Method,
        path_and_query: &str,
        body: Option<Vec<u8>>,
        extra: &[(String, String)],
    ) -> Result<Response, ForumError> {
        let (bearer, exchanged) = self.bearer().await?;
        let request = self.request(method, path_and_query, body.clone(), extra, &bearer);
        let resp = self.transport.send(request).await?;
        if resp.status == 401 && exchanged {
            self.tokens.clear();
            let (bearer, _) = self.bearer().await?;
            let request = self.request(method, path_and_query, body, extra, &bearer);
            return self.check(self.transport.send(request).await?);
        }
        self.check(resp)
    }

    fn check(&self, resp: Response) -> Result<Response, ForumError> {
        if (200..300).contains(&resp.status) || resp.status == 304 {
            Ok(resp)
        } else {
            Err(ForumError::from_response(&resp))
        }
    }

    fn request(
        &self,
        method: Method,
        path_and_query: &str,
        body: Option<Vec<u8>>,
        extra: &[(String, String)],
        bearer: &str,
    ) -> Request {
        let mut headers = vec![
            ("accept".to_owned(), "application/json".to_owned()),
            ("authorization".to_owned(), format!("Bearer {bearer}")),
            (TEAM_HEADER.to_owned(), self.team.clone()),
        ];
        if let Some(host) = &self.host_team {
            headers.push((HOST_TEAM_HEADER.to_owned(), host.clone()));
        }
        if let Some((session, host)) = &self.reported {
            headers.push((SESSION_HEADER.to_owned(), session.clone()));
            headers.push((REPORTED_HOST_HEADER.to_owned(), host.clone()));
        }
        if body.is_some() {
            headers.push(("content-type".to_owned(), "application/json".to_owned()));
        }
        headers.extend(extra.iter().cloned());
        Request { method, path_and_query: path_and_query.to_owned(), headers, body }
    }

    /// The bearer to send, and whether it came from an agent-key exchange.
    async fn bearer(&self) -> Result<(String, bool), ForumError> {
        let credential = self.credential.lock().unwrap_or_else(|e| e.into_inner()).clone();
        match credential {
            Credential::Session { access_token } => Ok((access_token, false)),
            Credential::AgentKey { key } => {
                let now = self.clock.now_unix();
                if let Some(token) = self.tokens.get(now) {
                    return Ok((token, true));
                }
                let grant = self.exchange(&key).await?;
                self.tokens.put(grant.token.clone(), now, grant.expires_in);
                Ok((grant.token, true))
            }
        }
    }

    async fn exchange(&self, key: &str) -> Result<TokenGrant, ForumError> {
        // No host header: a key's token is for its own team.
        let request = Request {
            method: Method::Post,
            path_and_query: path("/token", &[]),
            headers: vec![
                ("accept".to_owned(), "application/json".to_owned()),
                ("authorization".to_owned(), format!("Bearer {key}")),
                (TEAM_HEADER.to_owned(), self.team.clone()),
            ],
            body: None,
        };
        let resp = self.check(self.transport.send(request).await?)?;
        let grant: TokenGrant = decode(&resp)?;
        if grant.token.is_empty() {
            return Err(ForumError::Decode("token exchange returned no token".to_owned()));
        }
        Ok(grant)
    }
}

fn path(route: &str, query: &[(&str, &str)]) -> String {
    if query.is_empty() {
        return format!("{BASE}{route}");
    }
    let q = form_urlencoded::Serializer::new(String::new()).extend_pairs(query).finish();
    format!("{BASE}{route}?{q}")
}

fn decode<R: DeserializeOwned>(resp: &Response) -> Result<R, ForumError> {
    serde_json::from_slice(&resp.body).map_err(|e| ForumError::Decode(e.to_string()))
}

//! OpenRouter OAuth exchanges the loopback callback for a normal provider key.
//! The code, verifier and returned key stay in the daemon.

use std::sync::Arc;
use std::time::Duration;

use reqwest::{Client, Url};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::{Attempt, Begun, Failure, Service, SignIn, Status, blocking, now};
use crate::chatgpt::oauth::{challenge, random_token, read_target, respond};

const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_CONNECTIONS: usize = 16;

struct Callback {
    listener: TcpListener,
    url: Url,
    path: Arc<str>,
    verifier: Zeroizing<String>,
}

impl Callback {
    async fn start(origin: &str) -> Result<Self, Failure> {
        let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|_| "network")?;
        let address = listener.local_addr().map_err(|_| "network")?;
        let state = random_token(32).map_err(|_| "internal")?;
        let path: Arc<str> = format!("/callback/{state}").into();
        let verifier = Zeroizing::new(random_token(32).map_err(|_| "internal")?);
        let mut url = Url::parse(&format!("{origin}/auth")).map_err(|_| "internal")?;
        url.query_pairs_mut()
            .append_pair("callback_url", &format!("http://{address}{path}"))
            .append_pair("code_challenge", &challenge(&verifier))
            .append_pair("code_challenge_method", "S256")
            .append_pair("key_label", "cmux");
        Ok(Self { listener, url, path, verifier })
    }

    async fn exchange(self, client: &Client, origin: &str) -> Result<Zeroizing<String>, Failure> {
        let mut connections = JoinSet::new();
        let code = loop {
            tokio::select! {
                connection = connections.join_next(), if !connections.is_empty() => {
                    if let Some(Ok(Some(code))) = connection {
                        break code?;
                    }
                }
                accepted = self.listener.accept(), if connections.len() < MAX_CONNECTIONS => {
                    let (stream, _) = accepted.map_err(|_| "network")?;
                    let path = self.path.clone();
                    connections.spawn(async move {
                        tokio::time::timeout(REQUEST_TIMEOUT, callback_code(stream, &path))
                            .await
                            .ok()
                            .flatten()
                    });
                }
            }
        };
        drop(connections);
        drop(self.listener);
        exchange_key(client, origin, &code, &self.verifier).await
    }
}

async fn callback_code(
    mut stream: TcpStream,
    path: &str,
) -> Option<Result<Zeroizing<String>, Failure>> {
    let target = read_target(&mut stream).await?;
    let (request_path, _) = target.split_once('?').unwrap_or((&target, ""));
    if request_path != path {
        let _ = respond(&mut stream, "404 Not Found", "Not found.").await;
        return None;
    }
    let url = Url::parse(&format!("http://127.0.0.1{target}")).ok()?;
    let mut codes = url.query_pairs().filter(|(name, _)| name == "code");
    let code = codes.next().map(|(_, code)| Zeroizing::new(code.into_owned()));
    let result = match code {
        Some(code) if codes.next().is_none() && crate::agent_credentials::token_shaped(&code) => {
            Ok(code)
        }
        _ => Err("bad_code"),
    };
    let _ = respond(&mut stream, "200 OK", "Return to cmux to finish connecting.").await;
    Some(result)
}

async fn exchange_key(
    client: &Client,
    origin: &str,
    code: &str,
    verifier: &str,
) -> Result<Zeroizing<String>, Failure> {
    #[derive(serde::Deserialize)]
    struct Reply {
        key: String,
    }

    let response = client
        .post(format!("{origin}/api/v1/auth/keys"))
        .json(&serde_json::json!({
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        }))
        .send()
        .await
        .map_err(|_| "network")?;
    if !response.status().is_success() {
        return Err(if response.status().is_client_error() {
            "bad_code"
        } else {
            "provider_error"
        });
    }
    let key = Zeroizing::new(response.json::<Reply>().await.map_err(|_| "bad_reply")?.key);
    if !crate::agent_credentials::token_shaped(&key) {
        return Err("bad_reply");
    }
    Ok(key)
}

impl Service {
    /// Returns only the authorization URL. The storage closure runs after approval commits.
    pub async fn begin_openrouter(
        self: &Arc<Self>,
        save: impl FnOnce(&str) -> Result<String, Failure> + Send + 'static,
        on_finish: impl FnOnce() + Send + 'static,
    ) -> Result<Begun, Failure> {
        self.start_openrouter(LOGIN_TIMEOUT, save, on_finish).await
    }

    async fn start_openrouter(
        self: &Arc<Self>,
        timeout: Duration,
        save: impl FnOnce(&str) -> Result<String, Failure> + Send + 'static,
        on_finish: impl FnOnce() + Send + 'static,
    ) -> Result<Begun, Failure> {
        let _starting = self.starting.lock().await;
        let sign_in = SignIn::OpenRouter;
        if let Some(previous) = self.previous_pending(sign_in) {
            Self::stop(&previous).await;
        }

        let client = self.oauth.http()?.clone();
        let origin = self.oauth.endpoints.openrouter.clone();
        let callback = Callback::start(&origin).await?;
        let challenge = Begun {
            attempt: uuid::Uuid::new_v4().to_string(),
            url: callback.url.to_string(),
            user_code: String::new(),
            expires_at: now() + timeout.as_secs() as i64,
            interval: 0,
        };
        let (cancel, mut cancelled) = watch::channel(false);
        let (state, receiver) = watch::channel(Status::Pending);
        let started = Instant::now();
        self.attempts.lock().unwrap_or_else(|poison| poison.into_inner()).insert(
            challenge.attempt.clone(),
            Arc::new(Attempt { sign_in, request: None, started, cancel, state: receiver }),
        );
        static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
        SCOPE.get_or_init(|| cmux_scope::Scope::new("OpenRouter sign-in"))
            .spawn_named("OpenRouter approval", async move {
                let status = tokio::select! {
                    biased;
                    _ = async { let _ = cancelled.wait_for(|yes| *yes).await; } => Status::Cancelled,
                    outcome = tokio::time::timeout_at(started + timeout, callback.exchange(&client, &origin)) => {
                        match outcome {
                            Err(_) => Status::Failed("expired_token"),
                            Ok(Err(code)) => Status::Failed(code),
                            Ok(Ok(key)) => match blocking(move || save(&key)).await {
                                Ok(id) => Status::Done(id),
                                Err(code) => Status::Failed(code),
                            },
                        }
                    }
                };
                if matches!(status, Status::Done(_)) { on_finish(); }
                state.send_replace(status);
            });
        Ok(challenge)
    }
}

#[cfg(test)]
mod tests;

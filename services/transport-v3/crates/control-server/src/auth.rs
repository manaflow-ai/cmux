//! Stack is the source of user/session and team authority. Regional caching is
//! bounded in count and time; its original verification time is passed to grant issuance.
use crate::{identifier, now, Error};
use reqwest::{
    header::{HeaderMap, HeaderValue},
    Client, Url,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};

#[derive(Clone)]
pub struct Identity {
    pub user: String,
    pub team: String,
    pub admin: bool,
    pub verified_at: u64,
}
struct Cached {
    identity: Identity,
    expires: Instant,
}
pub struct Stack {
    client: Client,
    origin: Url,
    project: String,
    publishable: String,
    secret: String,
    cache: Mutex<HashMap<[u8; 32], Cached>>,
    slots: Semaphore,
}
#[derive(Deserialize)]
struct User {
    id: String,
    #[serde(default)]
    is_anonymous: bool,
}
#[derive(Deserialize)]
struct Item {
    id: String,
}
#[derive(Deserialize)]
struct Page<T> {
    items: Vec<T>,
    #[serde(default)]
    next_cursor: Option<String>,
}
#[derive(Deserialize)]
struct Permission {
    id: String,
    team_id: String,
    user_id: String,
}
impl Stack {
    /// Check the destination owner's current membership too. A stale device row
    /// must not keep a removed team member reachable indefinitely.
    pub async fn member_verified(&self, user: &str, team: &str) -> Result<u64, Error> {
        if !identifier(user) || !identifier(team) {
            return Err(Error::Denied);
        }
        let cache_key: [u8; 32] = Sha256::digest(
            serde_json::to_vec(&("membership", user, team)).map_err(|_| Error::Invalid)?,
        )
        .into();
        if let Some(hit) = self
            .cache
            .lock()
            .await
            .get(&cache_key)
            .filter(|v| v.expires > Instant::now())
        {
            return Ok(hit.identity.verified_at);
        }
        let _slot = self.slots.try_acquire().map_err(|_| Error::Unavailable)?;
        let started = Instant::now();
        let verified_at = now();
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("x-stack-access-type", "server"),
            ("x-stack-project-id", self.project.as_str()),
            ("x-stack-secret-server-key", self.secret.as_str()),
        ] {
            headers.insert(
                name,
                HeaderValue::from_str(value).map_err(|_| Error::Unavailable)?,
            );
        }
        let mut url = self
            .origin
            .join("api/v1/teams")
            .map_err(|_| Error::Unavailable)?;
        url.query_pairs_mut().append_pair("user_id", user);
        let mut cursors = std::collections::HashSet::new();
        for _ in 0..32 {
            let page: Page<Item> = self.get(url.clone(), &headers).await?;
            if page.items.len() > 4096 {
                return Err(Error::Unavailable);
            }
            if page.items.iter().any(|v| v.id == team) {
                if started.elapsed() >= Duration::from_secs(20) {
                    return Err(Error::Unavailable);
                }
                let mut cache = self.cache.lock().await;
                cache.retain(|_, v| v.expires > Instant::now());
                if cache.len() < 4096 {
                    cache.insert(
                        cache_key,
                        Cached {
                            identity: Identity {
                                user: user.into(),
                                team: team.into(),
                                admin: false,
                                verified_at,
                            },
                            expires: started + Duration::from_secs(20),
                        },
                    );
                }
                return Ok(verified_at);
            }
            let Some(cursor) = page.next_cursor else {
                return Err(Error::Denied);
            };
            if cursor.len() > 1024 || !cursors.insert(cursor.clone()) {
                return Err(Error::Unavailable);
            }
            url.query_pairs_mut()
                .clear()
                .append_pair("user_id", user)
                .append_pair("cursor", &cursor);
        }
        Err(Error::Unavailable)
    }
    pub fn new(
        origin: Url,
        project: String,
        publishable: String,
        secret: String,
    ) -> anyhow::Result<Self> {
        if origin.scheme() != "https"
            || origin.host_str().is_none()
            || !origin.username().is_empty()
            || origin.password().is_some()
            || origin.query().is_some()
            || origin.fragment().is_some()
            || origin.path() != "/"
            || !identifier(&project)
            || publishable.is_empty()
            || secret.is_empty()
        {
            anyhow::bail!("Stack requires an HTTPS origin and complete project credentials");
        }
        Ok(Self {
            client: Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(5))
                .build()?,
            origin,
            project,
            publishable,
            secret,
            cache: Mutex::new(HashMap::new()),
            slots: Semaphore::new(16),
        })
    }
    pub async fn authorize(&self, token: &str, team: &str, admin: bool) -> Result<Identity, Error> {
        if token.is_empty() || token.len() > 8192 || !identifier(team) {
            return Err(Error::Unauthorized);
        }
        let cache_key: [u8; 32] =
            Sha256::digest(serde_json::to_vec(&(token, team)).map_err(|_| Error::Invalid)?).into();
        if !admin {
            if let Some(hit) = self
                .cache
                .lock()
                .await
                .get(&cache_key)
                .filter(|v| v.expires > Instant::now())
            {
                return Ok(hit.identity.clone());
            }
        }
        let _slot = self.slots.try_acquire().map_err(|_| Error::Unavailable)?;
        let started = Instant::now();
        let verified_at = now();
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("x-stack-access-type", "client"),
            ("x-stack-project-id", self.project.as_str()),
            ("x-stack-publishable-client-key", self.publishable.as_str()),
            ("x-stack-access-token", token),
        ] {
            headers.insert(
                name,
                HeaderValue::from_str(value).map_err(|_| Error::Unauthorized)?,
            );
        }
        let me: User = self
            .get(
                self.origin
                    .join("api/v1/users/me")
                    .map_err(|_| Error::Unavailable)?,
                &headers,
            )
            .await?;
        if !identifier(&me.id) || me.is_anonymous {
            return Err(Error::Denied);
        }
        let mut url = self
            .origin
            .join("api/v1/teams")
            .map_err(|_| Error::Unavailable)?;
        url.query_pairs_mut().append_pair("user_id", "me");
        let mut found = false;
        let mut cursors = std::collections::HashSet::new();
        for _ in 0..32 {
            let page: Page<Item> = self.get(url.clone(), &headers).await?;
            if page.items.len() > 4096 {
                return Err(Error::Unavailable);
            }
            if page.items.iter().any(|v| v.id == team) {
                found = true;
                break;
            }
            let Some(cursor) = page.next_cursor else {
                break;
            };
            if cursor.len() > 1024 || !cursors.insert(cursor.clone()) {
                return Err(Error::Unavailable);
            }
            url.query_pairs_mut()
                .clear()
                .append_pair("user_id", "me")
                .append_pair("cursor", &cursor);
        }
        if !found {
            return Err(Error::Denied);
        }
        if admin {
            headers.remove("x-stack-access-token");
            headers.remove("x-stack-publishable-client-key");
            headers.insert("x-stack-access-type", HeaderValue::from_static("server"));
            headers.insert(
                "x-stack-secret-server-key",
                HeaderValue::from_str(&self.secret).map_err(|_| Error::Unavailable)?,
            );
            let mut url = self
                .origin
                .join("api/v1/team-permissions")
                .map_err(|_| Error::Unavailable)?;
            url.query_pairs_mut()
                .append_pair("team_id", team)
                .append_pair("user_id", &me.id)
                .append_pair("permission_id", "$update_team")
                .append_pair("recursive", "true");
            let page: Page<Permission> = self.get(url, &headers).await?;
            if !page
                .items
                .iter()
                .any(|p| p.id == "$update_team" && p.team_id == team && p.user_id == me.id)
            {
                return Err(Error::Denied);
            }
        }
        let identity = Identity {
            user: me.id,
            team: team.into(),
            admin,
            verified_at,
        };
        if started.elapsed() >= Duration::from_secs(20) {
            return Err(Error::Unavailable);
        }
        if !admin {
            let mut cache = self.cache.lock().await;
            cache.retain(|_, v| v.expires > Instant::now());
            if cache.len() < 4096 {
                cache.insert(
                    cache_key,
                    Cached {
                        identity: identity.clone(),
                        expires: started + Duration::from_secs(20),
                    },
                );
            }
        }
        Ok(identity)
    }
    async fn get<T: serde::de::DeserializeOwned>(
        &self,
        url: Url,
        headers: &HeaderMap,
    ) -> Result<T, Error> {
        let mut response = self
            .client
            .get(url)
            .headers(headers.clone())
            .send()
            .await
            .map_err(|_| Error::Unavailable)?;
        if !response.status().is_success() {
            if headers
                .get("x-stack-access-type")
                .is_some_and(|v| v == "server")
            {
                return Err(Error::Unavailable);
            }
            return Err(match response.status().as_u16() {
                401 => Error::Unauthorized,
                403 => Error::Denied,
                _ => Error::Unavailable,
            });
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Error::Unavailable)? {
            if bytes.len() + chunk.len() > 512 * 1024 {
                return Err(Error::Unavailable);
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| Error::Unavailable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        extract::{Query, State},
        http::{HeaderMap, StatusCode},
        routing::get,
        Json, Router,
    };
    use std::sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    };
    #[derive(Clone)]
    struct Mock {
        member: Arc<AtomicBool>,
        admin: Arc<AtomicBool>,
        calls: Arc<AtomicUsize>,
    }
    async fn me(
        State(s): State<Mock>,
        headers: HeaderMap,
    ) -> Result<Json<serde_json::Value>, StatusCode> {
        s.calls.fetch_add(1, Ordering::Relaxed);
        if headers
            .get("x-stack-access-token")
            .and_then(|v| v.to_str().ok())
            != Some("valid")
        {
            return Err(StatusCode::UNAUTHORIZED);
        }
        Ok(Json(serde_json::json!({"id":"alice","is_anonymous":false})))
    }
    async fn teams(State(s): State<Mock>) -> Json<serde_json::Value> {
        if s.member.load(Ordering::Relaxed) {
            Json(serde_json::json!({"items":[{"id":"team-a"}]}))
        } else {
            Json(serde_json::json!({"items":[]}))
        }
    }
    async fn permissions(
        State(s): State<Mock>,
        Query(q): Query<HashMap<String, String>>,
    ) -> Json<serde_json::Value> {
        if s.admin.load(Ordering::Relaxed) {
            Json(
                serde_json::json!({"items":[{"id":"$update_team","team_id":q["team_id"],"user_id":q["user_id"]}]}),
            )
        } else {
            Json(serde_json::json!({"items":[]}))
        }
    }
    async fn fixture() -> (Stack, Mock, tokio::task::JoinHandle<()>) {
        let state = Mock {
            member: Arc::new(true.into()),
            admin: Arc::new(false.into()),
            calls: Arc::new(0.into()),
        };
        let app = Router::new()
            .route("/api/v1/users/me", get(me))
            .route("/api/v1/teams", get(teams))
            .route("/api/v1/team-permissions", get(permissions))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}/", listener.local_addr().unwrap())
            .parse()
            .unwrap();
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        // HTTP is confined to this private test constructor. Public new() rejects it.
        let stack = Stack {
            client: Client::new(),
            origin,
            project: "project".into(),
            publishable: "public".into(),
            secret: "server".into(),
            cache: Mutex::new(HashMap::new()),
            slots: Semaphore::new(2),
        };
        (stack, state, task)
    }
    #[tokio::test]
    async fn stack_identity_and_membership_are_server_verified_and_cache_cannot_elevate_admin() {
        let (stack, state, task) = fixture().await;
        assert!(matches!(
            stack.authorize("invalid", "team-a", false).await,
            Err(Error::Unauthorized)
        ));
        assert!(matches!(
            stack.authorize("valid", "team-b", false).await,
            Err(Error::Denied)
        ));
        let identity = stack.authorize("valid", "team-a", false).await.unwrap();
        assert_eq!(identity.user, "alice");
        assert!(!identity.admin);
        let before = state.calls.load(Ordering::Relaxed);
        stack.authorize("valid", "team-a", false).await.unwrap();
        assert_eq!(before, state.calls.load(Ordering::Relaxed));
        assert!(matches!(
            stack.authorize("valid", "team-a", true).await,
            Err(Error::Denied)
        ));
        state.admin.store(true, Ordering::Relaxed);
        assert!(
            stack
                .authorize("valid", "team-a", true)
                .await
                .unwrap()
                .admin
        );
        state.admin.store(false, Ordering::Relaxed);
        assert!(matches!(
            stack.authorize("valid", "team-a", true).await,
            Err(Error::Denied)
        ));
        // An expired positive membership cache cannot mask removal.
        state.member.store(false, Ordering::Relaxed);
        for item in stack.cache.lock().await.values_mut() {
            item.expires = Instant::now() - Duration::from_secs(1);
        }
        assert!(matches!(
            stack.authorize("valid", "team-a", false).await,
            Err(Error::Denied)
        ));
        assert!(matches!(
            stack.member_verified("alice", "team-a").await,
            Err(Error::Denied)
        ));
        task.abort();
    }
    #[test]
    fn stack_configuration_rejects_credential_leaking_origins() {
        for origin in [
            "http://api.stack-auth.com/",
            "https://user:secret@api.stack-auth.com/",
            "https://api.stack-auth.com/path",
            "https://api.stack-auth.com/?x=1",
        ] {
            assert!(Stack::new(
                origin.parse().unwrap(),
                "project".into(),
                "public".into(),
                "secret".into()
            )
            .is_err());
        }
    }
}

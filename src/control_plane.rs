use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use reqwest::blocking::{Client, Response};
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::cli::Error;
use crate::config::{self, Config};

const DEFAULT_API_URL: &str = "https://coderouter.dev";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublicConfig {
    version: u32,
    auth: AuthConfig,
    coderouter: Endpoints,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthConfig {
    api_url: String,
    project_id: String,
    publishable_client_key: String,
    confirm_url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Endpoints {
    session_url: String,
    openai_base_url: String,
}

#[derive(Deserialize)]
struct CliStart {
    polling_code: String,
    login_code: String,
}

#[derive(Deserialize)]
struct CliPoll {
    status: String,
    refresh_token: Option<String>,
}

#[derive(Deserialize)]
struct StackTokens {
    access_token: String,
    refresh_token: Option<String>,
}

#[derive(Deserialize)]
struct StackTeam {
    id: String,
    display_name: String,
}

#[derive(Deserialize)]
struct TeamEnvelope {
    items: Vec<StackTeam>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouteSession {
    token: String,
    expires_at: String,
    openai_base_url: String,
}

pub fn login(no_browser: bool) -> Result<(), Error> {
    let api_url = api_url()?;
    let client = client(REQUEST_TIMEOUT)?;
    let public: PublicConfig = response_json(
        client
            .get(format!("{api_url}/api/cli/config"))
            .send()
            .map_err(network_error("load CodeRouter configuration"))?,
        "load CodeRouter configuration",
    )?;
    if public.version < 3 {
        return Err(Error::Backend(
            "coderouter.dev does not support the direct Vercel data plane yet".into(),
        ));
    }

    let started: CliStart = stack_json(
        &client,
        &public.auth,
        "POST",
        "/auth/cli",
        None,
        Some(json!({ "expires_in_millis": 15 * 60 * 1_000 })),
    )?;
    let mut confirmation = reqwest::Url::parse(&public.auth.confirm_url)
        .map_err(|error| Error::Backend(format!("invalid confirmation URL: {error}")))?;
    confirmation
        .query_pairs_mut()
        .append_pair("login_code", &started.login_code);
    println!("Authorize CodeRouter:\n  {confirmation}");
    if !no_browser {
        let _ = webbrowser::open(confirmation.as_str());
    }

    let deadline = Instant::now() + Duration::from_secs(15 * 60);
    let refresh_token = loop {
        if Instant::now() >= deadline {
            return Err(Error::Backend("CodeRouter login expired".into()));
        }
        let poll: CliPoll = stack_json(
            &client,
            &public.auth,
            "POST",
            "/auth/cli/poll",
            None,
            Some(json!({ "polling_code": started.polling_code })),
        )?;
        match poll.status.as_str() {
            "waiting" => thread::sleep(Duration::from_secs(2)),
            "success" => {
                break poll.refresh_token.ok_or_else(|| {
                    Error::Backend("Stack approved login without a refresh token".into())
                })?;
            }
            "expired" | "used" => {
                return Err(Error::Backend(format!("CodeRouter login {}", poll.status)));
            }
            status => {
                return Err(Error::Backend(format!(
                    "CodeRouter login returned unexpected status {status}"
                )));
            }
        }
    };

    let tokens = refresh_stack_tokens(&client, &public.auth, &refresh_token)?;
    let teams: TeamEnvelope = stack_json(
        &client,
        &public.auth,
        "GET",
        "/teams?user_id=me",
        Some(&tokens.access_token),
        None,
    )?;
    let team = select_team(teams.items, &tokens.access_token)?;
    let route: RouteSession = response_json(
        client
            .post(&public.coderouter.session_url)
            .header(AUTHORIZATION, format!("Bearer {}", tokens.access_token))
            .header("x-stack-refresh-token", &refresh_token)
            .header("x-cmux-team-id", &team.id)
            .send()
            .map_err(network_error("create CodeRouter route session"))?,
        "create CodeRouter route session",
    )?;

    config::save(&Config {
        api_url,
        stack_api_url: public.auth.api_url,
        stack_project_id: public.auth.project_id,
        stack_publishable_client_key: public.auth.publishable_client_key,
        stack_access_token: tokens.access_token,
        stack_refresh_token: tokens.refresh_token.unwrap_or(refresh_token),
        team_id: team.id,
        team_name: team.display_name,
        route_token: route.token,
        route_token_expires_at: route.expires_at,
        openai_base_url: if route.openai_base_url.is_empty() {
            public.coderouter.openai_base_url
        } else {
            route.openai_base_url
        },
    })?;
    println!("Signed in to CodeRouter.");
    Ok(())
}

pub fn logout() -> Result<(), Error> {
    let started = Instant::now();
    let mut current = config::load()?;
    if !current.logged_in() {
        println!(
            "Already logged out in {} ms.",
            started.elapsed().as_millis()
        );
        return Ok(());
    }
    let previous = current.clone();
    current.clear_session();
    config::save(&current)?;

    // Remote revocation is deliberately bounded. A local logout must never
    // appear frozen because an auth provider is degraded.
    let remote = revoke_stack_session(&previous, Duration::from_secs(2));
    if let Err(error) = remote {
        eprintln!("warning: local logout completed; remote revocation was unavailable: {error}");
    }
    println!("Logged out in {} ms.", started.elapsed().as_millis());
    Ok(())
}

pub fn refreshed_config() -> Result<Config, Error> {
    let mut current = config::load()?;
    if !current.logged_in() {
        return Err(Error::Usage("not signed in; run `cr login`".into()));
    }
    let auth = auth_from_config(&current);
    let tokens = refresh_stack_tokens(
        &client(REQUEST_TIMEOUT)?,
        &auth,
        &current.stack_refresh_token,
    )?;
    current.stack_access_token = tokens.access_token;
    if let Some(refresh) = tokens.refresh_token {
        current.stack_refresh_token = refresh;
    }
    config::save(&current)?;
    Ok(current)
}

pub fn accounts() -> Result<Value, Error> {
    let current = refreshed_config()?;
    response_json(
        authenticated(
            client(REQUEST_TIMEOUT)?.get(format!(
                "{}/api/coderouter/accounts",
                current.api_url.trim_end_matches('/')
            )),
            &current,
        )
        .send()
        .map_err(network_error("list CodeRouter accounts"))?,
        "list CodeRouter accounts",
    )
}

pub fn upload_credential(credential: &Value) -> Result<Value, Error> {
    let current = refreshed_config()?;
    response_json(
        authenticated(
            client(REQUEST_TIMEOUT)?.post(format!(
                "{}/api/coderouter/accounts",
                current.api_url.trim_end_matches('/')
            )),
            &current,
        )
        .json(credential)
        .send()
        .map_err(network_error("upload CodeRouter account"))?,
        "upload CodeRouter account",
    )
}

pub fn opencode_config() -> Result<String, Error> {
    let current = config::load()?;
    if !current.logged_in() {
        return Err(Error::Usage("not signed in; run `cr login`".into()));
    }
    let value: Value = response_json(
        client(REQUEST_TIMEOUT)?
            .get(format!(
                "{}/api/coderouter/opencode/config",
                current.api_url.trim_end_matches('/')
            ))
            .bearer_auth(&current.route_token)
            .send()
            .map_err(network_error("load OpenCode provider catalog"))?,
        "load OpenCode provider catalog",
    )?;
    serde_json::to_string(&value)
        .map_err(|error| Error::Backend(format!("encode OpenCode configuration: {error}")))
}

fn revoke_stack_session(current: &Config, timeout: Duration) -> Result<(), Error> {
    let client = client(timeout)?;
    let auth = auth_from_config(current);
    let tokens = refresh_stack_tokens(&client, &auth, &current.stack_refresh_token)?;
    let refresh = tokens
        .refresh_token
        .as_deref()
        .unwrap_or(&current.stack_refresh_token);
    let route_response = authenticated(
        client.delete(format!(
            "{}/api/coderouter/session",
            current.api_url.trim_end_matches('/')
        )),
        &Config {
            stack_access_token: tokens.access_token.clone(),
            stack_refresh_token: refresh.to_owned(),
            ..current.clone()
        },
    )
    .header("x-coderouter-route-token", &current.route_token)
    .send()
    .map_err(network_error("revoke CodeRouter route token"))?;
    if !route_response.status().is_success() {
        return Err(Error::Backend(format!(
            "revoke CodeRouter route token: HTTP {}",
            route_response.status()
        )));
    }
    let response = client
        .delete(format!(
            "{}/auth/sessions/current",
            auth.api_url.trim_end_matches('/')
        ))
        .header(CONTENT_TYPE, "application/json")
        .header("x-stack-project-id", &auth.project_id)
        .header("x-stack-access-type", "client")
        .header(
            "x-stack-publishable-client-key",
            &auth.publishable_client_key,
        )
        .header("x-stack-access-token", &tokens.access_token)
        .header("x-stack-refresh-token", refresh)
        .body("{}")
        .send()
        .map_err(network_error("revoke Stack session"))?;
    if response.status().is_success() || matches!(response.status().as_u16(), 400 | 401 | 404) {
        Ok(())
    } else {
        Err(Error::Backend(format!(
            "revoke Stack session: HTTP {}",
            response.status()
        )))
    }
}

fn authenticated(
    request: reqwest::blocking::RequestBuilder,
    current: &Config,
) -> reqwest::blocking::RequestBuilder {
    request
        .header(
            AUTHORIZATION,
            format!("Bearer {}", current.stack_access_token),
        )
        .header("x-stack-refresh-token", &current.stack_refresh_token)
        .header("x-cmux-team-id", &current.team_id)
}

fn refresh_stack_tokens(
    client: &Client,
    auth: &AuthConfig,
    refresh_token: &str,
) -> Result<StackTokens, Error> {
    response_json(
        client
            .post(format!(
                "{}/auth/oauth/token",
                auth.api_url.trim_end_matches('/')
            ))
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh_token),
                ("client_id", auth.project_id.as_str()),
                ("client_secret", auth.publishable_client_key.as_str()),
            ])
            .send()
            .map_err(network_error("refresh Stack session"))?,
        "refresh Stack session",
    )
}

fn stack_json<T: serde::de::DeserializeOwned>(
    client: &Client,
    auth: &AuthConfig,
    method: &str,
    path: &str,
    access_token: Option<&str>,
    body: Option<Value>,
) -> Result<T, Error> {
    let url = format!("{}{}", auth.api_url.trim_end_matches('/'), path);
    let mut request = match method {
        "GET" => client.get(url),
        "POST" => client.post(url),
        _ => return Err(Error::Backend("unsupported Stack method".into())),
    }
    .header("x-stack-project-id", &auth.project_id)
    .header("x-stack-access-type", "client")
    .header(
        "x-stack-publishable-client-key",
        &auth.publishable_client_key,
    );
    if let Some(token) = access_token {
        request = request.header("x-stack-access-token", token);
    }
    if let Some(value) = body {
        request = request.json(&value);
    }
    response_json(
        request
            .send()
            .map_err(network_error("request Stack session"))?,
        "request Stack session",
    )
}

fn select_team(teams: Vec<StackTeam>, access_token: &str) -> Result<StackTeam, Error> {
    if teams.len() == 1 {
        return Ok(teams.into_iter().next().expect("one team"));
    }
    if let Some(selected_id) = selected_team_id(access_token) {
        if let Some(index) = teams.iter().position(|team| team.id == selected_id) {
            return Ok(teams.into_iter().nth(index).expect("selected team"));
        }
    }
    if teams.is_empty() {
        Err(Error::Backend(
            "your CodeRouter account has no teams".into(),
        ))
    } else {
        Err(Error::Usage(
            "multiple CodeRouter teams are available; team selection is required".into(),
        ))
    }
}

fn selected_team_id(token: &str) -> Option<String> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(token.split('.').nth(1)?)
        .ok()?;
    serde_json::from_slice::<Value>(&bytes)
        .ok()?
        .get("selected_team_id")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn auth_from_config(current: &Config) -> AuthConfig {
    AuthConfig {
        api_url: current.stack_api_url.clone(),
        project_id: current.stack_project_id.clone(),
        publishable_client_key: current.stack_publishable_client_key.clone(),
        confirm_url: String::new(),
    }
}

fn api_url() -> Result<String, Error> {
    let value = std::env::var("CODEROUTER_API_URL")
        .unwrap_or_else(|_| DEFAULT_API_URL.to_owned())
        .trim_end_matches('/')
        .to_owned();
    let url = reqwest::Url::parse(&value)
        .map_err(|error| Error::Usage(format!("invalid CODEROUTER_API_URL: {error}")))?;
    let loopback = url.host_str() == Some("localhost")
        || url
            .host_str()
            .and_then(|host| host.parse::<std::net::IpAddr>().ok())
            .is_some_and(|ip| ip.is_loopback());
    if url.scheme() != "https" && !(url.scheme() == "http" && loopback) {
        return Err(Error::Usage(
            "CODEROUTER_API_URL must use HTTPS except on loopback".into(),
        ));
    }
    Ok(value)
}

fn client(timeout: Duration) -> Result<Client, Error> {
    Client::builder()
        .timeout(timeout)
        .user_agent(format!("coderouter/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| Error::Backend(error.to_string()))
}

fn response_json<T: serde::de::DeserializeOwned>(
    response: Response,
    action: &str,
) -> Result<T, Error> {
    let status = response.status();
    if !status.is_success() {
        let body = response.text().unwrap_or_default();
        return Err(Error::Backend(format!(
            "{action}: HTTP {status}{}",
            if body.trim().is_empty() {
                String::new()
            } else {
                format!(": {}", body.trim())
            }
        )));
    }
    response
        .json()
        .map_err(|error| Error::Backend(format!("{action}: invalid response: {error}")))
}

fn network_error(action: &'static str) -> impl FnOnce(reqwest::Error) -> Error {
    move |error| Error::Backend(format!("{action}: {error}"))
}

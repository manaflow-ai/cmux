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
const RETRYABLE_READ_STATUS: &[u16] = &[408, 425, 500, 502, 503, 504];
// OpenAI's model catalog hides all current models from very old client
// versions. This is a protocol compatibility version, not coderouter's version.
const CODEX_MODEL_CATALOG_CLIENT_VERSION: &str = "0.146.0";

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

#[derive(Clone, Debug)]
pub struct CodexModel {
    pub id: String,
    pub name: String,
    pub context_window: u64,
    pub max_tokens: u64,
}

#[derive(Deserialize)]
pub struct RemoveAccountResult {
    #[serde(rename = "lastAccount")]
    pub last_account: bool,
    #[serde(rename = "legacyCleanupPending", default)]
    pub legacy_cleanup_pending: bool,
}

pub struct OpenCodeConfig {
    pub content: String,
    pub models: Vec<String>,
}

pub fn login(no_browser: bool) -> Result<(), Error> {
    login_at(no_browser, None)
}

pub fn login_at(no_browser: bool, server: Option<&str>) -> Result<(), Error> {
    let starting = crate::loading::DelayedSpinner::new("Starting coderouter authorization");
    let api_url = api_url_for(server)?;
    let client = client(REQUEST_TIMEOUT)?;
    let public = load_public_config(&client, &api_url)?;

    let started: CliStart = stack_json(
        &client,
        &public.auth,
        "POST",
        "/auth/cli",
        None,
        Some(json!({ "expires_in_millis": 15 * 60 * 1_000 })),
    )?;
    starting.finish();
    let mut confirmation = reqwest::Url::parse(&public.auth.confirm_url)
        .map_err(|error| Error::Backend(format!("invalid confirmation URL: {error}")))?;
    confirmation
        .query_pairs_mut()
        .append_pair("login_code", &started.login_code);
    println!("Authorize coderouter:\n  {confirmation}");
    if !no_browser {
        let _ = webbrowser::open(confirmation.as_str());
    }

    let waiting = crate::loading::DelayedSpinner::new("Waiting for coderouter authorization");
    let deadline = Instant::now() + Duration::from_secs(15 * 60);
    let refresh_token = loop {
        if Instant::now() >= deadline {
            return Err(Error::Backend("coderouter login expired".into()));
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
                    Error::Backend("Authentication succeeded without a refresh token".into())
                })?;
            }
            "expired" | "used" => {
                return Err(Error::Backend(format!("coderouter login {}", poll.status)));
            }
            status => {
                return Err(Error::Backend(format!(
                    "coderouter login returned unexpected status {status}"
                )));
            }
        }
    };
    waiting.finish();

    complete_login(&api_url, &client, &public, &refresh_token)
}

pub fn login_with_code_at(value: &str, server: Option<&str>) -> Result<(), Error> {
    let exchanging = crate::loading::DelayedSpinner::new("Exchanging coderouter sign-in code");
    let api_url = api_url_for(server)?;
    let client = client(REQUEST_TIMEOUT)?;
    let public = load_public_config(&client, &api_url)?;
    let code = code_from_value(value)?;
    let tokens: StackTokens = stack_json(
        &client,
        &public.auth,
        "POST",
        "/auth/otp/sign-in",
        None,
        Some(json!({ "code": code })),
    )?;
    let refresh_token = tokens.refresh_token.ok_or_else(|| {
        Error::Backend("Authentication succeeded without returning a refresh token".into())
    })?;
    exchanging.finish();
    complete_login(&api_url, &client, &public, &refresh_token)
}

fn complete_login(
    api_url: &str,
    client: &Client,
    public: &PublicConfig,
    refresh_token: &str,
) -> Result<(), Error> {
    let loading = crate::loading::DelayedSpinner::new("Setting up coderouter");
    let tokens = refresh_stack_tokens(client, &public.auth, refresh_token)?;
    let teams: TeamEnvelope = stack_json(
        client,
        &public.auth,
        "GET",
        "/teams?user_id=me",
        Some(&tokens.access_token),
        None,
    )?;
    let team = select_team(teams.items, &tokens.access_token)?;
    let current_refresh_token = tokens
        .refresh_token
        .clone()
        .unwrap_or_else(|| refresh_token.to_owned());
    let route: RouteSession = response_json(
        client
            .post(&public.coderouter.session_url)
            .header(AUTHORIZATION, format!("Bearer {}", tokens.access_token))
            .header("x-stack-refresh-token", &current_refresh_token)
            .header("x-cmux-team-id", &team.id)
            .send()
            .map_err(network_error("create coderouter route session"))?,
        "create coderouter route session",
    )?;

    config::save(&Config {
        api_url: api_url.to_owned(),
        stack_api_url: public.auth.api_url.clone(),
        stack_project_id: public.auth.project_id.clone(),
        stack_publishable_client_key: public.auth.publishable_client_key.clone(),
        stack_access_token: tokens.access_token,
        stack_refresh_token: current_refresh_token,
        team_id: team.id,
        team_name: team.display_name,
        route_token: route.token,
        route_token_expires_at: route.expires_at,
        openai_base_url: if route.openai_base_url.is_empty() {
            public.coderouter.openai_base_url.clone()
        } else {
            route.openai_base_url
        },
    })?;
    loading.finish();
    println!("Signed in to coderouter.");
    Ok(())
}

fn load_public_config(client: &Client, api_url: &str) -> Result<PublicConfig, Error> {
    let public: PublicConfig = response_json(
        send_safe_read(
            client.get(format!("{api_url}/api/cli/config")),
            "load coderouter configuration",
        )?,
        "load coderouter configuration",
    )?;
    if public.version < 3 {
        return Err(Error::Backend(
            "coderouter.dev does not support the direct Vercel data plane yet".into(),
        ));
    }
    Ok(public)
}

fn code_from_value(value: &str) -> Result<String, Error> {
    let value = value.trim();
    if value.is_empty() {
        return Err(Error::Usage("a sign-in code is required".into()));
    }
    if let Ok(url) = reqwest::Url::parse(value) {
        return url
            .query_pairs()
            .find_map(|(key, value)| (key == "code").then(|| value.into_owned()))
            .ok_or_else(|| Error::Usage("the pasted URL does not contain a `code`".into()));
    }
    Ok(value.to_owned())
}

pub fn logout() -> Result<(), Error> {
    let mut current = config::load()?;
    if !current.logged_in() {
        println!("Already logged out.");
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
    println!("Logged out.");
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

pub fn ensure_route_config() -> Result<Config, Error> {
    let current = current_route_config()?;
    let client = client(REQUEST_TIMEOUT)?;
    let response = send_safe_read(
        client
            .get(format!(
                "{}/api/coderouter/session",
                current.api_url.trim_end_matches('/')
            ))
            .bearer_auth(&current.route_token),
        "validate coderouter route session",
    )?;
    if response.status().is_success() {
        return Ok(current);
    }
    // Older compatible self-hosts may not expose the validation endpoint.
    if matches!(response.status().as_u16(), 404 | 405) {
        return Ok(current);
    }
    if response.status().as_u16() != 401 {
        return response_json::<Value>(response, "validate coderouter route session")
            .map(|_| current);
    }

    renew_route_config(&client)
}

fn current_route_config() -> Result<Config, Error> {
    let current = config::load()?;
    if !current.logged_in() {
        return Err(Error::Usage("not signed in; run `cr login`".into()));
    }
    Ok(current)
}

fn renew_route_config(client: &Client) -> Result<Config, Error> {
    let mut current = refreshed_config()?;
    let public = load_public_config(client, &current.api_url)?;
    let route: RouteSession = response_json(
        authenticated(client.post(&public.coderouter.session_url), &current)
            .send()
            .map_err(network_error("renew coderouter route session"))?,
        "renew coderouter route session",
    )?;
    current.route_token = route.token;
    current.route_token_expires_at = route.expires_at;
    current.openai_base_url = route.openai_base_url;
    config::save(&current)?;
    Ok(current)
}

pub fn accounts() -> Result<Value, Error> {
    let client = client(REQUEST_TIMEOUT)?;
    let current = current_route_config()?;
    // Validation and status are independent reads. Run them together so
    // revocation stays fail-closed without adding a serial preflight.
    let (validation, response) = thread::scope(|scope| {
        let validation_client = client.clone();
        let validation_current = current.clone();
        let validation =
            scope.spawn(move || validate_route_response(&validation_client, &validation_current));
        let accounts = list_accounts_response(&client, &current);
        (
            validation.join().expect("route validation thread"),
            accounts,
        )
    });
    let validation = validation?;
    let mut response = response?;
    if validation.status().as_u16() == 401 || response.status().as_u16() == 401 {
        let current = renew_route_config(&client)?;
        response = list_accounts_response(&client, &current)?;
    } else if !validation.status().is_success()
        && !matches!(validation.status().as_u16(), 404 | 405)
    {
        return response_json::<Value>(validation, "validate coderouter route session")
            .and_then(|_| response_json(response, "list coderouter accounts"));
    }
    response_json(response, "list coderouter accounts")
}

fn validate_route_response(client: &Client, current: &Config) -> Result<Response, Error> {
    send_safe_read(
        client
            .get(format!(
                "{}/api/coderouter/session",
                current.api_url.trim_end_matches('/')
            ))
            .bearer_auth(&current.route_token),
        "validate coderouter route session",
    )
}

fn list_accounts_response(client: &Client, current: &Config) -> Result<Response, Error> {
    send_safe_read(
        client
            .get(format!(
                "{}/api/coderouter/accounts",
                current.api_url.trim_end_matches('/')
            ))
            .bearer_auth(&current.route_token),
        "list coderouter accounts",
    )
}

pub fn codex_models() -> Result<Vec<CodexModel>, Error> {
    let current = ensure_route_config()?;
    let value: Value = response_json(
        send_safe_read(
            client(REQUEST_TIMEOUT)?
                .get(format!(
                    "{}/models?client_version={}",
                    current.openai_base_url.trim_end_matches('/'),
                    CODEX_MODEL_CATALOG_CLIENT_VERSION,
                ))
                .bearer_auth(&current.route_token),
            "load coderouter models",
        )?,
        "load coderouter models",
    )?;
    let models = value
        .get("models")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|model| {
            let id = model
                .get("slug")
                .or_else(|| model.get("id"))
                .and_then(Value::as_str)?
                .to_owned();
            Some(CodexModel {
                name: model
                    .get("display_name")
                    .or_else(|| model.get("name"))
                    .and_then(Value::as_str)
                    .unwrap_or(&id)
                    .to_owned(),
                id,
                context_window: model
                    .get("context_window")
                    .and_then(Value::as_u64)
                    .unwrap_or(272_000),
                max_tokens: model
                    .get("max_output_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(128_000),
            })
        })
        .collect::<Vec<_>>();
    if models.is_empty() {
        return Err(Error::Backend(
            "coderouter returned no models for Pi".into(),
        ));
    }
    Ok(models)
}

pub fn remove_account(account_id: &str) -> Result<RemoveAccountResult, Error> {
    let current = refreshed_config()?;
    response_json(
        authenticated(
            client(REQUEST_TIMEOUT)?.delete(format!(
                "{}/api/coderouter/accounts/{account_id}",
                current.api_url.trim_end_matches('/')
            )),
            &current,
        )
        .send()
        .map_err(network_error("remove subscription"))?,
        "remove subscription",
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
        .map_err(network_error("upload subscription to coderouter"))?,
        "upload subscription to coderouter",
    )
}

pub fn opencode_config() -> Result<OpenCodeConfig, Error> {
    let current = ensure_route_config()?;
    let value: Value = response_json(
        send_safe_read(
            client(REQUEST_TIMEOUT)?
                .get(format!(
                    "{}/api/coderouter/opencode/config",
                    current.api_url.trim_end_matches('/')
                ))
                .bearer_auth(&current.route_token),
            "load OpenCode provider catalog",
        )?,
        "load OpenCode provider catalog",
    )?;
    let models = value
        .get("provider")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|providers| providers.iter())
        .flat_map(|(provider, value)| {
            value
                .get("models")
                .and_then(Value::as_object)
                .into_iter()
                .flat_map(move |models| {
                    models
                        .keys()
                        .map(move |model| format!("{provider}/{model}"))
                })
        })
        .collect::<Vec<_>>();
    if models.is_empty() {
        return Err(Error::Backend(
            "coderouter returned no OpenCode Go models".into(),
        ));
    }
    let content = serde_json::to_string(&value)
        .map_err(|error| Error::Backend(format!("encode OpenCode configuration: {error}")))?;
    Ok(OpenCodeConfig { content, models })
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
    .map_err(network_error("revoke coderouter route token"))?;
    if !route_response.status().is_success() {
        return Err(Error::Backend(format!(
            "revoke coderouter route token: HTTP {}",
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
        .map_err(network_error("revoke coderouter session"))?;
    if response.status().is_success() || matches!(response.status().as_u16(), 400 | 401 | 404) {
        Ok(())
    } else {
        Err(Error::Backend(format!(
            "revoke coderouter session: HTTP {}",
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
            .map_err(network_error("refresh coderouter session"))?,
        "refresh coderouter session",
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
        _ => return Err(Error::Backend("unsupported authentication method".into())),
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
    let response = if method == "GET" {
        send_safe_read(request, "request coderouter session")?
    } else {
        request
            .send()
            .map_err(network_error("request coderouter session"))?
    };
    response_json(response, "request coderouter session")
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
            "your coderouter account has no teams".into(),
        ))
    } else {
        Err(Error::Usage(
            "multiple coderouter teams are available; team selection is required".into(),
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

fn api_url_for(server: Option<&str>) -> Result<String, Error> {
    let value = server
        .map(str::to_owned)
        .or_else(|| std::env::var("CODEROUTER_API_URL").ok())
        .unwrap_or_else(|| DEFAULT_API_URL.to_owned())
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
            "coderouter server URL must use HTTPS except on loopback".into(),
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

fn send_safe_read(
    request: reqwest::blocking::RequestBuilder,
    action: &'static str,
) -> Result<Response, Error> {
    let retry = request.try_clone();
    match request.send() {
        Ok(response)
            if RETRYABLE_READ_STATUS.contains(&response.status().as_u16()) && retry.is_some() =>
        {
            retry
                .expect("checked retry request")
                .send()
                .map_err(network_error(action))
        }
        Ok(response) => Ok(response),
        Err(first) => match retry {
            Some(retry) => retry.send().map_err(network_error(action)),
            None => Err(network_error(action)(first)),
        },
    }
}

fn response_json<T: serde::de::DeserializeOwned>(
    response: Response,
    action: &str,
) -> Result<T, Error> {
    let status = response.status();
    if !status.is_success() {
        let body = response.text().unwrap_or_default();
        let parsed = serde_json::from_str::<Value>(&body).ok();
        return Err(response_error(status, parsed.as_ref(), action));
    }
    response
        .json()
        .map_err(|error| Error::Backend(format!("{action}: invalid response: {error}")))
}

fn response_error(status: reqwest::StatusCode, parsed: Option<&Value>, action: &str) -> Error {
    let code = parsed
        .and_then(|value| value.get("error"))
        .and_then(Value::as_str);
    if status.as_u16() == 402 && code == Some("pro_required") {
        return Error::Usage(
            "hosted coderouter requires cmux Pro or Team; upgrade at https://cmux.com/pricing or connect a self-hosted server with `cr login --server <URL>`".into(),
        );
    }
    let server_message = parsed
        .and_then(|value| value.get("message"))
        .and_then(Value::as_str)
        .filter(|message| !message.trim().is_empty() && message.len() <= 500)
        .map(scrub_server_message);
    let guidance = match status.as_u16() {
        400 => server_message.unwrap_or_else(|| {
            format!("{action} rejected the request; verify the supplied code or input")
        }),
        401 => {
            format!("{action}: your authorization expired or was revoked; run `cr login` and retry")
        }
        403 => format!("{action}: your account does not have permission for this team"),
        404 => format!(
            "{action}: coderouter endpoint not found; verify `cr login --server <URL>` and update `cr`"
        ),
        409 => format!("{action}: another update won the race; refresh with `cr` and retry"),
        429 => format!("{action}: temporarily rate limited; retry shortly"),
        500..=599 => server_message.unwrap_or_else(|| {
            format!("{action}: coderouter is temporarily unavailable; retry shortly")
        }),
        _ => server_message.unwrap_or_else(|| format!("{action}: request failed ({status})")),
    };
    Error::Backend(format!("{guidance} [HTTP {}]", status.as_u16()))
}

fn network_error(action: &'static str) -> impl FnOnce(reqwest::Error) -> Error {
    move |error| {
        let detail = if error.is_timeout() {
            "timed out; check your connection and retry"
        } else if error.is_connect() {
            "could not connect; check DNS, your network, and the configured server"
        } else if error.is_request() {
            "could not send the request; check your network and retry"
        } else {
            "network request failed; retry shortly"
        };
        Error::Backend(format!("{action}: {detail}"))
    }
}

fn scrub_server_message(message: &str) -> String {
    message
        .split_whitespace()
        .map(|word| {
            if word.starts_with("crt_")
                || word.starts_with("srt_")
                || word.starts_with("sk-")
                || word.starts_with("eyJ")
            {
                "[redacted]"
            } else {
                word
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod fault_matrix_tests {
    use super::*;
    use serde_json::json;

    fn message(status: u16, body: Option<Value>) -> String {
        response_error(
            reqwest::StatusCode::from_u16(status).unwrap(),
            body.as_ref(),
            "test action",
        )
        .to_string()
    }

    #[test]
    fn snapshots_actionable_http_error_matrix() {
        let cases = [
            (
                400,
                "test action rejected the request; verify the supplied code or input [HTTP 400]",
            ),
            (
                401,
                "test action: your authorization expired or was revoked; run `cr login` and retry [HTTP 401]",
            ),
            (
                403,
                "test action: your account does not have permission for this team [HTTP 403]",
            ),
            (
                404,
                "test action: coderouter endpoint not found; verify `cr login --server <URL>` and update `cr` [HTTP 404]",
            ),
            (
                409,
                "test action: another update won the race; refresh with `cr` and retry [HTTP 409]",
            ),
            (
                429,
                "test action: temporarily rate limited; retry shortly [HTTP 429]",
            ),
            (
                500,
                "test action: coderouter is temporarily unavailable; retry shortly [HTTP 500]",
            ),
            (
                503,
                "test action: coderouter is temporarily unavailable; retry shortly [HTTP 503]",
            ),
        ];
        for (status, expected) in cases {
            assert_eq!(message(status, None), expected);
        }
    }

    #[test]
    fn snapshots_hosted_pro_self_hosting_guidance() {
        assert_eq!(
            message(402, Some(json!({ "error": "pro_required" }))),
            "hosted coderouter requires cmux Pro or Team; upgrade at https://cmux.com/pricing or connect a self-hosted server with `cr login --server <URL>`"
        );
    }

    #[test]
    fn accepts_safe_server_guidance_but_scrubs_credentials() {
        let rendered = message(
            503,
            Some(json!({
                "message": "account unavailable for crt_secret sk-secret eyJtoken; add a healthy subscription"
            })),
        );
        assert_eq!(
            rendered,
            "account unavailable for [redacted] [redacted] [redacted] add a healthy subscription [HTTP 503]"
        );
        assert!(!rendered.contains("secret"));
        assert!(!rendered.contains("eyJtoken"));
    }

    #[test]
    fn ignores_oversized_or_empty_server_messages() {
        assert_eq!(
            message(500, Some(json!({ "message": "x".repeat(501) }))),
            "test action: coderouter is temporarily unavailable; retry shortly [HTTP 500]"
        );
        assert_eq!(
            message(400, Some(json!({ "message": "   " }))),
            "test action rejected the request; verify the supplied code or input [HTTP 400]"
        );
    }
}

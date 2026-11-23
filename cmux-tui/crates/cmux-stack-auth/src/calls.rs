//! The Stack calls `StackAuthClient.swift` makes through the SDK: the sign-in exchanges (OAuth
//! code with PKCE, OTP code, password), `/users/me`, the team list, team selection and creation,
//! and the session revoke (StackClientApp.swift, CurrentUser.swift, Team.swift).

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use reqwest::header::CONTENT_TYPE;
use reqwest::{Method, Url};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::client::{StackClient, TOKEN_PATH, TokenResolution, exchange, refresh_failure_error};
use crate::error::StackError;
use crate::wire::{Session, form};

/// The signed-in user (`GET /users/me`), as the app shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CurrentUser {
    pub id: String,
    pub primary_email: Option<String>,
    pub display_name: Option<String>,
    pub profile_image_url: Option<String>,
    /// The server-written review-demo flag: only a JSON `true` at
    /// `client_read_only_metadata.cmuxReviewDemoContent` counts.
    pub demonstration_content_enabled: bool,
    /// Stack's cross-device selected team.
    pub selected_team_id: Option<String>,
}

/// One Stack team of the user.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Team {
    pub id: String,
    pub display_name: String,
    pub profile_image_url: Option<String>,
    /// `client_read_only_metadata.cmuxPlan`: 1 to 64 characters, else none.
    pub plan: Option<String>,
}

impl Team {
    fn from_json(value: &Value) -> Self {
        Team {
            id: text(value, "id").unwrap_or_default(),
            display_name: text(value, "display_name").unwrap_or_default(),
            profile_image_url: text(value, "profile_image_url"),
            plan: value
                .get("client_read_only_metadata")
                .and_then(|m| m.get("cmuxPlan"))
                .and_then(Value::as_str)
                .filter(|plan| !plan.is_empty() && plan.chars().count() <= 64)
                .map(str::to_owned),
        }
    }
}

/// Whether a Stack team is a cmux VM personal tenant (`cmuxVmPersonalTenant: true`): the private
/// team cmux's server makes for the VM API. It is no team: never listed, never selected (CMUX-380).
fn is_vm_personal_tenant(value: &Value) -> bool {
    value.get("client_read_only_metadata").and_then(|m| m.get("cmuxVmPersonalTenant"))
        == Some(&Value::Bool(true))
}

fn text(value: &Value, name: &str) -> Option<String> {
    value.get(name)?.as_str().map(str::to_owned)
}

fn flag(value: &Value, name: &str) -> bool {
    value.get(name).and_then(Value::as_bool).unwrap_or(false)
}

/// A browser sign-in to start: open `url` in the sign-in sheet, keep the rest for the callback.
#[derive(Clone, PartialEq, Eq)]
pub struct OAuthStart {
    /// `<base>/api/v1/auth/oauth/authorize/<provider>?...`; holds the access token when one was
    /// given, so it is never logged.
    pub url: String,
    pub state: String,
    /// The PKCE verifier the token exchange proves.
    pub code_verifier: String,
    pub redirect_url: String,
}

/// Never the URL (it can hold a token) or the verifier.
impl std::fmt::Debug for OAuthStart {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OAuthStart")
            .field("redirect_url", &self.redirect_url)
            .finish_non_exhaustive()
    }
}

/// What the sign-in sheet's callback URL said.
#[derive(Clone, PartialEq, Eq)]
pub enum OAuthCallback {
    Code(String),
    /// The provider's `error` and `error_description`.
    Error {
        code: String,
        description: Option<String>,
    },
    /// No `code` and no `error`.
    MissingCode,
}

impl std::fmt::Debug for OAuthCallback {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OAuthCallback::Code(_) => f.write_str("Code(<redacted>)"),
            OAuthCallback::Error { code, .. } => write!(f, "Error({code})"),
            OAuthCallback::MissingCode => f.write_str("MissingCode"),
        }
    }
}

impl OAuthCallback {
    /// Reads a callback URL's query.
    pub fn parse(callback_url: &str) -> Self {
        let Ok(url) = Url::parse(callback_url) else { return OAuthCallback::MissingCode };
        let pair =
            |name: &str| url.query_pairs().find(|(k, _)| k == name).map(|(_, v)| v.into_owned());
        match (pair("code"), pair("error")) {
            (Some(code), _) => OAuthCallback::Code(code),
            (None, Some(code)) => {
                OAuthCallback::Error { code, description: pair("error_description") }
            }
            (None, None) => OAuthCallback::MissingCode,
        }
    }
}

const ALPHANUMERIC: &[u8; 62] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// `length` random letters and digits (the SDK's `generateRandomString`).
fn random_string(length: usize) -> Result<String, StackError> {
    let mut out = String::with_capacity(length);
    while out.len() < length {
        let mut bytes = [0_u8; 64];
        getrandom::fill(&mut bytes).map_err(|_| StackError::Client("no system randomness"))?;
        // 248 = 4 x 62: a byte under it picks a character with no bias.
        for byte in bytes.into_iter().filter(|b| *b < 248) {
            if out.len() >= length {
                break;
            }
            if let Some(c) = byte.checked_rem(62).and_then(|i| ALPHANUMERIC.get(usize::from(i))) {
                out.push(char::from(*c));
            }
        }
    }
    Ok(out)
}

/// The S256 PKCE challenge of `verifier`: base64url of its SHA-256, unpadded.
pub(crate) fn code_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// The pair a sign-in answered (`access_token`, and `refresh_token` when `refresh_required`
/// or present).
fn session_from(
    answer: &Value,
    refresh_required: bool,
    what: &'static str,
) -> Result<Session, StackError> {
    let access =
        answer.get("access_token").and_then(Value::as_str).ok_or(StackError::Parse(what))?;
    let refresh = answer.get("refresh_token").and_then(Value::as_str);
    if refresh_required && refresh.is_none() {
        return Err(StackError::Parse(what));
    }
    Ok(Session::new(Some(access), refresh))
}

impl StackClient {
    /// The browser sign-in's start (`getOAuthUrl`): a new state and PKCE verifier, and the
    /// authorize URL for `provider`. `access_token` links the provider to a signed-in account.
    pub fn oauth_authorize_url(
        &self,
        provider: &str,
        redirect_url: &str,
        error_redirect_url: &str,
        access_token: Option<&str>,
    ) -> Result<OAuthStart, StackError> {
        if !redirect_url.contains("://") || !error_redirect_url.contains("://") {
            return Err(StackError::Client("OAuth redirect URLs must be absolute"));
        }
        let state = random_string(32)?;
        let code_verifier = random_string(64)?;
        let mut url =
            self.url(&format!("/api/v1/auth/oauth/authorize/{}", provider.to_ascii_lowercase()))?;
        {
            let mut query = url.query_pairs_mut();
            query
                .append_pair("client_id", &self.config.project_id)
                .append_pair("client_secret", self.oauth_client_secret())
                .append_pair("redirect_uri", redirect_url)
                .append_pair("scope", "legacy")
                .append_pair("state", &state)
                .append_pair("grant_type", "authorization_code")
                .append_pair("code_challenge", &code_challenge(&code_verifier))
                .append_pair("code_challenge_method", "S256")
                .append_pair("response_type", "code")
                .append_pair("type", "authenticate")
                .append_pair("error_redirect_uri", error_redirect_url);
            if let Some(token) = access_token {
                query.append_pair("token", token);
            }
        }
        Ok(OAuthStart {
            url: url.into(),
            state,
            code_verifier,
            redirect_url: redirect_url.to_owned(),
        })
    }

    /// The browser sign-in's code exchange (`callOAuthCallback`): `POST /auth/oauth/token` with
    /// `grant_type=authorization_code` and the PKCE verifier. Answers the new session.
    pub async fn exchange_oauth_code(
        &self,
        callback: &OAuthCallback,
        start: &OAuthStart,
    ) -> Result<Session, StackError> {
        let code = match callback {
            OAuthCallback::Code(code) => code,
            OAuthCallback::Error { code, .. } => {
                return Err(StackError::OAuth { code: code.clone(), status: 0 });
            }
            OAuthCallback::MissingCode => {
                return Err(StackError::OAuth { code: "missing_code".to_owned(), status: 0 });
            }
        };
        let body = form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", &start.redirect_url),
            ("code_verifier", &start.code_verifier),
            ("client_id", &self.config.project_id),
            ("client_secret", self.oauth_client_secret()),
        ]);
        // The SDK sends this exchange with the project id alone.
        let request = self
            .http()
            .post(self.url(TOKEN_PATH)?)
            .timeout(self.config.request_timeout)
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .header("x-hexclave-project-id", &self.config.project_id)
            .body(body);
        let answer =
            exchange(request, self.config.request_timeout).await.map_err(StackError::from)?;
        let json = answer.json();
        if answer.status != 200 {
            let code = json
                .as_ref()
                .and_then(|v| v.get("error")?.as_str().map(str::to_owned))
                .unwrap_or_else(|| "token_exchange_failed".to_owned());
            return Err(StackError::OAuth { code, status: answer.status });
        }
        session_from(&json.unwrap_or(Value::Null), false, "the token exchange answer")
    }

    /// Emails a sign-in code (`POST /auth/otp/send-sign-in-code`). Answers the nonce the entered
    /// code is joined with at [`StackClient::sign_in_with_code`].
    pub async fn send_sign_in_code(
        &self,
        email: &str,
        callback_url: &str,
    ) -> Result<String, StackError> {
        let body = json!({ "email": email, "callback_url": callback_url });
        let answer =
            self.call(Method::POST, "/auth/otp/send-sign-in-code", Some(&body), None).await?;
        answer
            .json()
            .and_then(|v| v.get("nonce")?.as_str().map(str::to_owned))
            .ok_or(StackError::Parse("the sign-in code answer"))
    }

    /// Signs in with an emailed code joined with its nonce (`POST /auth/otp/sign-in`).
    pub async fn sign_in_with_code(&self, code: &str) -> Result<Session, StackError> {
        let body = json!({ "code": code });
        let answer = self.call(Method::POST, "/auth/otp/sign-in", Some(&body), None).await?;
        session_from(&answer.json().unwrap_or(Value::Null), true, "the code sign-in answer")
    }

    /// Signs in with an email and password (`POST /auth/password/sign-in`; debug builds' account).
    pub async fn sign_in_with_password(
        &self,
        email: &str,
        password: &str,
    ) -> Result<Session, StackError> {
        let body = json!({ "email": email, "password": password });
        let answer = self.call(Method::POST, "/auth/password/sign-in", Some(&body), None).await?;
        session_from(&answer.json().unwrap_or(Value::Null), true, "the password sign-in answer")
    }

    /// The signed-in user (`GET /users/me`), or `None` when signed out, or when the account is
    /// anonymous or restricted. Unlike the SDK's `.returnNull`, a failed read is an error, so a
    /// caller can tell "no session" from "could not check".
    pub async fn current_user(
        &self,
        session: &mut Session,
    ) -> Result<Option<CurrentUser>, StackError> {
        match self.likely_valid_access_token(session).await {
            TokenResolution::NoSession | TokenResolution::Rejected => return Ok(None),
            TokenResolution::Unavailable(failure) => return Err(refresh_failure_error(failure)),
            TokenResolution::Valid(_) | TokenResolution::Fallback { .. } => {}
        }
        let answer = self.call(Method::GET, "/users/me", None, Some(session)).await?;
        let user =
            answer.json().filter(Value::is_object).ok_or(StackError::Parse("the user answer"))?;
        if flag(&user, "is_anonymous") || flag(&user, "is_restricted") {
            return Ok(None);
        }
        Ok(Some(CurrentUser {
            id: text(&user, "id").unwrap_or_default(),
            primary_email: text(&user, "primary_email"),
            display_name: text(&user, "display_name"),
            profile_image_url: text(&user, "profile_image_url"),
            demonstration_content_enabled: user
                .get("client_read_only_metadata")
                .and_then(|m| m.get("cmuxReviewDemoContent"))
                == Some(&Value::Bool(true)),
            selected_team_id: user.get("selected_team").and_then(|t| text(t, "id")),
        }))
    }

    /// The user's Stack teams (`GET /teams?user_id=me`), VM personal tenants left out. An answer
    /// with no `items` is an error, not an empty list, so a dropped read never records a
    /// signed-in account as having no teams.
    pub async fn list_teams(&self, session: &mut Session) -> Result<Vec<Team>, StackError> {
        self.authorize(session).await?;
        let answer = self.call(Method::GET, "/teams?user_id=me", None, Some(session)).await?;
        let json = answer.json();
        let items = json
            .as_ref()
            .and_then(|v| v.get("items")?.as_array())
            .ok_or(StackError::Parse("the team list answer"))?;
        Ok(items.iter().filter(|item| !is_vm_personal_tenant(item)).map(Team::from_json).collect())
    }

    /// Stack's cross-device selected team, or `None` when signed out or none is selected.
    pub async fn selected_team_id(
        &self,
        session: &mut Session,
    ) -> Result<Option<String>, StackError> {
        Ok(self.current_user(session).await?.and_then(|user| user.selected_team_id))
    }

    /// Selects a team for the account (`PATCH /users/me` `selected_team_id`); `None` clears it.
    pub async fn set_selected_team(
        &self,
        session: &mut Session,
        team_id: Option<&str>,
    ) -> Result<(), StackError> {
        self.authorize(session).await?;
        let body = json!({ "selected_team_id": team_id });
        self.call(Method::PATCH, "/users/me", Some(&body), Some(session)).await?;
        Ok(())
    }

    /// Creates a team with the user as its creator (`POST /teams`) and selects it, as the SDK's
    /// `createTeam` does.
    pub async fn create_team(
        &self,
        session: &mut Session,
        display_name: &str,
    ) -> Result<Team, StackError> {
        self.authorize(session).await?;
        let body = json!({ "display_name": display_name, "creator_user_id": "me" });
        let answer = self.call(Method::POST, "/teams", Some(&body), Some(session)).await?;
        let team =
            answer.json().filter(Value::is_object).ok_or(StackError::Parse("the team answer"))?;
        let team = Team::from_json(&team);
        self.set_selected_team(session, Some(&team.id)).await?;
        Ok(team)
    }

    /// Revokes the server session `session` authenticates (`DELETE /auth/sessions/current`),
    /// for a sign-out that already cleared the store. Works on a copy: a refresh on the way is
    /// never written back.
    pub async fn revoke_session(&self, session: &Session) -> Result<(), StackError> {
        if session.access_token.is_none() && session.refresh_token.is_none() {
            return Ok(());
        }
        let mut copy = session.clone();
        self.call(Method::DELETE, "/auth/sessions/current", None, Some(&mut copy)).await?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "calls_tests.rs"]
mod tests;

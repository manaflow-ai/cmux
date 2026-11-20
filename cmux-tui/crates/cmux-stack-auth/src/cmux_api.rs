//! The cmux backend's account calls beside Stack: account deletion (AccountDeletionClient.swift),
//! the email-verification and billing recovery posts (EmailVerificationRecoveryClient.swift), and
//! the team list with roles (CmuxTeamsAPI.swift `memberships`). Authenticated calls carry the
//! native session pair: `Authorization: Bearer <access>` and `X-Stack-Refresh-Token: <refresh>`.

use reqwest::header::ACCEPT;
use reqwest::{Method, Url};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::client::{NoAnswer, exchange};
use crate::config::CmuxApiConfig;
use crate::error::StackError;
use crate::wire::{Session, http_client};

/// What `DELETE /api/account` did when the backend accepted it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountDeletionResult {
    /// Stack and cmux cleanup completed.
    Completed,
    /// The Stack account is gone, but the backend said cmux follow-up cleanup needs support.
    CompletedWithIncompleteServerCleanup,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountDeletionError {
    /// The configured base URL cannot make the deletion URL.
    InvalidApiBaseUrl,
    /// The backend rejected the access or refresh token.
    Unauthorized,
    /// cmux data was deleted, but the Stack account deletion did not finish: retry.
    StackDeleteIncomplete,
    /// No answer by the deadline.
    TimedOut,
    /// The request may have reached the backend, and no definite result came back.
    CompletionUnknown,
    /// The request failed locally before it could plausibly reach the backend.
    LocalTransportFailure,
    /// A definite refusal.
    Rejected { status: u16 },
}

/// Failures of the email-verification and billing recovery posts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryError {
    InvalidApiBaseUrl,
    RateLimited,
    Unavailable,
}

/// The user's role in a team, as `/api/teams` reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TeamRole {
    Admin,
    Member,
}

impl TeamRole {
    fn parse(raw: Option<&str>) -> Option<Self> {
        match raw? {
            "admin" => Some(TeamRole::Admin),
            "member" => Some(TeamRole::Member),
            _ => None,
        }
    }
}

/// What the user may do in a team. A permission the server does not send is not granted.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TeamPermissions {
    pub update_team: bool,
    pub delete_team: bool,
    pub invite_members: bool,
    pub read_members: bool,
    pub remove_members: bool,
    pub manage_api_keys: bool,
    pub manage_billing: bool,
}

/// One team of the user with the user's role in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TeamMembership {
    pub id: String,
    pub display_name: String,
    pub profile_image_url: Option<String>,
    /// `None` for a role this client does not know.
    pub role: Option<TeamRole>,
    pub permissions: TeamPermissions,
}

/// The user's teams with roles, and the account's selected team.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TeamMemberships {
    pub teams: Vec<TeamMembership>,
    pub selected_team_id: Option<String>,
}

/// A cmux team API failure (CMUXTeamError).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TeamError {
    Forbidden,
    SubscriptionActive,
    NotFound,
    InvalidName,
    SignedOut,
    Busy,
    /// A rate limit, a network failure, or an answer this client cannot read.
    Unavailable,
    InvitationInvalid,
    EmailMismatch,
    SeatLimit,
}

impl TeamError {
    /// By the body's `error.code`, else by the status.
    pub fn from_status(status: u16, code: Option<&str>) -> Self {
        match code {
            Some("team_has_active_subscription") => TeamError::SubscriptionActive,
            Some("team_not_found") => TeamError::NotFound,
            Some("forbidden" | "last_admin") => TeamError::Forbidden,
            Some("invalid_request") => TeamError::InvalidName,
            Some("unauthorized") => TeamError::SignedOut,
            Some("invitation_invalid" | "invitation_not_found") => TeamError::InvitationInvalid,
            Some("email_mismatch") => TeamError::EmailMismatch,
            Some("seat_limit") => TeamError::SeatLimit,
            _ => match status {
                401 => TeamError::SignedOut,
                403 => TeamError::Forbidden,
                404 => TeamError::NotFound,
                _ => TeamError::Unavailable,
            },
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TeamListReply {
    teams: Vec<TeamListEntry>,
    selected_team_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TeamListEntry {
    id: String,
    display_name: String,
    profile_image_url: Option<String>,
    role: Option<String>,
    permissions: Option<TeamPermissions>,
}

/// The cmux backend's client.
pub struct CmuxApi {
    config: CmuxApiConfig,
    http: reqwest::Client,
}

impl CmuxApi {
    pub fn new(config: CmuxApiConfig) -> Result<Self, StackError> {
        Ok(CmuxApi { config, http: http_client().map_err(StackError::Client)? })
    }

    fn url(&self, path: &str) -> Option<Url> {
        Url::parse(&format!("{}{path}", self.config.base_url)).ok()
    }

    /// Deletes the account (`DELETE /api/account`).
    pub async fn delete_account(
        &self,
        access_token: &str,
        refresh_token: &str,
    ) -> Result<AccountDeletionResult, AccountDeletionError> {
        let url = self.url("/api/account").ok_or(AccountDeletionError::InvalidApiBaseUrl)?;
        let request = self
            .http
            .request(Method::DELETE, url)
            .timeout(self.config.request_timeout)
            .bearer_auth(access_token)
            .header("X-Stack-Refresh-Token", refresh_token);
        let answer = match exchange(request, self.config.request_timeout).await {
            Ok(answer) => answer,
            Err(NoAnswer::TimedOut) => return Err(AccountDeletionError::TimedOut),
            // Connect, DNS and TLS failures never reached the backend.
            Err(NoAnswer::Connect) => return Err(AccountDeletionError::LocalTransportFailure),
            Err(NoAnswer::Failed(_)) => return Err(AccountDeletionError::CompletionUnknown),
        };
        let json = answer.json();
        match answer.status {
            200..=299 => {
                let Some(object) = json.as_ref().filter(|v| v.is_object()) else {
                    return Ok(AccountDeletionResult::Completed);
                };
                if object.get("deletionPending") == Some(&Value::Bool(true)) {
                    return Err(AccountDeletionError::CompletionUnknown);
                }
                if object.get("cleanupIncomplete") == Some(&Value::Bool(true)) {
                    return Ok(AccountDeletionResult::CompletedWithIncompleteServerCleanup);
                }
                Ok(AccountDeletionResult::Completed)
            }
            401 => Err(AccountDeletionError::Unauthorized),
            status => {
                let code = json.as_ref().and_then(|v| v.get("error")?.as_str());
                Err(match code {
                    Some(
                        "account_delete_retryable"
                        | "account_stack_delete_failed_after_data_delete",
                    ) => AccountDeletionError::StackDeleteIncomplete,
                    Some("account_delete_failed") => AccountDeletionError::Rejected { status },
                    _ if status == 408 || status >= 500 => AccountDeletionError::CompletionUnknown,
                    _ => AccountDeletionError::Rejected { status },
                })
            }
        }
    }

    /// Asks Stack, through cmux, to send a contact-channel verification
    /// (`POST /api/auth/email-verification`).
    pub async fn request_email_verification(&self, email: &str) -> Result<(), RecoveryError> {
        self.recovery("/api/auth/email-verification", email).await
    }

    /// Asks the billing recovery endpoint to provision a paid account when there is one and send
    /// a sign-in code (`POST /api/billing/recover`). Paid and unpaid addresses get the same answer.
    pub async fn request_billing_recovery(&self, email: &str) -> Result<(), RecoveryError> {
        self.recovery("/api/billing/recover", email).await
    }

    async fn recovery(&self, path: &str, email: &str) -> Result<(), RecoveryError> {
        let url = self.url(path).ok_or(RecoveryError::InvalidApiBaseUrl)?;
        let body = json!({ "email": email.trim().to_lowercase() });
        let request = self.http.post(url).timeout(self.config.request_timeout).json(&body);
        let answer = exchange(request, self.config.request_timeout)
            .await
            .map_err(|_| RecoveryError::Unavailable)?;
        match answer.status {
            200..=299 => Ok(()),
            429 => Err(RecoveryError::RateLimited),
            _ => Err(RecoveryError::Unavailable),
        }
    }

    /// The user's teams with roles and permissions (`GET /api/teams`).
    pub async fn team_memberships(&self, session: &Session) -> Result<TeamMemberships, TeamError> {
        let (Some(access), Some(refresh)) = (&session.access_token, &session.refresh_token) else {
            return Err(TeamError::SignedOut);
        };
        let url = self.url("/api/teams").ok_or(TeamError::Unavailable)?;
        let request = self
            .http
            .get(url)
            .timeout(self.config.request_timeout)
            .header(ACCEPT, "application/json")
            .bearer_auth(access)
            .header("X-Stack-Refresh-Token", refresh);
        let answer = exchange(request, self.config.request_timeout)
            .await
            .map_err(|_| TeamError::Unavailable)?;
        if !(200..300).contains(&answer.status) {
            let json = answer.json();
            let code = json.as_ref().and_then(|v| v.get("error")?.get("code")?.as_str());
            return Err(TeamError::from_status(answer.status, code));
        }
        let reply: TeamListReply =
            serde_json::from_slice(&answer.body).map_err(|_| TeamError::Unavailable)?;
        Ok(TeamMemberships {
            teams: reply
                .teams
                .into_iter()
                .map(|team| TeamMembership {
                    role: TeamRole::parse(team.role.as_deref()),
                    permissions: team.permissions.unwrap_or_default(),
                    id: team.id,
                    display_name: team.display_name,
                    profile_image_url: team.profile_image_url,
                })
                .collect(),
            selected_team_id: reply.selected_team_id,
        })
    }
}

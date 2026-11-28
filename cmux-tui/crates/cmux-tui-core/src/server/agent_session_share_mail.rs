//! The mail an invite-chat sends the person it invites ("X shared a chat with you", with the chat's
//! invite link), the way a shared doc mails its new reader. Off unless `CMUX_SHARE_INVITE_MAIL` is
//! `1`: the daemon decides here whether a mail is due, and the owner's cmux API (the one the share
//! room takes, `platform::share_owner_api`) only delivers it, with the owner's token, through the
//! Home invites sender (`backend/apps/api/src/share-invite-mail.ts`).
//!
//! A mail is due only for an email account that no live share of the chat invites yet: an
//! `@handle` has no address here, and a repeat invite or a role change mails nobody again. When a
//! mail is due and the call carries no owner token, the invite is refused with
//! `share.needs_sign_in` before anything changes, so the app mints the token and asks again, as it
//! does for a new share. Nothing here logs the token, the address or the link.

use super::*;
use zeroize::Zeroizing;

/// The switch: the mail goes only when this is `1` (or `on`, `true`).
pub(super) const FLAG: &str = "CMUX_SHARE_INVITE_MAIL";
/// The owner API's route that delivers the mail.
pub(super) const PATH: &str = "/v1/share-invites/mail";
const TIMEOUT: Duration = Duration::from_secs(10);

/// Whether the switch is on.
pub(super) fn enabled() -> bool {
    switch_on(std::env::var(FLAG).ok().as_deref())
}

fn switch_on(value: Option<&str>) -> bool {
    matches!(value.map(str::trim), Some("1" | "on" | "true"))
}

/// What an invite-chat does about the mail.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Due {
    /// No mail: the switch is off, the account has no address, it was invited already, or no
    /// owner API delivers for this room.
    Skip,
    /// A mail is due but the call has no owner token: refuse with `share.needs_sign_in`.
    NeedsToken,
    /// Send it once the invite holds.
    Send,
}

/// The decision, from what the daemon knows before the invite changes anything.
pub(super) fn decide(
    enabled: bool,
    account: &str,
    already_invited: bool,
    owner_api: Option<&str>,
    has_token: bool,
) -> Due {
    let email = !account.starts_with('@') && account.contains('@');
    if !enabled || !email || already_invited || owner_api.is_none() {
        Due::Skip
    } else if !has_token {
        Due::NeedsToken
    } else {
        Due::Send
    }
}

/// Whether any live share of `session` invites `account` now.
pub(super) fn already_invited(all: &[LinkShare], session: &str, account: &str) -> bool {
    all.iter()
        .filter(|s| s.session == session && s.live().is_ok())
        .any(|s| s.invitees.iter().any(|i| i.account == account && i.state == InviteState::Invited))
}

/// The owner token a mail would spend: a copy of the call's, checked as a new share's is, and
/// only taken when the switch is on.
pub(super) fn token(enabled: bool, owner_token: Option<&String>) -> Option<Zeroizing<String>> {
    if !enabled {
        return None;
    }
    owner_token.filter(|t| !t.is_empty() && t.len() <= 8192).map(|t| Zeroizing::new(t.clone()))
}

/// Asks `api` to mail `to` the invite link, without waiting; a failure is logged by status only.
pub(super) fn send(
    shares: &LinkShares,
    api: &'static str,
    token: Zeroizing<String>,
    to: String,
    invite_url: String,
    role: Role,
) -> bool {
    let Some(runtime) = shares.bridge.runtime() else { return false };
    let url = format!("{api}{PATH}");
    let body = json!({"to": to, "invite_url": invite_url, "role": role});
    runtime.spawn(async move {
        match room::call(reqwest::Method::POST, &url, &token, Some(&body), TIMEOUT).await {
            Some((status, _)) if (200..300).contains(&status) => {}
            Some((status, _)) => eprintln!("cmux-tui: share invite mail refused ({status})"),
            None => eprintln!("cmux-tui: share invite mail did not reach the owner API"),
        }
    });
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const API: Option<&str> = Some("https://cloud-api-staging.cmux.dev");

    #[test]
    fn share_mail_is_off_by_default() {
        assert!(!switch_on(None));
        assert!(!switch_on(Some("")));
        assert!(!switch_on(Some("0")));
        assert!(!switch_on(Some("off")));
        assert!(switch_on(Some("1")));
        assert!(switch_on(Some("on")));
        assert_eq!(decide(false, "a@b.co", false, API, true), Due::Skip);
        assert!(token(false, Some(&"t".to_owned())).is_none());
    }

    #[test]
    fn share_mail_skips_a_handle() {
        assert_eq!(decide(true, "@lawrence", false, API, true), Due::Skip);
        assert_eq!(decide(true, "@lawrence", false, API, false), Due::Skip);
    }

    #[test]
    fn share_mail_skips_a_repeat_or_role_change() {
        assert_eq!(decide(true, "a@b.co", true, API, true), Due::Skip);
        assert_eq!(decide(true, "a@b.co", true, API, false), Due::Skip);
    }

    #[test]
    fn share_mail_skips_a_room_without_an_owner_api() {
        assert_eq!(decide(true, "a@b.co", false, None, true), Due::Skip);
    }

    #[test]
    fn share_mail_goes_to_a_new_email() {
        assert_eq!(decide(true, "a@b.co", false, API, true), Due::Send);
        assert_eq!(decide(true, "a@b.co", false, API, false), Due::NeedsToken);
    }

    #[test]
    fn share_mail_token_is_checked_like_a_new_shares() {
        assert!(token(true, None).is_none());
        assert!(token(true, Some(&String::new())).is_none());
        assert!(token(true, Some(&"x".repeat(8193))).is_none());
        assert_eq!(token(true, Some(&"t".to_owned())).as_deref().map(String::as_str), Some("t"));
    }
}

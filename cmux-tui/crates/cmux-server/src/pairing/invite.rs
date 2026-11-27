//! Invite codes for the reverse pairing flow: a signed-in device shows the
//! code (`server.pair.invite`), this machine types it (`cmux pair CODE`,
//! `cmux server pair --invite CODE`) and begins with it. 10 Crockford base32
//! symbols (50 bits), shown `ABCDE-12345`, read like a pairing code
//! (case-insensitive, `O` for `0`, `I`/`L` for `1`, dashes and spaces
//! dropped). The length tells an invite from an 8-symbol pairing code.

use cmux_server_core::pairing::{ALPHABET, decode_symbol};

use crate::error::{Error, Result};

pub const INVITE_LEN: usize = 10;

/// The begin route's 404 for an invite: unknown, or past its ten minutes.
pub const UNKNOWN: &str = "server.pair.invite_unknown";
/// The begin route's 409: redeemed by another machine, replaced by a newer
/// invite, or already paired.
pub const USED: &str = "server.pair.invite_used";
/// The wait was refused after an invite begin: the invite was voided.
pub const VOIDED: &str = "server.pair.invite_voided";

/// The canonical form (`ABCDE12345`), or a usage error.
pub fn normalize(input: &str) -> Result<String> {
    let invalid = || Error::usage("server.pair.invalid_invite");
    if input.len() > 64 {
        return Err(invalid());
    }
    let mut out = String::with_capacity(INVITE_LEN);
    for c in input.chars() {
        if c == '-' || c.is_whitespace() {
            continue;
        }
        let upper = c.to_ascii_uppercase();
        if upper == 'U' {
            return Err(invalid());
        }
        let symbol = decode_symbol(upper).ok_or_else(invalid)?;
        out.push(char::from(ALPHABET[usize::from(symbol)]));
    }
    if out.len() == INVITE_LEN { Ok(out) } else { Err(invalid()) }
}

/// `ABCDE-12345`.
pub fn display(canonical: &str) -> String {
    let (head, tail) = canonical.split_at_checked(5).unwrap_or_default();
    format!("{head}-{tail}")
}

/// Who the API says must confirm this machine: bounded, printable, or none.
pub(super) fn inviter(response: &serde_json::Value) -> Option<String> {
    let text = response.get("inviter")?.as_str()?.trim();
    (!text.is_empty() && text.chars().count() <= 120 && !text.chars().any(char::is_control))
        .then(|| text.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invite_codes_normalize_like_pairing_codes_and_never_have_a_pairing_code_length() {
        assert_eq!(normalize("abcde-12345").unwrap(), "ABCDE12345");
        assert_eq!(normalize(" ABCDE 1234O ").unwrap(), "ABCDE12340");
        assert_eq!(normalize("abcde-1234l").unwrap(), "ABCDE12341");
        assert_eq!(normalize("abcde-1234i").unwrap(), "ABCDE12341");
        for bad in
            ["7KQ4-M2XD", "ABCDE-1234U", "ABCDE-123456", "ABCDE_12345", "", "A".repeat(65).as_str()]
        {
            let error = normalize(bad).unwrap_err();
            assert_eq!(error.kind, crate::ExitKind::Usage, "{bad}");
            assert_eq!(error.message, "server.pair.invalid_invite");
        }
        assert_eq!(display("ABCDE12345"), "ABCDE-12345");
    }

    #[test]
    fn begin_refusals_for_an_invite_are_named_and_others_stay_generic() {
        use reqwest::StatusCode;
        assert_eq!(super::super::network::invite_refusal(StatusCode::NOT_FOUND), UNKNOWN);
        assert_eq!(super::super::network::invite_refusal(StatusCode::CONFLICT), USED);
        assert_eq!(
            super::super::network::invite_refusal(StatusCode::BAD_REQUEST),
            "server.pair.api_refused"
        );
    }

    #[test]
    fn the_inviter_shown_is_bounded_and_printable() {
        use serde_json::json;
        assert_eq!(inviter(&json!({"inviter":" Leo "})).as_deref(), Some("Leo"));
        assert_eq!(inviter(&json!({"inviter":"a\u{1b}[31mb"})), None);
        assert_eq!(inviter(&json!({"inviter":"x".repeat(121)})), None);
        assert_eq!(inviter(&json!({"inviter":null})), None);
        assert_eq!(inviter(&json!({})), None);
    }
}

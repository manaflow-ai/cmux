//! Where a `cmux machine` verb's credential comes from: a flag or variable, else the signed-in
//! app's session (or, for a plain `machine add`, the app's Add Machine card).

use std::io::BufRead;

use super::{Auth, Command, Failure, SIGN_IN, Verb};

/// A signed-in app that could not hand over its session (none answers, or it is signed out).
const APP_SIGN_IN: &str = "sign in to the cmux app (cmux login), or pass --cloud-token-file PATH (or set CMUX_CLOUD_ACCESS_TOKEN)";

/// Where a verb's sign-in comes from when no flag or variable names a credential.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum NoCredential {
    /// A plain `machine add`: the app's Add Machine card, as before joining existed.
    Card,
    /// The signed-in app's session (`auth.token`): no token passes through the caller.
    AppSession,
}

impl Command {
    /// What a run with no credential does: the card for a plain `machine add` (unless it asks for
    /// `--app-session`), the app's session for every other verb.
    pub(super) fn without_credential(&self) -> NoCredential {
        match &self.verb {
            Verb::Add(add) if add.plain() && !self.auth.app_session => NoCredential::Card,
            _ => NoCredential::AppSession,
        }
    }
}

/// A signed-in run's token, the team it is for and the API origin it came from.
type SignedIn = (String, Option<String>, Option<String>);

/// The credential a run signs in with: the one a flag or variable names; else, with none, the
/// app's Add Machine card for a plain `machine add` (`Err(Ok(exit code))`) or the app's session.
/// Returns the token, the team it is for and the API origin it came from.
pub(super) fn sign_in(
    command: &Command,
    env: &dyn Fn(&str) -> Option<String>,
    args: &[String],
) -> Result<SignedIn, Result<i32, Failure>> {
    let given = if command.auth.app_session {
        Ok(None)
    } else {
        read_credential(&command.auth, env, &mut std::io::stdin().lock())
    };
    match given {
        Ok(Some(credential)) => Ok((credential, None, None)),
        Ok(None) => match command.without_credential() {
            // With no credential, `machine add` stays the app's Add Machine card wherever an
            // app answers, as it was before joining existed.
            NoCredential::Card => match crate::cli::app_commands::run_app_action_fallback(args) {
                Some(code) => Err(Ok(code)),
                None => Err(Err(Failure::usage(SIGN_IN))),
            },
            NoCredential::AppSession => app_session().map_err(Err),
        },
        Err(message) => Err(Err(Failure::usage(message))),
    }
}

/// The app's own session, minted for its current team the way `cmux auth token` asks for one:
/// the token goes from the app's socket straight into the call, never to the caller's terminal,
/// environment or logs. Returns the token, its team and the API origin it came from.
fn app_session() -> Result<SignedIn, Failure> {
    match crate::cli::auth_token::app_token_in(None) {
        Ok(token) => Ok((token.token.to_string(), Some(token.team), Some(token.api_origin))),
        Err(why) => Err(Failure::new(
            "machine_join.signed_out",
            format!("the cmux app gave no session ({why}): {APP_SIGN_IN}"),
        )),
    }
}

/// The caller's cmux credential: stdin, then the file, then the environment.
/// `None` when no way names one. Errors name neither the file's path nor its
/// contents (a pasted secret could be in either).
pub(crate) fn read_credential(
    auth: &Auth,
    env: &dyn Fn(&str) -> Option<String>,
    stdin: &mut dyn BufRead,
) -> Result<Option<String>, String> {
    let raw = if auth.token_stdin {
        let mut line = String::new();
        stdin
            .read_line(&mut line)
            .map_err(|e| format!("the credential on stdin could not be read ({:?})", e.kind()))?;
        line
    } else if let Some(path) = &auth.token_file {
        std::fs::read_to_string(path)
            .map_err(|e| format!("the --cloud-token-file could not be read ({:?})", e.kind()))?
    } else {
        // `CMUX_CLOUD_ACCESS_TOKEN`, else an API token in `CMUX_TOKEN` (api_tokens.rs).
        return Ok(crate::cli::api_tokens::env_credential(env));
    };
    let credential = raw.trim().to_owned();
    if credential.is_empty() {
        return Err("the cmux credential is empty".into());
    }
    Ok(Some(credential))
}

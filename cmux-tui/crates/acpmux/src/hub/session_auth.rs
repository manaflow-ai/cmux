//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/session/auth` (Leo: "you gotta re-authenticate.
//! You gotta log in again on the modal picker before the user even sends a prompt."): what this
//! daemon knows of a chat's sign-in, from evidence in this order, the first that says something
//! answering:
//!
//! 1. The chat's newest turn ([`turn_evidence`]): a sign-in failure (`auth.signed_out`,
//!    `auth.expired`) or a completed turn.
//! 2. With `refresh`, the harness's own check that reads no keychain
//!    (`harness_health::fresh_auth`).
//! 3. Else `unknown`, never signed out. A connection error is never a sign-in state.
//!
//! A peer's chat is answered here from its link (`server/session_auth.rs`): `peerUnreachable`
//! when it is down, else `unknown`. Asking the peer, the route probe and a target (a chat with
//! no session yet) come next; until then `initialize` does not list the feature.
//!
//! Never the saved harness health (checked every six hours), and never the login keychain.

use super::*;

use crate::harness_health::Auth;
use crate::protocol::auth::{
    SessionAuthLogin, SessionAuthLoginKind as LoginKind, SessionAuthResult,
    SessionAuthSource as Source, SessionAuthState as State,
};
use crate::{route_account, routes};

/// A chat's sign-in as one of its turns showed it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TurnEvidence {
    pub state: State,
    pub at: u64,
    pub detail: String,
}

/// What a chat's `lastTurn` says of its sign-in: `ready` when it completed, `signedOut` or
/// `expired` when it failed on its sign-in (its `errorKind`; a turn recorded before the kinds
/// existed, by its error text). A cancelled turn, or one that failed another way (a connection
/// error), says nothing.
pub(crate) fn turn_evidence(last: &Value) -> Option<TurnEvidence> {
    let at = last.get("endedAt").and_then(Value::as_u64)?;
    let text = last.get("errorText").and_then(Value::as_str).unwrap_or_default();
    let state = match last.get("status").and_then(Value::as_str)? {
        "completed" => State::Ready,
        "failed" => {
            let kind = last.get("errorKind").and_then(Value::as_str);
            match kind.or_else(|| crate::recovery::auth_kind(text))? {
                crate::recovery::kind::AUTH_SIGNED_OUT => State::SignedOut,
                crate::recovery::kind::AUTH_EXPIRED => State::Expired,
                _ => return None,
            }
        }
        _ => return None,
    };
    let detail = match state {
        State::Ready => "its last turn completed".to_owned(),
        _ => format!("its last turn failed: {text}"),
    };
    Some(TurnEvidence { state, at, detail })
}

/// The evidence one answer is decided from, in the module's order.
#[derive(Debug, Default)]
pub(crate) struct Facts {
    pub harness: String,
    pub route_id: Option<String>,
    /// The turn and the chat it came from.
    pub turn: Option<(String, TurnEvidence)>,
    /// The harness's own check and when it ran; Err: it could not answer.
    pub check: Option<(u64, Result<(Auth, String), String>)>,
    /// The harness's login command, for `login`.
    pub login: Option<String>,
}

impl Facts {
    /// Whether the evidence before the harness check already answers.
    fn settled(&self) -> bool {
        self.turn.is_some()
    }

    /// The answer: the first evidence that says something, else `unknown`; its `detail` one
    /// sentence ([`one_sentence`]).
    pub(crate) fn decide(self) -> SessionAuthResult {
        let mut out = self.answer();
        out.detail = one_sentence(&out.detail);
        out
    }

    fn answer(self) -> SessionAuthResult {
        let mut out = SessionAuthResult {
            state: State::Unknown,
            source: Source::None,
            evidence_at: None,
            detail: "nothing here shows this chat's sign-in yet".into(),
            harness: self.harness.clone(),
            host: None,
            route_id: self.route_id.clone(),
            login: None,
            from_session_id: None,
        };
        let terminal = |command: &Option<String>| SessionAuthLogin {
            kind: LoginKind::Terminal,
            command: command.clone(),
            host: None,
            route_id: None,
        };
        if let Some((from, turn)) = self.turn {
            out.state = turn.state;
            out.source = Source::Turn;
            out.evidence_at = Some(turn.at);
            out.detail = turn.detail;
            out.from_session_id = Some(from);
            if turn.state != State::Ready {
                out.login = Some(terminal(&self.login));
            }
            return out;
        }
        match self.check {
            Some((at, Ok((auth, detail)))) if auth != Auth::Unknown => {
                out.state = match auth {
                    Auth::SignedIn => State::Ready,
                    Auth::Expired => State::Expired,
                    _ => State::SignedOut,
                };
                out.source = Source::AuthCheck;
                out.evidence_at = Some(at);
                out.detail = detail;
                if out.state != State::Ready {
                    out.login = Some(terminal(&self.login));
                }
            }
            Some((_, Err(why))) => out.detail = format!("the harness's sign-in is unknown: {why}"),
            _ => {}
        }
        out
    }
}

/// `text` as the one sentence a reply's `detail` is: its words on one line, up to the end of
/// its first sentence, at most [`DETAIL_CHARS`] characters. An agent's error text may run to
/// many lines.
pub(crate) fn one_sentence(text: &str) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    // A sentence ends at `.`, `!` or `?` before a space, but not after an abbreviation
    // ("e.g.", "etc.") or a word of one or two letters ("a.", "no.").
    // A closing quote or bracket right after the mark ends with it ("expired." Please).
    let closers = ['"', '\'', '\u{201d}', '\u{2019}', ')', ']'];
    let end = flat.match_indices(['.', '!', '?']).map(|(i, _)| i + 1).find_map(|i| {
        let word = flat[..i].rsplit(' ').next().unwrap_or_default().to_lowercase();
        let word = word.trim_start_matches(|c: char| !c.is_alphanumeric());
        let short = word.chars().count() <= 2;
        let rest = flat[i..].trim_start_matches(closers);
        let end = flat.len() - rest.len();
        (rest.starts_with(' ')
            && !short
            && !["e.g.", "i.e.", "etc.", "vs.", "cf.", "approx."].contains(&word))
        .then_some(end)
    });
    let sentence = end.map_or(flat.as_str(), |i| &flat[..i]);
    if sentence.chars().count() <= DETAIL_CHARS {
        return sentence.to_owned();
    }
    let cut: String = sentence.chars().take(DETAIL_CHARS - 1).collect();
    format!("{}…", cut.trim_end())
}

/// The longest `detail`, in characters.
const DETAIL_CHARS: usize = 200;

/// `VAR=<home> <command>` when the chat runs in an account home of its own.
fn login_command(command: Option<String>, home: Option<(&str, &Path)>) -> Option<String> {
    let command = command?;
    let Some((var, home)) = home else { return Some(command) };
    let home = home.display().to_string();
    let safe = home.chars().all(|c| c.is_ascii_alphanumeric() || "/._-~".contains(c));
    let home = if safe { home } else { format!("'{}'", home.replace('\'', r"'\''")) };
    Some(format!("{var}={home} {command}"))
}

impl Hub {
    /// `_acpmux/session/auth` for this daemon's chat `session`. `refresh`: run the harness's own
    /// check when its turns say nothing.
    pub(crate) async fn session_auth(
        self: &Arc<Self>,
        session: &Arc<Session>,
        refresh: bool,
    ) -> Result<SessionAuthResult, RpcError> {
        // A chat whose log is not read yet (a deferred start) has only its summary.
        self.session_log(session).await;
        let meta = session.meta();
        let harness = meta.harness.clone();
        let cfg = self.config.read().await;
        let profile = cfg.harnesses.get(&harness).cloned();
        let notes = cfg.profile_meta.get(&harness).and_then(|m| m.auth.clone());
        let (dir, state) = routes::places(&cfg);
        drop(cfg);
        let family = profile
            .as_ref()
            .map(|p| crate::config::derive_family(&harness, p))
            .unwrap_or_else(|| harness.clone());
        let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
        let route_id = routes::bound_route(&routes::bindings(&state), &meta.id, workspace, &family)
            .map(|(id, _)| id);
        let route = route_id.as_ref().and_then(|id| routes::find(dir.as_deref(), id).ok());
        let home = self.home_of(&meta, &family, route.as_ref()).await;
        let var = route_account::home_var(&family);
        let mut facts = Facts {
            harness: harness.clone(),
            route_id,
            login: login_command(
                notes
                    .as_ref()
                    .and_then(|n| n.login.clone())
                    .or_else(|| crate::harness_health::builtin_login(&family).map(str::to_owned)),
                var.zip(home.as_deref()),
            ),
            turn: meta.last_turn.as_ref().and_then(turn_evidence).map(|t| (session.id.clone(), t)),
            ..Facts::default()
        };
        if !facts.settled()
            && refresh
            && let Some(mut profile) = profile
        {
            // The chat's own env (its preset's and its chat store's over the profile's), as
            // its harness runs.
            profile.env = self.harness_env(&meta).await.1;
            if let (Some(var), Some(home)) = (var, &home) {
                profile.env.insert(var.to_owned(), home.display().to_string());
            }
            let check = tokio::task::spawn_blocking(move || {
                crate::harness_health::fresh_auth(&harness, &profile, notes.as_ref())
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()));
            facts.check = Some((now_ms(), check));
        }
        Ok(facts.decide())
    }

    /// The account home `meta`'s chat runs in when it is not the CLI's default: its recorded
    /// store or its env's, else the route's for a chat that has not started.
    async fn home_of(
        &self,
        meta: &SessionMeta,
        family: &str,
        route: Option<&routes::Route>,
    ) -> Option<PathBuf> {
        let (_, env) = self.harness_env(meta).await;
        route_account::current_home(meta, family, &env).or_else(|| {
            let route_home = route.and_then(|r| r.file.account_home.as_ref());
            route_home.filter(|_| !route_account::has_home(meta)).map(PathBuf::from)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(status: &str, kind: Option<&str>, text: &str, at: u64) -> Value {
        json!({"status": status, "errorKind": kind, "errorText": text, "endedAt": at})
    }

    fn facts(last: Option<Value>, check: Option<Result<Auth, &str>>) -> Facts {
        Facts {
            harness: "claude".into(),
            route_id: None,
            turn: last.as_ref().and_then(turn_evidence).map(|t| ("chat-1".into(), t)),
            check: check.map(|c| (9, c.map(|a| (a, "`check` ran".into())).map_err(str::to_owned))),
            login: Some("claude auth login".into()),
        }
    }

    /// Each state from the evidence that gives it, with its source and when it was seen.
    #[test]
    fn each_state_comes_from_its_evidence() {
        let signed_out = turn("failed", Some("auth.signed_out"), "Not logged in", 7);
        let expired = turn("failed", Some("auth.expired"), "OAuth token has expired", 7);
        for (f, state, source, at) in [
            (
                facts(Some(turn("completed", None, "", 7)), None),
                State::Ready,
                Source::Turn,
                Some(7),
            ),
            (facts(Some(signed_out), None), State::SignedOut, Source::Turn, Some(7)),
            (facts(Some(expired), None), State::Expired, Source::Turn, Some(7)),
            (facts(None, Some(Ok(Auth::Expired))), State::Expired, Source::AuthCheck, Some(9)),
            (facts(None, Some(Ok(Auth::SignedOut))), State::SignedOut, Source::AuthCheck, Some(9)),
            (facts(None, Some(Ok(Auth::SignedIn))), State::Ready, Source::AuthCheck, Some(9)),
            (facts(None, None), State::Unknown, Source::None, None),
        ] {
            let out = f.decide();
            assert_eq!((out.state, out.source, out.evidence_at), (state, source, at), "{out:?}");
            let blocks = matches!(state, State::SignedOut | State::Expired);
            assert_eq!(out.login.is_some(), blocks, "{out:?}");
        }
    }

    /// No evidence, a check that could not answer, a connection error or a cancel: unknown,
    /// never signed out.
    #[test]
    fn no_evidence_and_transport_errors_are_unknown() {
        for last in [
            turn("failed", None, "API Error: Connection error.", 7),
            turn("failed", Some("agent.exited"), "agent process closed", 7),
            turn("cancelled", None, "", 7),
        ] {
            assert_eq!(turn_evidence(&last), None, "{last}");
            assert_eq!(facts(Some(last), None).decide().state, State::Unknown);
        }
        let out = facts(None, Some(Err("Claude Code may keep its login in its keychain"))).decide();
        assert_eq!((out.state, out.source, out.evidence_at), (State::Unknown, Source::None, None));
        assert!(out.detail.contains("keychain"), "{out:?}");
        // A turn recorded before the auth kinds is read by its text.
        let old = turn("failed", None, "Not logged in · Please run /login", 7);
        assert_eq!(turn_evidence(&old).map(|t| t.state), Some(State::SignedOut));
    }

    /// An agent's error of many lines and sentences is one sentence in `detail`.
    #[test]
    fn a_detail_is_one_sentence() {
        let text = "API Error: 401 OAuth token has expired. Please run /login\n\nat step 2";
        let out = facts(Some(turn("failed", Some("auth.expired"), text, 7)), None).decide();
        assert_eq!(out.detail, "its last turn failed: API Error: 401 OAuth token has expired.");
        assert_eq!(
            one_sentence("not logged in\nrun claude auth login"),
            "not logged in run claude auth login"
        );
        assert_eq!(one_sentence("see e.g. the docs"), "see e.g. the docs");
        assert_eq!(one_sentence("not logged in. run /login"), "not logged in.");
        assert_eq!(
            one_sentence("Claude said: \"OAuth token expired.\" Please run /login"),
            "Claude said: \"OAuth token expired.\""
        );
        assert_eq!(one_sentence("Error! try again"), "Error!");
        assert_eq!(one_sentence("use v2.1 i.e. the new one"), "use v2.1 i.e. the new one");
        let long = one_sentence(&"word ".repeat(100));
        assert!(long.chars().count() <= DETAIL_CHARS && long.ends_with('…'), "{long}");
    }

    #[test]
    fn a_chat_in_its_own_account_home_signs_in_there() {
        let home = Path::new("/Users/me/claude two");
        assert_eq!(
            login_command(Some("claude auth login".into()), Some(("CLAUDE_CONFIG_DIR", home))),
            Some("CLAUDE_CONFIG_DIR='/Users/me/claude two' claude auth login".into())
        );
        assert_eq!(login_command(Some("codex login".into()), None), Some("codex login".into()));
    }
}

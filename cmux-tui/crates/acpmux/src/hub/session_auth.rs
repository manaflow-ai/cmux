//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/session/auth` (Leo: "you gotta re-authenticate.
//! You gotta log in again on the modal picker before the user even sends a prompt."): what this
//! daemon knows of a chat's sign-in, from evidence in this order, the first that says something
//! answering:
//!
//! 1. The peer link (`server/session_auth.rs`): a peer's chat whose link is down is
//!    `peerUnreachable`.
//! 2. The chat's bound route: with `refresh` a new probe (never of a route whose secret is in
//!    the keychain), else its last answer at most [`PROBE_FRESH_MS`] old (`route_probe.rs`).
//!    `auth_needed` is `routeAuthNeeded`, `unreachable` `routeUnreachable`; `rate_limited` and
//!    `unknown` say nothing about the sign-in and fall through.
//! 3. The chat's newest turn ([`turn_evidence`]): a sign-in failure (`auth.signed_out`,
//!    `auth.expired`) or a completed turn. A target (a chat with no session yet) takes the
//!    newest such turn of a chat here with the same harness, project directory, account home and route.
//! 4. With `refresh`, the harness's own check that reads no keychain
//!    (`harness_health::fresh_auth_in`).
//! 5. Else `unknown`, never signed out. A connection error is never a sign-in state.
//!
//! Never the saved harness health (checked every six hours), and never the login keychain.

use super::*;

use crate::harness_health::Auth;
use crate::protocol::auth::{
    SessionAuthLogin, SessionAuthLoginKind as LoginKind, SessionAuthResult,
    SessionAuthSource as Source, SessionAuthState as State, SessionAuthTarget,
};
use crate::{route_account, routes};
use std::collections::BTreeMap;

/// Listed in `initialize`'s features: this daemon answers `_acpmux/session/auth`.
pub(crate) const FEATURE: &str = "sessionAuth";
/// A route probe answer younger than this is reused (as long as `route_probe.rs` keeps one).
pub(crate) const PROBE_FRESH_MS: u64 = crate::route_probe::KEPT_MS;

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

fn session_evidence(meta: &SessionMeta) -> Option<TurnEvidence> {
    let last = meta.last_turn.as_ref();
    if let Some(change) = &meta.auth_change
        && last.and_then(|v| v.get("turnId")).and_then(Value::as_str) == change.turn_id.as_deref()
        && last.and_then(|v| v.get("endedAt")).and_then(Value::as_u64) == change.ended_at
    {
        return Some(TurnEvidence {
            state: State::Unknown,
            at: change.at,
            detail: "credentials changed; the next turn will check the new sign-in".into(),
        });
    }
    last.and_then(turn_evidence)
}

/// Terminal logins do not call agent_login/finish. A dedicated credential file written after
/// the failed turn is evidence of a replacement, never evidence that the replacement works.
/// Read metadata only; settings files and the keychain are deliberately not probed here.
fn credential_file_changed(
    family: &str,
    env: &BTreeMap<String, String>,
    home: Option<&Path>,
    after: u64,
) -> Option<u64> {
    let file = match family {
        "claude" => ".credentials.json",
        "codex" => "auth.json",
        _ => return None,
    };
    let home = home.map(PathBuf::from).or_else(|| account_home(family, env))?;
    let modified = std::fs::metadata(home.join(file))
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_millis();
    let modified = u64::try_from(modified).ok()?;
    // A future timestamp is not evidence of a login since this turn.
    (modified > after && modified <= now_ms()).then_some(modified)
}

fn account_home(family: &str, env: &BTreeMap<String, String>) -> Option<PathBuf> {
    let var = route_account::home_var(family)?;
    let effective = crate::login_env::effective_for(Some(family), env);
    effective.get(var).filter(|v| !v.is_empty()).map(PathBuf::from).or_else(|| {
        effective
            .get("HOME")
            .map(PathBuf::from)
            .or_else(dirs::home_dir)
            .map(|p| p.join(format!(".{family}")))
    })
}

fn mark_credentials_changed(meta: &mut SessionMeta, at: u64) {
    let last = meta.last_turn.as_ref();
    meta.auth_change = Some(crate::store::AuthChange {
        at,
        turn_id: last.and_then(|v| v.get("turnId")).and_then(Value::as_str).map(str::to_owned),
        ended_at: last.and_then(|v| v.get("endedAt")).and_then(Value::as_u64),
    });
}

/// The evidence one answer is decided from, in the module's order.
#[derive(Debug, Default)]
pub(crate) struct Facts {
    pub harness: String,
    pub route_id: Option<String>,
    /// The route probe's answer and when it came.
    pub probe: Option<(u64, Value)>,
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
        self.route_state().is_some()
            || self.turn.as_ref().is_some_and(|(_, t)| t.state != State::Ready)
    }

    fn route_state(&self) -> Option<State> {
        match self.probe.as_ref()?.1.get("status").and_then(Value::as_str)? {
            "auth_needed" => Some(State::RouteAuthNeeded),
            "unreachable" => Some(State::RouteUnreachable),
            _ => None,
        }
    }

    /// The answer: the first evidence that says something, else `unknown`; its `detail` one
    /// sentence ([`one_sentence`]).
    pub(crate) fn decide(self) -> SessionAuthResult {
        let mut out = self.answer();
        out.detail = one_sentence(&out.detail);
        out
    }

    fn answer(self) -> SessionAuthResult {
        let route = self.route_id.clone();
        let mut out = SessionAuthResult {
            state: State::Unknown,
            source: Source::None,
            evidence_at: None,
            detail: "nothing here shows this chat's sign-in yet".into(),
            harness: self.harness.clone(),
            host: None,
            route_id: route.clone(),
            login: None,
            from_session_id: None,
        };
        let terminal = |command: &Option<String>| SessionAuthLogin {
            kind: LoginKind::Terminal,
            command: command.clone(),
            host: None,
            route_id: None,
        };
        if let (Some(state), Some((at, probe))) = (self.route_state(), &self.probe) {
            let message = probe.get("message").and_then(Value::as_str).unwrap_or_default();
            out.state = state;
            out.source = Source::RouteProbe;
            out.evidence_at = Some(*at);
            out.detail = format!("route {} answered: {message}", route.as_deref().unwrap_or("?"));
            if state == State::RouteAuthNeeded {
                out.login = Some(SessionAuthLogin {
                    kind: LoginKind::Route,
                    command: None,
                    host: None,
                    route_id: route,
                });
            }
            return out;
        }
        // A fresh conclusive refusal can supersede an old successful turn. Mere local
        // credential presence never supersedes a failed turn, and network errors prove neither.
        let newer_refusal = self.turn.as_ref().is_some_and(|(_, turn)| {
            turn.state == State::Ready
                && self.check.as_ref().is_some_and(|(at, check)| {
                    *at >= turn.at && matches!(check, Ok((Auth::SignedOut | Auth::Expired, _)))
                })
        });
        if let Some((from, turn)) = self.turn.filter(|_| !newer_refusal) {
            out.state = turn.state;
            out.source = if turn.state == State::Unknown { Source::None } else { Source::Turn };
            out.evidence_at = (turn.state != State::Unknown).then_some(turn.at);
            out.detail = turn.detail;
            out.from_session_id = (turn.state != State::Unknown).then_some(from);
            if matches!(turn.state, State::SignedOut | State::Expired) {
                out.login = Some(terminal(&self.login));
            }
            return out;
        }
        match self.check {
            // A check that ran is the evidence, whatever it said; one that could not reach its
            // provider says unknown, never signed out.
            Some((at, Ok((auth, detail)))) => {
                out.state = match auth {
                    Auth::SignedIn => State::Ready,
                    Auth::Expired => State::Expired,
                    Auth::Unknown => State::Unknown,
                    _ => State::SignedOut,
                };
                out.source = Source::AuthCheck;
                out.evidence_at = Some(at);
                out.detail = detail;
                if matches!(out.state, State::SignedOut | State::Expired) {
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
        let word =
            flat.get(..i).unwrap_or_default().rsplit(' ').next().unwrap_or_default().to_lowercase();
        let word = word.trim_start_matches(|c: char| !c.is_alphanumeric());
        let short = word.chars().count() <= 2;
        let rest = flat.get(i..).unwrap_or_default().trim_start_matches(closers);
        let end = flat.len() - rest.len();
        (rest.starts_with(' ')
            && !short
            && !["e.g.", "i.e.", "etc.", "vs.", "cf.", "approx."].contains(&word))
        .then_some(end)
    });
    let sentence = end.map_or(flat.as_str(), |i| flat.get(..i).unwrap_or(&flat));
    if sentence.chars().count() <= DETAIL_CHARS {
        return sentence.to_owned();
    }
    let cut: String = sentence.chars().take(DETAIL_CHARS - 1).collect();
    format!("{}…", cut.trim_end())
}

/// The longest `detail`, in characters.
const DETAIL_CHARS: usize = 200;

impl Hub {
    /// Resolve login in the same profile, preset, recorded account home and route as the chat.
    /// The caller supplies only a session id and agent family, never a path or environment.
    pub(crate) async fn login_profile(
        &self,
        session: &Session,
        family: &str,
    ) -> Result<(crate::config::HarnessProfile, Option<String>), RpcError> {
        let meta = session.meta();
        let cfg = self.config.read().await;
        let mut profile = cfg.harnesses.get(&meta.harness).cloned().ok_or_else(|| {
            RpcError::invalid_params("the chat's harness is no longer configured")
        })?;
        if crate::config::derive_family(&meta.harness, &profile) != family {
            return Err(RpcError::invalid_params(
                "the login agent does not match the chat's harness",
            ));
        }
        let defaults = cfg.defaults_for(&meta.harness).env;
        let (dir, state) = routes::places(&cfg);
        drop(cfg);
        let bindings = routes::bindings(&state);
        profile.env = route_account::spawn_env(
            &meta,
            with_defaults(&defaults, self.harness_env(&meta).await.1),
        );
        let route = route_of(&bindings, dir.as_deref(), &meta, family, &profile.env)
            .map_err(|e| RpcError::invalid_params(e.to_string()))?;
        if route.as_ref().is_some_and(|(r, _)| r.file.kind != routes::RouteKind::DirectSubscription)
        {
            return Err(RpcError::invalid_params(
                "this chat uses a provider route; sign in to that route",
            ));
        }
        let picked = route.as_ref().map(|(r, scope)| (r, *scope));
        let home = self.home_of(&meta, family, &defaults, picked).await;
        if let (Some(var), Some(home)) = (route_account::home_var(family), home) {
            // Pinning the default Claude home would move its .claude.json, so leave it unset.
            profile.env.insert(var.into(), home.display().to_string());
        }
        Ok((profile, route.map(|(r, _)| r.id)))
    }

    /// Credential writes invalidate only this account on this route. Keep the old turn in
    /// history and suppress its auth claim until another turn actually uses the new credential.
    pub(crate) async fn login_changed(
        self: &Arc<Self>,
        family: &str,
        home: &Path,
        route: Option<&str>,
    ) -> Result<(), RpcError> {
        if route_account::home_var(family).is_none() {
            return Ok(());
        }
        for session in self.sessions() {
            let Ok((profile, current_route)) = self.login_profile(&session, family).await else {
                continue;
            };
            if account_home(family, &profile.env).as_deref() != Some(home)
                || current_route.as_deref() != route
            {
                continue;
            }
            self.session_log(&session).await;
            {
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                mark_credentials_changed(&mut meta, now_ms());
            }
            self.save_meta_answered(&session)?;
        }
        Ok(())
    }

    /// `_acpmux/session/auth` for this daemon's chat `session`, or for `target` (a chat with
    /// no session yet, on this daemon). `refresh`: probe the route and run the harness's own
    /// check when nothing newer answers.
    pub(crate) async fn session_auth(
        self: &Arc<Self>,
        session: Option<&Arc<Session>>,
        target: Option<&SessionAuthTarget>,
        refresh: bool,
    ) -> Result<SessionAuthResult, RpcError> {
        // A chat whose log is not read yet (a deferred start) has only its summary.
        if let Some(session) = session {
            self.session_log(session).await;
        }
        let meta = session.map(|s| s.meta());
        // Validate on the destination daemon, after peer forwarding. Never substitute this
        // daemon's own cwd for an omitted target directory.
        let cwd = match (&meta, target.and_then(|t| t.cwd.as_ref())) {
            (Some(meta), _) => Some(meta.cwd.clone()),
            (None, Some(cwd)) => {
                if !cwd.is_absolute() || !tokio::fs::metadata(cwd).await.is_ok_and(|m| m.is_dir()) {
                    return Err(RpcError::invalid_params(
                        "target.cwd must be an absolute existing directory on the destination",
                    ));
                }
                Some(cwd.clone())
            }
            (None, None) => None,
        };
        let harness = match (&meta, target) {
            (Some(meta), _) => meta.harness.clone(),
            (None, Some(t)) => t.harness.clone(),
            (None, None) => {
                return Err(RpcError::invalid_params("sessionId or target is required"));
            }
        };
        let cfg = self.config.read().await;
        let profile = cfg.harnesses.get(&harness).cloned();
        if profile.is_none() && meta.is_none() {
            return Err(RpcError::invalid_params(format!("no harness named {harness:?}")));
        }
        let notes = cfg.profile_meta.get(&harness).and_then(|m| m.auth.clone());
        // The family's and the profile's `defaults` env, which a spawn lays under the profile's
        // (`Hub::spawn_profile`): it may pin an account home.
        let defaults = cfg.defaults_for(&harness).env;
        let (dir, state) = routes::places(&cfg);
        drop(cfg);
        let family = profile
            .as_ref()
            .map(|p| crate::config::derive_family(&harness, p))
            .unwrap_or_else(|| harness.clone());
        let bindings = routes::bindings(&state);
        let env = match &meta {
            Some(meta) => route_account::spawn_env(
                meta,
                with_defaults(&defaults, self.harness_env(meta).await.1),
            ),
            None => with_defaults(
                &defaults,
                profile.as_ref().map(|p| p.env.clone()).unwrap_or_default(),
            ),
        };
        // The route and the scope that chose it, as the spawn picks them. A chat whose route
        // is gone is reported on none (its next spawn says so); a target's is an error.
        let route = match (&meta, target) {
            (Some(meta), _) => {
                route_of(&bindings, dir.as_deref(), meta, &family, &env).ok().flatten()
            }
            (None, Some(t)) => target_route(dir.as_deref(), &bindings, t, &family, &env)?,
            (None, None) => None,
        };
        let own_login = route
            .as_ref()
            .is_none_or(|(r, _)| r.file.kind == routes::RouteKind::DirectSubscription);
        let route_id = route.as_ref().map(|(r, _)| r.id.clone());
        let picked = route.as_ref().map(|(r, scope)| (r, *scope));
        let home = match &meta {
            Some(meta) => self.home_of(meta, &family, &defaults, picked).await,
            None => target_home(&env, &family, picked, cwd.as_deref()),
        };
        let var = route_account::home_var(&family);
        let mut facts = Facts {
            harness: harness.clone(),
            route_id: route_id.clone(),
            login: route_account::login_command(
                notes
                    .as_ref()
                    .and_then(|n| n.login.clone())
                    .or_else(|| crate::harness_health::builtin_login(&family).map(str::to_owned)),
                var.zip(home.as_deref()),
            ),
            ..Facts::default()
        };
        // Only a probe of the endpoint this harness uses says anything of it.
        if let Some((route, _)) = route.as_ref().filter(|(r, _)| routes::probes_for(r, &family)) {
            // With refresh, a new probe (never of a route whose secret is in the keychain);
            // else, or for such a route, the last answer while it is fresh.
            facts.probe = if refresh && !routes::reads_keychain(route) {
                Some((now_ms(), routes::probe(route, &state).await))
            } else {
                routes::recent_probe(route, PROBE_FRESH_MS)
            };
        }
        facts.turn = match (session, &meta) {
            (Some(s), Some(meta)) => session_evidence(meta).map(|t| (s.id.clone(), t)),
            _ => {
                let siblings = Siblings {
                    bindings: &bindings,
                    family: &family,
                    defaults: &defaults,
                    route: &route_id,
                    cwd: cwd.as_deref(),
                };
                self.sibling_turn(&harness, &siblings, &home).await
            }
        };
        if refresh
            && own_login
            && let Some((_, previous)) = &facts.turn
            && matches!(previous.state, State::SignedOut | State::Expired)
        {
            let after = previous.at;
            let family = family.clone();
            let env = env.clone();
            let home = home.clone();
            let changed = tokio::task::spawn_blocking(move || {
                credential_file_changed(&family, &env, home.as_deref(), after)
            })
            .await
            .unwrap_or(None);
            if let (Some(at), Some((id, evidence))) = (changed, facts.turn.as_mut()) {
                if let Ok(changed_session) = self.resolve(id) {
                    let current = {
                        let mut meta =
                            changed_session.meta.lock().unwrap_or_else(|e| e.into_inner());
                        // The file probe awaited off-thread: do not invalidate a newer turn,
                        // including in this response, if one finished while the file was read.
                        if meta
                            .last_turn
                            .as_ref()
                            .and_then(turn_evidence)
                            .is_some_and(|t| t.at == after)
                        {
                            mark_credentials_changed(&mut meta, at);
                        }
                        session_evidence(&meta)
                    };
                    self.save_meta_answered(&changed_session)?;
                    if let Some(current) = current {
                        *evidence = current;
                    }
                } else {
                    *evidence = TurnEvidence {
                        state: State::Unknown,
                        at,
                        detail:
                            "the credential file changed; the next turn will check the new sign-in"
                                .into(),
                    };
                }
            }
        }
        // A provider route does not use the CLI's own subscription login. Its probe/turn
        // evidence answers for it; a local file token expiring cannot block that route.
        if !facts.settled()
            && refresh
            && own_login
            && let Some(mut profile) = profile
        {
            // A chat's own env as its spawn builds it (`route_account::spawn_env`); a target's
            // is the profile's; either over the defaults' env.
            profile.env = env;
            if let (Some(var), Some(home)) = (var, &home) {
                profile.env.insert(var.to_owned(), home.display().to_string());
            }
            let id = harness.clone();
            let check = tokio::task::spawn_blocking(move || match cwd.as_deref() {
                Some(cwd) => {
                    crate::harness_health::fresh_auth_in(&id, &profile, notes.as_ref(), Some(cwd))
                }
                None => crate::harness_health::fresh_auth(&id, &profile, notes.as_ref()),
            })
            .await
            .unwrap_or_else(|e| Err(e.to_string()));
            facts.check = Some((now_ms(), check));
        }
        Ok(facts.decide())
    }

    /// The account home `meta`'s chat runs in when it is not the CLI's default, as its spawn
    /// picks it on `route` (and the scope that chose it; `Hub::apply_route_for`): a chat whose
    /// conversation has a home keeps it; else a route picked for the chat or its profile puts
    /// its own home over a pinned one, and any other route's home applies only where nothing
    /// pins one.
    async fn home_of(
        &self,
        meta: &SessionMeta,
        family: &str,
        defaults: &BTreeMap<String, String>,
        route: Option<(&routes::Route, &str)>,
    ) -> Option<PathBuf> {
        let env = with_defaults(defaults, self.harness_env(meta).await.1);
        let pinned = route_account::current_home(meta, family, &env);
        if route_account::has_home(meta) {
            return pinned;
        }
        let picked =
            route.filter(|(_, scope)| pinned.is_none() || matches!(*scope, "chat" | "profile"));
        picked.and_then(|(r, _)| r.file.account_home.as_ref().map(PathBuf::from)).or(pinned)
    }

    /// The newest turn evidence of a chat here with this harness, route and account home. A
    /// chat whose spawn would fail on its route (gone, or not serving the harness) shares none.
    async fn sibling_turn(
        self: &Arc<Self>,
        harness: &str,
        like: &Siblings<'_>,
        home: &Option<PathBuf>,
    ) -> Option<(String, TurnEvidence)> {
        let dir = routes::places(&*self.config.read().await).0;
        let mut best: Option<(String, TurnEvidence)> = None;
        for s in self.sessions() {
            if s.meta().harness != harness || like.cwd != Some(s.meta().cwd.as_path()) {
                continue;
            }
            // A chat whose log is not read yet (a deferred start) has only its summary.
            self.session_log(&s).await;
            let meta = s.meta();
            let Some(turn) = session_evidence(&meta) else { continue };
            if best.as_ref().is_some_and(|(_, b)| b.at >= turn.at) {
                continue;
            }
            let env = route_account::spawn_env(
                &meta,
                with_defaults(like.defaults, self.harness_env(&meta).await.1),
            );
            let Ok(route) = route_of(like.bindings, dir.as_deref(), &meta, like.family, &env)
            else {
                continue;
            };
            if route.as_ref().map(|(r, _)| &r.id) != like.route.as_ref() {
                continue;
            }
            let picked = route.as_ref().map(|(r, scope)| (r, *scope));
            if self.home_of(&meta, like.family, like.defaults, picked).await == *home {
                best = Some((s.id.clone(), turn));
            }
        }
        best
    }
}

/// What a target's sibling chats share with it, besides the harness.
struct Siblings<'a> {
    bindings: &'a routes::Bindings,
    family: &'a str,
    /// The harness's `defaults` env, under every chat's own.
    defaults: &'a BTreeMap<String, String>,
    /// The target's route id.
    route: &'a Option<String>,
    /// An omitted project directory cannot borrow another project's evidence.
    cwd: Option<&'a Path>,
}

/// The route a spawn takes, given the route id and scope it chose (`routes::spawn_route`): an
/// error for one it refuses (gone, or named by the chat or the profile but not serving the
/// harness), none for a family or global one that does not serve it (`Hub::apply_route_for`).
fn spawn_route_for(
    dir: Option<&Path>,
    chosen: Option<(String, &'static str)>,
    family: &str,
) -> Result<Option<(routes::Route, &'static str)>, String> {
    let Some((id, scope)) = chosen else { return Ok(None) };
    let route = routes::find(dir, &id).map_err(|e| format!("route {id}: {}", e.message()))?;
    if route.serves(family) {
        Ok(Some((route, scope)))
    } else if matches!(scope, "chat" | "profile") {
        Err(format!("route {id} does not serve the {family} harness"))
    } else {
        Ok(None)
    }
}

/// The route `meta`'s chat spawns on and the scope that chose it, as its spawn picks them.
fn route_of(
    bindings: &routes::Bindings,
    dir: Option<&Path>,
    meta: &SessionMeta,
    family: &str,
    profile_env: &BTreeMap<String, String>,
) -> Result<Option<(routes::Route, &'static str)>, String> {
    let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
    let chosen = routes::spawn_route(bindings, &meta.id, workspace, family, profile_env);
    spawn_route_for(dir, chosen, family)
}

/// The route a new chat of `target` would spawn on, and the scope that chose it: its `routeId`
/// (as a chat's own), else the one a spawn picks with no chat or workspace. An error for a
/// route a spawn refuses.
fn target_route(
    dir: Option<&Path>,
    bindings: &routes::Bindings,
    target: &SessionAuthTarget,
    family: &str,
    profile_env: &BTreeMap<String, String>,
) -> Result<Option<(routes::Route, &'static str)>, RpcError> {
    let chosen = match &target.route_id {
        Some(id) => Some((id.clone(), "chat")),
        None => {
            let mut bindings = bindings.clone();
            bindings.chats.clear();
            routes::spawn_route(&bindings, "", None, family, profile_env)
        }
    };
    spawn_route_for(dir, chosen, family).map_err(RpcError::invalid_params)
}

/// `env` over `defaults`, as a spawn lays them (`Hub::spawn_profile`).
fn with_defaults(
    defaults: &BTreeMap<String, String>,
    mut env: BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    for (k, v) in defaults {
        env.entry(k.clone()).or_insert_with(|| v.clone());
    }
    env
}

/// The account home a new chat would run in with `env` (its profile's over its defaults) on
/// `route` (and the scope that chose it), as `Hub::apply_route_for` picks it: a home `env` pins
/// is only replaced by a route picked for the chat or the profile; else the route's home, else
/// the pinned one.
fn target_home(
    env: &BTreeMap<String, String>,
    family: &str,
    route: Option<(&routes::Route, &str)>,
    cwd: Option<&Path>,
) -> Option<PathBuf> {
    let configured = route_account::home_var(family).and_then(|var| env.get(var));
    let pinned = configured.and_then(|value| {
        // No target model or directory means these variables cannot select a known account.
        if value.contains("${model}") || (cwd.is_none() && value.contains("${cwd}")) {
            return None;
        }
        let user = dirs::home_dir().unwrap_or_default();
        Some(PathBuf::from(super::expand_env_value(value, cwd.unwrap_or(&user), &user, "")))
    });
    let picked =
        route.filter(|(_, scope)| configured.is_none() || matches!(*scope, "chat" | "profile"));
    picked.and_then(|(r, _)| r.file.account_home.as_ref().map(PathBuf::from)).or(pinned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(status: &str, kind: Option<&str>, text: &str, at: u64) -> Value {
        json!({"status": status, "errorKind": kind, "errorText": text, "endedAt": at})
    }

    fn facts(probe: Option<&str>, last: Option<Value>, check: Option<Result<Auth, &str>>) -> Facts {
        Facts {
            harness: "claude".into(),
            route_id: probe.map(|_| "proxy".into()),
            probe: probe.map(|s| (5, json!({"status": s, "message": format!("HTTP: {s}")}))),
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
                facts(None, Some(turn("completed", None, "", 7)), None),
                State::Ready,
                Source::Turn,
                Some(7),
            ),
            (facts(None, Some(signed_out), None), State::SignedOut, Source::Turn, Some(7)),
            (facts(None, Some(expired), None), State::Expired, Source::Turn, Some(7)),
            (
                facts(Some("auth_needed"), None, None),
                State::RouteAuthNeeded,
                Source::RouteProbe,
                Some(5),
            ),
            (
                facts(Some("unreachable"), None, None),
                State::RouteUnreachable,
                Source::RouteProbe,
                Some(5),
            ),
            (
                facts(None, None, Some(Ok(Auth::Expired))),
                State::Expired,
                Source::AuthCheck,
                Some(9),
            ),
            (facts(None, None, Some(Ok(Auth::SignedIn))), State::Ready, Source::AuthCheck, Some(9)),
            (
                facts(None, None, Some(Ok(Auth::SignedOut))),
                State::SignedOut,
                Source::AuthCheck,
                Some(9),
            ),
            (facts(None, None, None), State::Unknown, Source::None, None),
            (
                facts(None, None, Some(Ok(Auth::Unknown))),
                State::Unknown,
                Source::AuthCheck,
                Some(9),
            ),
        ] {
            let out = f.decide();
            assert_eq!((out.state, out.source, out.evidence_at), (state, source, at), "{out:?}");
            let blocks =
                matches!(state, State::SignedOut | State::Expired | State::RouteAuthNeeded);
            assert_eq!(out.login.is_some(), blocks, "{out:?}");
        }
    }

    #[test]
    fn a_new_refusal_supersedes_an_old_success_but_presence_does_not_clear_a_failure() {
        for auth in [Auth::Expired, Auth::SignedOut] {
            let f = facts(None, Some(turn("completed", None, "", 7)), Some(Ok(auth)));
            assert!(!f.settled(), "an old success permits an explicit fresh check");
            let out = f.decide();
            assert_eq!(out.source, Source::AuthCheck);
            assert!(matches!(out.state, State::Expired | State::SignedOut));
        }
        for check in [Ok(Auth::SignedIn), Ok(Auth::Unknown), Err("network error")] {
            let out =
                facts(None, Some(turn("failed", Some("auth.expired"), "expired", 7)), Some(check))
                    .decide();
            assert_eq!((out.state, out.source), (State::Expired, Source::Turn));
        }
        let out =
            facts(None, Some(turn("completed", None, "", 7)), Some(Err("network error"))).decide();
        assert_eq!((out.state, out.source), (State::Ready, Source::Turn));
    }

    #[test]
    fn credential_change_survives_metadata_reload_without_changing_turn_history() {
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        assert!(meta.auth_change.is_none(), "older metadata remains readable");
        let history = turn("failed", Some("auth.expired"), "expired", 7);
        meta.last_turn = Some(history.clone());
        mark_credentials_changed(&mut meta, 9);
        let encoded = serde_json::to_value(&meta).unwrap();
        let mut restored: SessionMeta = serde_json::from_value(encoded).unwrap();
        assert_eq!(restored.last_turn, Some(history));
        assert_eq!(session_evidence(&restored).unwrap().state, State::Unknown);
        restored.last_turn = Some(turn("failed", Some("auth.expired"), "still expired", 10));
        assert_eq!(session_evidence(&restored).unwrap().state, State::Expired);
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
            assert_eq!(facts(None, Some(last), None).decide().state, State::Unknown);
        }
        let out =
            facts(None, None, Some(Err("Claude Code may keep its login in its keychain"))).decide();
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
        let out = facts(None, Some(turn("failed", Some("auth.expired"), text, 7)), None).decide();
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

    /// A rate-limited or unknown probe says nothing of the sign-in: the turn answers.
    #[test]
    fn a_rate_limited_probe_falls_through() {
        for status in ["rate_limited", "unknown", "ok"] {
            let out = facts(Some(status), Some(turn("completed", None, "", 7)), None).decide();
            assert_eq!((out.state, out.source), (State::Ready, Source::Turn), "{status}");
            assert_eq!(out.route_id.as_deref(), Some("proxy"));
            let out = facts(Some(status), None, None).decide();
            assert_eq!(out.state, State::Unknown, "{status}");
        }
    }

    /// A target's account home is the one its spawn would use: a home the profile pins beats
    /// a family or global route's, not one picked for the chat or the profile.
    #[test]
    fn a_target_keeps_the_home_its_profile_pins() {
        let route = |home: &str| routes::Route {
            id: "r".into(),
            file: serde_json::from_value(
                json!({"kind": "direct-subscription", "account_home": home}),
            )
            .unwrap(),
            path: PathBuf::new(),
        };
        let at = |home: &str| BTreeMap::from([("CODEX_HOME".to_owned(), home.to_owned())]);
        let pinned = at("/accounts/A");
        let plain = BTreeMap::new();
        let b = route("/accounts/B");
        let home = |env: &BTreeMap<_, _>, scope| target_home(env, "codex", Some((&b, scope)), None);
        assert_eq!(home(&pinned, "global"), Some(PathBuf::from("/accounts/A")));
        assert_eq!(home(&pinned, "family"), Some(PathBuf::from("/accounts/A")));
        assert_eq!(home(&pinned, "chat"), Some(PathBuf::from("/accounts/B")));
        assert_eq!(home(&plain, "global"), Some(PathBuf::from("/accounts/B")));
        assert_eq!(target_home(&pinned, "codex", None, None), Some(PathBuf::from("/accounts/A")));
        let templated = BTreeMap::from([("CODEX_HOME".into(), "${cwd}/.codex".into())]);
        assert_eq!(target_home(&templated, "codex", None, None), None);
        assert_eq!(
            target_home(&templated, "codex", None, Some(Path::new("/project"))),
            Some(PathBuf::from("/project/.codex"))
        );
        // A home the defaults pin holds as the profile's does, and the profile's wins over it.
        let defaulted = with_defaults(&at("/accounts/A"), BTreeMap::new());
        assert_eq!(home(&defaulted, "global"), Some(PathBuf::from("/accounts/A")));
        let both = with_defaults(&at("/accounts/A"), at("/accounts/C"));
        assert_eq!(home(&both, "global"), Some(PathBuf::from("/accounts/C")));
    }

    /// A route a spawn refuses (gone, or named for the chat but not serving the harness) is an
    /// error; a family or global one that does not serve it is none.
    #[test]
    fn a_route_is_taken_as_a_spawn_takes_it() {
        let chosen = |id: &str, scope: &'static str| Some((id.to_owned(), scope));
        assert!(spawn_route_for(None, chosen("gone", "family"), "claude").is_err());
        assert!(spawn_route_for(None, chosen("cmux", "chat"), "codex").is_err());
        assert!(spawn_route_for(None, chosen("cmux", "profile"), "codex").is_err());
        assert!(matches!(spawn_route_for(None, chosen("cmux", "global"), "codex"), Ok(None)));
        let served = spawn_route_for(None, chosen("cmux", "global"), "claude").unwrap();
        assert_eq!(served.map(|(r, scope)| (r.id, scope)), Some(("cmux".into(), "global")));
        assert!(matches!(spawn_route_for(None, None, "claude"), Ok(None)));
    }

    #[test]
    fn a_chat_in_its_own_account_home_signs_in_there() {
        let home = Path::new("/Users/me/claude two");
        assert_eq!(
            route_account::login_command(
                Some("claude auth login".into()),
                Some(("CLAUDE_CONFIG_DIR", home))
            ),
            Some("CLAUDE_CONFIG_DIR='/Users/me/claude two' claude auth login".into())
        );
        assert_eq!(
            route_account::login_command(Some("codex login".into()), None),
            Some("codex login".into())
        );
    }
}

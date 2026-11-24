//! `_acpmux/account/sign_in|sign_in.finish|sign_in.cancel|switch|remove|sign_out|readiness`: one
//! provider-neutral
//! sign-in for every account a person has here (Leo, 2026-11-22: "we likewise want gh auth or
//! device stuff to be much more convienient ui/ux wise. it's similar to the chatgpt device with
//! the code login thing. we want that for anywhere and everywhere we have codex stuff, and
//! extremely convieniently tightly integrated claude stuff ... this is simply logins, done
//! righr.").
//!
//! - `sign_in {account}` signs a listed account (`_acpmux/accounts`) in, in its own home;
//!   `sign_in {family, name?}` adds another one of `codex`, `claude` or `github`. A Codex or
//!   Claude add takes the id, name and home the Mac's Settings picks
//!   (`SettingsHarnesses+Accounts.swift` `newAccount`: `<family>-<n>`, `ChatGPT <n>` /
//!   `Claude <n>`, `~/.cmux/accounts/<id>`, a shadow home for Codex) and lists its route only
//!   once the sign-in succeeded: a cancelled, failed or expired add lists nothing and removes
//!   only the home it made. GitHub runs gh's own device flow (`agent_login::github`).
//! - `sign_in.finish {loginId, code?}` waits for it (Claude takes the pasted code);
//!   `sign_in.cancel {loginId}` stops it.
//! - `switch {account}`: Codex and Claude make it their family's default (a built-in login:
//!   no binding); GitHub runs `gh auth switch`. `remove {account}`: Codex and Claude do what
//!   `_acpmux/route/remove` does (built-ins refused); GitHub runs `gh auth logout`.
//! - `sign_out {account}`: the CLI's own logout in the account's home (`codex logout`,
//!   `claude auth logout`, as the Mac's Settings `accountSignOut`; built-in logins too), and
//!   the row stays, signed out; GitHub runs `gh auth logout` (as `remove`).
//! - `readiness {}`: `{providers: [{family, state, account?, label?}]}`, always `github`, `codex`,
//!   `claude` in that order, for onboarding. `state` is `notInstalled` (its CLI is not found, the
//!   check `sign_in` refuses with), `signInRequired`, or `ready` (a signed-in, enabled account:
//!   `account` is the default one's id, else the first's, and `label` its email or login).
//!
//! Who may ask: exactly who may run an agent's sign-in here (`agent_login::allowed`, one rule for
//! both): this machine's unix socket and its app, and the owner's own peer daemon (the person's
//! Mac, forwarding its card for a Cloud or remote machine's chat: `vm_boundary::owner`), so a
//! Cloud or remote machine signs GitHub, Codex or Claude in there with the same device card
//! (Leo, 2026-11-22: "if we host the browser and the app at the same time and the cloud
//! product... theres no reason for us not only to be able to have s*** side by side opened where
//! it's convienient"). Never a Web client, a paired device, a teammate on a team machine, or a
//! peer forwarding for one of them (`REMOTE_REFUSED`); a team machine itself refuses every own
//! sign-in (`shared_machine`, `Machine::refuse_shared`). A request that names a chat
//! (`sessionId`) was forwarded to the chat's machine before it got here; one whose chat is not
//! here is refused (`unknown_session`), never run on this machine in its place. The caller names
//! an account or a family only:
//! every program, path and variable comes from this daemon. Nothing here logs, traces or
//! answers a code beyond `userCode` in the start reply, or any token.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};

use serde_json::{Value, json};

use super::agent_login::{REMOTE_REFUSED, cli_for, error, machine};
use super::{Conn, ConnAuth, Origin};
use crate::agent_login::{self as login, Agent, Cli, LoginError, github, reason};
use crate::hub::Hub;
use crate::routes::{self, RouteFile};
use crate::rpc::{RpcError, method};

#[cfg(test)]
mod tests;

/// The methods `handle` answers.
pub(super) const METHODS: &[&str] = &[
    method::MUX_ACCOUNT_SIGN_IN,
    method::MUX_ACCOUNT_SIGN_IN_FINISH,
    method::MUX_ACCOUNT_SIGN_IN_CANCEL,
    method::MUX_ACCOUNT_SWITCH,
    method::MUX_ACCOUNT_REMOVE,
    method::MUX_ACCOUNT_SIGN_OUT,
    method::MUX_ACCOUNT_READINESS,
];

/// The families `readiness` answers for, in its order, and their CLIs.
pub const READINESS_FAMILIES: [(&str, Agent); 3] =
    [("github", Agent::Github), ("codex", Agent::Codex), ("claude", Agent::Claude)];

/// The id prefix of a GitHub account row (`github:<login>`).
pub const GITHUB_PREFIX: &str = "github:";
/// The longest typed name kept (the Mac's picker keeps as many).
pub const NAME_MAX: usize = 128;

/// Whether a connection of `origin` that presented `auth` may ask (module docs): the agent
/// sign-in's own owner rule, not a second policy.
pub fn allowed(origin: Origin, auth: ConnAuth, params: &Value) -> bool {
    super::agent_login::allowed(origin, auth, params)
}

fn refused() -> RpcError {
    RpcError::new(
        -32000,
        "accounts sign in only from this machine, its cmux app, or its owner's own machine",
    )
    .with_data(json!({"reason": REMOTE_REFUSED}))
}

fn unknown(id: &str) -> LoginError {
    LoginError::new(reason::UNKNOWN_ACCOUNT, format!("no account {id:?} here"))
}

/// What a `sign_in`, `switch` or `remove` names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// A Codex or Claude account the accounts list has. `home`: its own folder (none for the
    /// CLI's own login, which signs in where the CLI keeps it); `builtin`: that own login.
    Listed { id: String, family: String, home: Option<PathBuf>, builtin: bool },
    /// A GitHub account of gh's (`github:<login>`).
    Github { login: String },
}

/// The account `id` names among `accounts` (the `_acpmux/accounts` rows): a GitHub id by its
/// shape, any other only when listed as a login (an API-key route is no sign-in).
pub fn resolve(id: &str, accounts: &[Value]) -> Result<Target, LoginError> {
    if let Some(login) = id.strip_prefix(GITHUB_PREFIX) {
        if !github::login_shaped(login) {
            return Err(unknown(id));
        }
        return Ok(Target::Github { login: login.to_owned() });
    }
    let row = accounts.iter().find(|a| field(a, "id") == Some(id)).ok_or_else(|| unknown(id))?;
    let family = field(row, "family").unwrap_or_default();
    if !matches!(family, "codex" | "claude") {
        return Err(unknown(id));
    }
    if flag(row, "key") {
        return Err(LoginError::new(
            reason::UNSUPPORTED,
            format!("{id} is an API key, not a sign-in: edit its key instead"),
        ));
    }
    Ok(Target::Listed {
        id: id.to_owned(),
        family: family.to_owned(),
        home: field(row, "home").map(PathBuf::from),
        builtin: flag(row, "builtin"),
    })
}

/// The id and name a new account of `family` gets, as the Mac's picker picks them
/// (`newAccount`): the first `n` from max(2, that family's count + 1) whose id `<family>-<n>`
/// and name `<Base> <n>` are both free, also skipping an id `taken` says is in use (an add in
/// progress, or a folder `~/.cmux/accounts/<id>` already there). A typed name, trimmed, is kept
/// to its first [`NAME_MAX`] characters.
pub fn new_account(
    family: &str,
    accounts: &[Value],
    typed: Option<&str>,
    taken: impl Fn(&str) -> bool,
) -> (String, String) {
    let ids: std::collections::HashSet<&str> =
        accounts.iter().filter_map(|a| field(a, "id")).collect();
    let names: std::collections::HashSet<&str> =
        accounts.iter().filter_map(|a| field(a, "name")).collect();
    let base = match family {
        "codex" => "ChatGPT",
        "claude" => "Claude",
        other => other,
    };
    let mut n = accounts
        .iter()
        .filter(|a| field(a, "family") == Some(family))
        .count()
        .saturating_add(1)
        .max(2);
    loop {
        let id = format!("{family}-{n}");
        let name = format!("{base} {n}");
        if !ids.contains(id.as_str()) && !names.contains(name.as_str()) && !taken(&id) {
            let typed = typed.map(str::trim).filter(|t| !t.is_empty());
            let name = typed.map(|t| t.chars().take(NAME_MAX).collect()).unwrap_or(name);
            return (id, name);
        }
        n = n.saturating_add(1);
    }
}

/// The folder a new account's login lives in: `<home>/.cmux/accounts/<id>`.
pub fn account_home(user_home: &Path, id: &str) -> PathBuf {
    user_home.join(".cmux/accounts").join(id)
}

/// The route a new Codex or Claude account writes once signed in (the Mac's `route/add` params).
pub fn add_file(family: &str, name: &str, home: &Path) -> Result<RouteFile, RpcError> {
    let mut params = json!({
        "name": name,
        "kind": "direct-subscription",
        "families": [family],
        "accountHome": home.display().to_string(),
    });
    if family == "codex"
        && let Some(obj) = params.as_object_mut()
    {
        obj.insert("shadow".into(), json!(true));
    }
    routes::file_from_json(&params).map_err(|e| crate::hub::route_error(&e))
}

/// A new account's home made ready for its sign-in: whether this made the folder (only then is
/// it removed again, [`drop_home`]).
pub fn make_home(file: &RouteFile) -> Result<bool, RpcError> {
    let made = file.account_home.as_deref().is_some_and(|h| !Path::new(h).exists());
    crate::route_account::prepare(file).map_err(|e| crate::hub::route_error(&e))?;
    Ok(made)
}

/// Removes a home an add made, unless a sign-in landed in it after all. Links in it (a Codex
/// shadow's) are removed, never what they point at.
pub fn drop_home(agent: Agent, home: &Path, made: bool) {
    if !made || login::signed_in_at(agent, home) {
        return;
    }
    if let Err(e) = crate::home_fs::remove_dir_all(home)
        && e.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!(home = %home.display(), error = %e, "account sign-in: remove the home it made");
    }
}

/// A new Codex or Claude account that is listed only once signed in.
#[derive(Debug, Clone)]
pub struct Add {
    pub id: String,
    pub file: RouteFile,
    pub home: PathBuf,
    /// This add made `home`.
    pub made: bool,
}

/// A sign-in this family started.
struct Pending {
    agent: Agent,
    /// The listed account (none: a GitHub add, whose login gh learns at the approve).
    account: Option<String>,
    /// A route-backed account's id (`login_changed`'s route).
    route: Option<String>,
    add: Option<Add>,
    /// A finish is waiting on it: a cancel only stops the CLI, and that finish cleans up.
    busy: bool,
}

fn pending() -> &'static StdMutex<HashMap<String, Pending>> {
    static PENDING: OnceLock<StdMutex<HashMap<String, Pending>>> = OnceLock::new();
    PENDING.get_or_init(Default::default)
}

fn lock_pending() -> std::sync::MutexGuard<'static, HashMap<String, Pending>> {
    pending().lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether an add in progress holds `id`.
fn adding(id: &str) -> bool {
    lock_pending().values().any(|p| p.add.as_ref().is_some_and(|a| a.id == id))
}

/// Ends an add that will not be listed: its home goes if it made it.
fn abandon(p: Pending) {
    if let Some(add) = p.add {
        drop_home(p.agent, &add.home, add.made);
    }
}

fn text<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty())
}

fn need<'a>(params: &'a Value, key: &str) -> Result<&'a str, RpcError> {
    text(params, key).ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

/// The accounts list (`_acpmux/accounts` without GitHub's rows).
async fn accounts(hub: &Hub) -> Result<Vec<Value>, RpcError> {
    let (dir, state) = routes::places(&*hub.config.read().await);
    tokio::task::spawn_blocking(move || {
        super::accounts::list(dir.as_deref(), &routes::bindings(&state))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))
}

/// How this daemon runs `agent`'s CLI (`server/agent_login.rs` `cli_for`, no chat).
async fn cli(hub: &Hub, agent: Agent) -> Result<Cli, RpcError> {
    let cfg = hub.config.read().await;
    cli_for(&cfg, agent, None).ok_or_else(|| {
        error(match agent {
            Agent::Github => LoginError::new(
                reason::NOT_INSTALLED,
                "gh (GitHub CLI) is not installed on this machine",
            ),
            _ => LoginError::new(
                reason::CLI_MISSING,
                format!("{} is not installed on this machine", agent.name()),
            ),
        })
    })
}

fn agent_of(family: &str) -> Option<Agent> {
    match family {
        "codex" => Some(Agent::Codex),
        "claude" => Some(Agent::Claude),
        "github" => Some(Agent::Github),
        _ => None,
    }
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if !allowed(conn.origin, conn.auth, params) {
        return Err(refused());
    }
    // A named chat this daemon does not have (module docs); a cancel stops a sign-in by its id.
    if m != method::MUX_ACCOUNT_SIGN_IN_CANCEL
        && let Some(key) = text(params, "sessionId")
        && hub.resolve(key).is_err()
    {
        return Err(error(LoginError::new(
            reason::UNKNOWN_SESSION,
            format!("no chat {key:?} here: open the chat again"),
        )));
    }
    match m {
        method::MUX_ACCOUNT_SIGN_IN => sign_in(hub, params).await,
        method::MUX_ACCOUNT_SIGN_IN_FINISH => finish(hub, params).await,
        method::MUX_ACCOUNT_SIGN_IN_CANCEL => {
            let id = need(params, "loginId")?;
            Ok(json!({"cancelled": cancel(id)}))
        }
        method::MUX_ACCOUNT_SWITCH => switch(hub, need(params, "account")?).await,
        method::MUX_ACCOUNT_REMOVE => remove(hub, need(params, "account")?).await,
        method::MUX_ACCOUNT_SIGN_OUT => sign_out(hub, need(params, "account")?).await,
        method::MUX_ACCOUNT_READINESS => readiness(hub).await,
        other => Err(RpcError::method_not_found(other)),
    }
}

async fn sign_in(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let (agent, account, route, home, add) = match (text(params, "account"), text(params, "family"))
    {
        (Some(_), Some(_)) => {
            return Err(RpcError::invalid_params("name an account or a family, not both"));
        }
        (None, None) => return Err(RpcError::invalid_params("account or family is required")),
        (Some(id), None) => {
            if text(params, "name").is_some() {
                return Err(RpcError::invalid_params("name is for adding an account (family)"));
            }
            let listed = accounts(hub).await?;
            match resolve(id, &listed).map_err(error)? {
                Target::Github { login } => {
                    (Agent::Github, Some(format!("{GITHUB_PREFIX}{login}")), None, None, None)
                }
                Target::Listed { id, family, home, builtin } => {
                    let agent = agent_of(&family).ok_or_else(|| error(unknown(&id)))?;
                    let route = (!builtin).then(|| id.clone());
                    (agent, Some(id), route, home, None)
                }
            }
        }
        (None, Some(family)) => {
            let agent = agent_of(family).ok_or_else(|| {
                error(LoginError::new(
                    reason::UNSUPPORTED_AGENT,
                    format!("family must be \"codex\", \"claude\" or \"github\", not {family:?}"),
                ))
            })?;
            if agent == Agent::Github {
                (agent, None, None, None, None)
            } else {
                let listed = accounts(hub).await?;
                let user_home = dirs::home_dir()
                    .ok_or_else(|| RpcError::internal("no home folder for a new account"))?;
                let (id, name) = new_account(family, &listed, text(params, "name"), |id| {
                    adding(id) || account_home(&user_home, id).exists()
                });
                let home = account_home(&user_home, &id);
                let file = add_file(family, &name, &home)?;
                let made = {
                    let file = file.clone();
                    tokio::task::spawn_blocking(move || make_home(&file))
                        .await
                        .map_err(|e| RpcError::internal(e.to_string()))??
                };
                let add = Add { id: id.clone(), file, home: home.clone(), made };
                (agent, Some(id.clone()), Some(id), Some(home), Some(add))
            }
        }
    };
    let cli = match cli(hub, agent).await {
        Ok(cli) => cli,
        Err(e) => {
            if let Some(add) = &add {
                drop_home(agent, &add.home, add.made);
            }
            return Err(e);
        }
    };
    let started = match login::start_in(&machine(hub), &cli, agent, home.as_deref()).await {
        Ok(s) => s,
        Err(e) => {
            if let Some(add) = &add {
                drop_home(agent, &add.home, add.made);
            }
            return Err(error(e));
        }
    };
    let added = add.is_some();
    let login_id = started.login_id.clone();
    lock_pending().insert(
        login_id.clone(),
        Pending { agent, account: account.clone(), route, add, busy: false },
    );
    // An add nobody finished or cancelled: its home goes with the sign-in's expiry.
    let _expiry = hub.scope.spawn_until_cancelled("account-sign-in-expiry", async move {
        tokio::time::sleep(login::EXPIRY.saturating_add(std::time::Duration::from_secs(5))).await;
        let stale = {
            let mut table = lock_pending();
            match table.get(&login_id) {
                Some(p) if !p.busy && !login::running(&login_id) => table.remove(&login_id),
                _ => None,
            }
        };
        if let Some(p) = stale {
            abandon(p);
        }
    });
    // A GitHub add has no login until gh names it at finish: until then its account is the
    // family (`github`), and finish answers the `github:<login>` it signed in.
    let shown = account.clone().unwrap_or_else(|| agent.name().to_owned());
    let mut reply = json!({
        "account": shown,
        "loginId": started.login_id,
        "url": started.url,
        "needsCode": started.needs_code,
        "expiresAtMs": started.expires_at_ms,
        "added": added,
    });
    if let Some(obj) = reply.as_object_mut() {
        if let Some(code) = started.user_code {
            obj.insert("userCode".into(), json!(code));
        }
        if let (Some(url), Some(port)) = (started.auto_url, started.callback_port) {
            obj.insert("autoUrl".into(), json!(url));
            obj.insert("callbackPort".into(), json!(port));
        }
    }
    Ok(reply)
}

/// Stops sign-in `login_id` and drops what its add made. Whether one was running.
pub fn cancel(login_id: &str) -> bool {
    let taken = {
        let mut table = lock_pending();
        match table.get(login_id) {
            // A finish waits on it: stopping the CLI ends that finish, which cleans up.
            Some(p) if p.busy => None,
            Some(_) => table.remove(login_id),
            None => None,
        }
    };
    let stopped = login::cancel(login_id);
    let had = taken.is_some();
    if let Some(p) = taken {
        abandon(p);
    }
    had || stopped
}

async fn finish(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let login_id = need(params, "loginId")?.to_owned();
    {
        let mut table = lock_pending();
        let Some(p) = table.get_mut(&login_id) else {
            return Err(error(LoginError::new(
                reason::UNKNOWN_LOGIN,
                "no account sign-in with that id is running here: start again",
            )));
        };
        if p.busy {
            return Err(error(LoginError::new(reason::BUSY, "this sign-in is already finishing")));
        }
        p.busy = true;
    }
    let code = params.get("code").and_then(Value::as_str);
    let done = login::finish(&login_id, code).await;
    // A finish refused before it waited (no code for Claude): the sign-in still runs.
    if done.is_err() && login::running(&login_id) {
        if let Some(p) = lock_pending().get_mut(&login_id) {
            p.busy = false;
        }
        return Err(error(done.err().unwrap_or_else(|| unknown(&login_id))));
    }
    let Some(p) = lock_pending().remove(&login_id) else {
        return Err(error(LoginError::new(reason::UNKNOWN_LOGIN, "the sign-in ended")));
    };
    let done = match done {
        Ok(done) if done.signed_in => done,
        Ok(_) => {
            let account = p.add.is_none().then(|| p.account.clone()).flatten();
            abandon(p);
            return Ok(json!({"signedIn": false, "account": account}));
        }
        Err(e) => {
            abandon(p);
            return Err(error(e));
        }
    };
    let account = match (&p.add, p.agent) {
        (Some(add), _) => {
            let (dir, _) = routes::places(&*hub.config.read().await);
            let (id, file) = (add.id.clone(), add.file.clone());
            let written =
                tokio::task::spawn_blocking(move || routes::add(dir.as_deref(), &id, &file, false))
                    .await
                    .map_err(|e| RpcError::internal(e.to_string()));
            match written {
                Ok(Ok(_)) => {
                    super::connections::announce_later(hub);
                    Some(add.id.clone())
                }
                Ok(Err(e)) => {
                    // The sign-in is in the home: keep it, and say why it is not listed.
                    return Err(crate::hub::route_error(&e));
                }
                Err(e) => return Err(e),
            }
        }
        (None, Agent::Github) => match cli(hub, Agent::Github).await {
            Ok(cli) => github::accounts(&cli)
                .await
                .into_iter()
                .find(|a| a.active)
                .map(|a| format!("{GITHUB_PREFIX}{}", a.login))
                .or(p.account.clone()),
            Err(_) => p.account.clone(),
        },
        (None, _) => p.account.clone(),
    };
    if p.agent != Agent::Github {
        let m = machine(hub);
        if done.store == m.home.join(p.agent.home_dir_name())
            && let Err(e) = m.choose_own(p.agent)
        {
            tracing::warn!(agent = p.agent.name(), error = %e, "account sign-in: record the own sign-in choice");
        }
        if let Err(e) = hub.login_changed(p.agent.name(), &done.store, p.route.as_deref()).await {
            tracing::warn!(agent = p.agent.name(), error = %e.message, "account sign-in: mark chats");
        }
    }
    Ok(json!({"signedIn": true, "account": account}))
}

async fn switch(hub: &Arc<Hub>, id: &str) -> Result<Value, RpcError> {
    let listed = accounts(hub).await?;
    match resolve(id, &listed).map_err(error)? {
        Target::Github { login } => {
            github::switch(&cli(hub, Agent::Github).await?, &login).await.map_err(error)?;
            Ok(json!({"account": id, "default": true}))
        }
        Target::Listed { id, family, builtin, .. } => {
            let row = listed.iter().find(|a| field(a, "id") == Some(id.as_str()));
            if row.is_some_and(|r| r.get("enabled").and_then(Value::as_bool) == Some(false)) {
                return Err(RpcError::invalid_params(format!(
                    "{id} is turned off: turn it on before making it a default"
                )));
            }
            let (_, state) = routes::places(&*hub.config.read().await);
            let scope = format!("family:{family}");
            let bound = (!builtin).then_some(id.as_str());
            routes::set_binding(&state, &scope, bound).map_err(|e| crate::hub::route_error(&e))?;
            super::connections::announce_later(hub);
            Ok(json!({"account": id, "default": true}))
        }
    }
}

async fn remove(hub: &Arc<Hub>, id: &str) -> Result<Value, RpcError> {
    let listed = accounts(hub).await?;
    match resolve(id, &listed).map_err(error)? {
        Target::Github { login } => {
            github::logout(&cli(hub, Agent::Github).await?, &login).await.map_err(error)?;
            Ok(json!({"account": id, "removed": true}))
        }
        Target::Listed { builtin: true, id, .. } => Err(RpcError::invalid_params(format!(
            "{id} is the CLI's own login: sign it out in the CLI instead"
        ))
        .with_data(json!({"reason": reason::UNSUPPORTED}))),
        Target::Listed { id, .. } => {
            let (dir, state) = routes::places(&*hub.config.read().await);
            let backup = routes::remove(dir.as_deref(), &state, &id)
                .map_err(|e| crate::hub::route_error(&e))?;
            super::connections::announce_later(hub);
            Ok(json!({"account": id, "removed": true, "backup": backup}))
        }
    }
}

async fn sign_out(hub: &Arc<Hub>, id: &str) -> Result<Value, RpcError> {
    let listed = accounts(hub).await?;
    match resolve(id, &listed).map_err(error)? {
        Target::Github { login } => {
            github::logout(&cli(hub, Agent::Github).await?, &login).await.map_err(error)?;
        }
        Target::Listed { id, family, home, .. } => {
            let agent = agent_of(&family).ok_or_else(|| error(unknown(&id)))?;
            let cli = cli(hub, agent).await?;
            login::sign_out_in(&cli, agent, home.as_deref()).await.map_err(error)?;
            let store = home.unwrap_or_else(|| cli.store(agent));
            let route = listed
                .iter()
                .any(|a| field(a, "id") == Some(id.as_str()) && !flag(a, "builtin"))
                .then_some(id.as_str());
            if let Err(e) = hub.login_changed(agent.name(), &store, route).await {
                tracing::warn!(agent = agent.name(), error = %e.message, "account sign-out: mark chats");
            }
            super::connections::announce_later(hub);
        }
    }
    Ok(json!({"account": id, "signedIn": false}))
}

/// GitHub's rows of `_acpmux/accounts`: gh's github.com accounts, read in at most
/// `github::ACCOUNTS_WAIT`; no gh, no rows.
pub(super) async fn github_rows(hub: &Hub) -> Vec<Value> {
    let cli = {
        let cfg = hub.config.read().await;
        cli_for(&cfg, Agent::Github, None)
    };
    match cli {
        Some(cli) => rows(&github::accounts(&cli).await),
        None => Vec::new(),
    }
}

/// The accounts rows of gh's accounts.
pub fn rows(accounts: &[github::GhAccount]) -> Vec<Value> {
    accounts
        .iter()
        .map(|a| {
            json!({
                "id": format!("{GITHUB_PREFIX}{}", a.login),
                "family": "github",
                "name": a.login,
                "signedIn": a.signed_in,
                "default": a.active,
                "builtin": false,
            })
        })
        .collect()
}

/// A row's string field.
fn field<'a>(row: &'a Value, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Value::as_str)
}

/// A row's flag: true only when it is `true`.
fn flag(row: &Value, key: &str) -> bool {
    row.get(key).and_then(Value::as_bool) == Some(true)
}

/// `readiness`: each family's [`provider`] answer, from the accounts rows (GitHub's too) and
/// whether its CLI is found the way [`cli`] finds it for a sign-in.
async fn readiness(hub: &Hub) -> Result<Value, RpcError> {
    let (listed, github) = tokio::join!(accounts(hub), github_rows(hub));
    let mut rows = listed?;
    rows.extend(github);
    let mut providers = Vec::with_capacity(READINESS_FAMILIES.len());
    for (family, agent) in READINESS_FAMILIES {
        let installed = cli(hub, agent).await.is_ok();
        providers.push(provider(family, installed, &rows));
    }
    Ok(json!({ "providers": providers }))
}

/// One family's readiness: `notInstalled`, `signInRequired`, or `ready` with the default
/// signed-in account (else the first signed-in one) as `account` and its email or login as
/// `label`. A turned-off account does not count.
pub fn provider(family: &str, installed: bool, rows: &[Value]) -> Value {
    if !installed {
        return json!({"family": family, "state": "notInstalled"});
    }
    let signed: Vec<&Value> = rows
        .iter()
        .filter(|a| field(a, "family") == Some(family) && flag(a, "signedIn"))
        .filter(|a| a.get("enabled").and_then(Value::as_bool) != Some(false))
        .collect();
    let Some(pick) = signed.iter().find(|a| flag(a, "default")).or_else(|| signed.first()) else {
        return json!({"family": family, "state": "signInRequired"});
    };
    let mut out = serde_json::Map::new();
    out.insert("family".to_owned(), json!(family));
    out.insert("state".to_owned(), json!("ready"));
    if let Some(id) = field(pick, "id") {
        out.insert("account".to_owned(), json!(id));
    }
    let label = field(pick, "email")
        .filter(|l| !l.is_empty())
        .or_else(|| field(pick, "name").filter(|l| !l.is_empty()));
    if let Some(label) = label {
        out.insert("label".to_owned(), json!(label));
    }
    Value::Object(out)
}

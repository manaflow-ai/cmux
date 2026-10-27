//! Per-chat consent. Removing or narrowing a share closes existing links.
use std::io::{BufRead as _, IsTerminal as _, Read as _, Write as _};

use anyhow::bail;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::{Flags, audit, config, grant};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Role {
    Member,
    Guest,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Share {
    pub surface: u64,
    pub login: String,
    pub role: Role,
    pub shared_at: String,
    /// Runtime surface numbers belong to one daemon boot, not the whole host.
    #[serde(default)]
    pub generation: String,
    /// The chat the owner consented to: the surface's agent session when shared. The proxy pins
    /// every frame to it, so a surface rebound to another chat is not shared. Empty (a share
    /// recorded before this field) matches nothing.
    #[serde(default)]
    pub session: String,
}

/// What a share names on the daemon: its boot and the surface's current agent session.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Chat {
    pub generation: String,
    pub session: String,
}

pub(super) fn run(verb: &str, args: &[String]) -> anyhow::Result<()> {
    let text = &crate::localization::catalog().host_share;
    let flags = Flags::parse(args, if verb == "share" { &["role"] } else { &[] }, &["json"])?;
    let config = config::load()?;
    if verb == "shares" {
        if !flags.positional.is_empty() {
            return Err(super::usage(text.no_arguments));
        }
        println!("{}", json!({"shares": config.shares}));
        return Ok(());
    }
    let [surface, login] = flags.positional.as_slice() else {
        return Err(super::usage(text.arguments));
    };
    let surface: u64 = surface.parse().map_err(|_| super::usage(text.surface))?;
    let login = login.trim().to_ascii_lowercase();
    let role = match flags.value("role").unwrap_or("member") {
        "member" => Role::Member,
        "guest" => Role::Guest,
        _ => return Err(super::usage(text.role)),
    };
    shareable(verb, &config, &login)?;
    // The surface names a chat of this daemon boot only: the boot and the surface's chat are fixed
    // before consent, and a restart or a rebind while the prompt waits refuses the change.
    let chat = if verb == "share" { chat(&config, surface)? } else { Chat::default() };
    if grant::require_interactive(std::io::stdin().is_terminal(), std::io::stderr().is_terminal())
        .is_err()
    {
        bail!("{}", text.terminal);
    }
    if verb == "share" {
        eprint!(
            "{verb}: {surface} ({} {}), {login}, {role:?}. {} ",
            text.chat, chat.session, text.confirm
        );
    } else {
        eprint!("{verb}: {surface}, {login}, {role:?}. {} ", text.confirm);
    }
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    if !grant::confirmed(&answer) {
        bail!("{}", text.not_approved);
    }
    // Applied to the config as it is now, under its lock: a grant revoked or a share changed
    // while the prompt waited is kept, and only this one share changes.
    let lock = config::lock()?;
    let config = config::load()?;
    let now = if verb == "share" { self::chat(&config, surface)? } else { Chat::default() };
    let config = applied(verb, config, surface, &login, role, &chat, &now)?;
    // Replacements restart too: a member may have become a guest.
    config::commit(&config, &lock, config::Listener::Restart)?;
    audit::append(&json!({"decision": verb, "surface": surface, "session": chat.session,
        "login": login, "role": role}));
    println!("{}", json!({"shares": config.shares}));
    Ok(())
}

/// `config` (as it is now, read under its lock) with one confirmed change: the share of
/// `surface` to `login` replaced, or removed for `unshare`. A share is refused when `login` is no
/// longer shareable, or when the daemon boot or the surface's chat `now` is not the one
/// `consented` the prompt named.
pub(super) fn applied(
    verb: &str,
    mut config: config::Config,
    surface: u64,
    login: &str,
    role: Role,
    consented: &Chat,
    now: &Chat,
) -> anyhow::Result<config::Config> {
    shareable(verb, &config, login)?;
    if verb == "share" && (now != consented || consented.session.is_empty()) {
        bail!("{}", crate::localization::catalog().host_share.restarted);
    }
    config.shares.retain(|s| s.surface != surface || !config::same_login(&s.login, login));
    if verb == "share" {
        config.shares.push(Share {
            surface,
            login: login.to_owned(),
            role,
            shared_at: grant::now_rfc3339(),
            generation: consented.generation.clone(),
            session: consented.session.clone(),
        });
    }
    Ok(config)
}

/// Whether `login` may get a share now: a consented `agents` grant, and not a full-access
/// login (`cmux host allow` is the owner's own trust, not a teammate). Unsharing is always allowed.
fn shareable(verb: &str, config: &config::Config, login: &str) -> anyhow::Result<()> {
    let text = &crate::localization::catalog().host_share;
    if verb != "share" {
        return Ok(());
    }
    if config.allow.iter().any(|allowed| config::same_login(allowed, login)) {
        bail!("{}: {login}", text.full_access);
    }
    if !matches!(grant::check(config, login),
        grant::Check::Granted(scopes) if scopes.contains(&grant::Scope::Agents))
    {
        bail!("{}: {login}", text.grant);
    }
    Ok(())
}

/// Whether `login` may go on the full-access list (`cmux host allow`): not while it has a share,
/// of this daemon boot or an older one. A shared login is admitted through its grant and the
/// filtered proxy (admit.rs), so full access would silently not apply; the owner unshares first.
pub(super) fn allowable(config: &config::Config, login: &str) -> anyhow::Result<()> {
    if config.shares.iter().any(|share| config::same_login(&share.login, login)) {
        bail!("{}: {login}", crate::localization::catalog().host_share.shared);
    }
    Ok(())
}

/// The daemon's boot and the surface's current agent session, over the same-user socket. A
/// surface that is not an agent chat with a session cannot be shared.
fn chat(config: &config::Config, surface: u64) -> anyhow::Result<Chat> {
    let text = &crate::localization::catalog().host_share;
    let identify = daemon(config, &json!({"cmd": "identify"}))?;
    let generation = identify["data"]["generation"].as_str().unwrap_or_default();
    if generation.is_empty() {
        return Err(super::usage(text.unavailable));
    }
    let of = daemon(config, &json!({"cmd": "agent-session-of", "surface": surface}))?;
    let session = of["data"]["session"].as_str().unwrap_or_default();
    if of["ok"] != true || session.is_empty() {
        return Err(super::usage(text.not_a_chat));
    }
    Ok(Chat { generation: generation.to_owned(), session: session.to_owned() })
}

fn daemon(
    config: &config::Config,
    request: &serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    let path = cmux_tui_core::server::try_default_socket_path(
        config.session.as_deref().unwrap_or("main"),
    )?;
    let mut socket = cmux_tui_core::platform::transport::connect_same_user(&path)?;
    let timeout = Some(std::time::Duration::from_secs(5));
    socket.set_read_timeout(timeout)?;
    socket.set_write_timeout(timeout)?;
    serde_json::to_writer(&mut socket, request)?;
    socket.write_all(b"\n")?;
    let mut line = String::new();
    std::io::BufReader::new(socket).take(128 * 1024).read_line(&mut line)?;
    Ok(serde_json::from_str(&line)?)
}

//! Per-chat consent. Removing or narrowing a share closes existing links.
use std::io::{BufRead as _, IsTerminal as _, Read as _, Write as _};

use anyhow::bail;
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::{Flags, audit, config, grant, service};

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
    // The surface names a chat of this daemon boot only: the boot is fixed before consent, and a
    // restart while the prompt waits refuses the change (a reused number may be another chat).
    let generation = if verb == "share" { generation(&config)? } else { String::new() };
    if grant::require_interactive(std::io::stdin().is_terminal(), std::io::stderr().is_terminal())
        .is_err()
    {
        bail!("{}", text.terminal);
    }
    eprint!("{verb}: {surface}, {login}, {role:?}. {} ", text.confirm);
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    if !grant::confirmed(&answer) {
        bail!("{}", text.not_approved);
    }
    // Applied to the config as it is now, under its lock: a grant revoked or a share changed
    // while the prompt waited is kept, and only this one share changes.
    let lock = config::lock()?;
    let config = config::load()?;
    let now = if verb == "share" { self::generation(&config)? } else { String::new() };
    let config = applied(verb, config, surface, &login, role, &generation, &now)?;
    config::save(&config, &lock)?;
    audit::append(&json!({"decision": verb, "surface": surface, "login": login, "role": role}));
    // Restart on replacements too: a member may have become a guest.
    if service::running_pid().is_some() {
        service::restart(&super::self_exe()?, service::installed())?;
    }
    println!("{}", json!({"shares": config.shares}));
    Ok(())
}

/// `config` (as it is now, read under its lock) with one confirmed change: the share of
/// `surface` to `login` replaced, or removed for `unshare`. A share is refused when `login` is no
/// longer shareable, or when the daemon boot `now` is not the boot `consented` the prompt named.
pub(super) fn applied(
    verb: &str,
    mut config: config::Config,
    surface: u64,
    login: &str,
    role: Role,
    consented: &str,
    now: &str,
) -> anyhow::Result<config::Config> {
    shareable(verb, &config, login)?;
    if verb == "share" && now != consented {
        bail!("{}", crate::localization::catalog().host_share.restarted);
    }
    config.shares.retain(|s| s.surface != surface || !config::same_login(&s.login, login));
    if verb == "share" {
        config.shares.push(Share {
            surface,
            login: login.to_owned(),
            role,
            shared_at: grant::now_rfc3339(),
            generation: consented.to_owned(),
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

fn generation(config: &config::Config) -> anyhow::Result<String> {
    let path = cmux_tui_core::server::try_default_socket_path(
        config.session.as_deref().unwrap_or("main"),
    )?;
    let mut socket = cmux_tui_core::platform::transport::connect_same_user(&path)?;
    let timeout = Some(std::time::Duration::from_secs(5));
    socket.set_read_timeout(timeout)?;
    socket.set_write_timeout(timeout)?;
    socket.write_all(b"{\"cmd\":\"identify\"}\n")?;
    let mut line = String::new();
    std::io::BufReader::new(socket).take(128 * 1024).read_line(&mut line)?;
    let reply: serde_json::Value = serde_json::from_str(&line)?;
    reply["data"]["generation"]
        .as_str()
        .filter(|g| !g.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| super::usage(crate::localization::catalog().host_share.unavailable))
}

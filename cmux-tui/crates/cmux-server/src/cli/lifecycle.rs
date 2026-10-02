//! `install`, `uninstall`, `status`, `upgrade`, `rollback`, `pin`
//! (server.md 4.4).

use std::path::{Path, PathBuf};

use cmux_server_core::InstallMode;
use cmux_server_core::access::access_policy;
use cmux_server_core::layout::Layout;
use serde_json::{Value, json};

use super::{Args, Context, Output};
use crate::config::ServerConfig;
use crate::error::{Error, Result};
use crate::pg::{PgOptions, Postgres, WalMethod, utc_stamp};
use crate::service::Services;
use crate::store::fetch::fetch_small;
use crate::store::{ApplyReport, ApplyRequest, MANIFEST_LIMIT, Store};
use crate::{access, fsx, host, sys};

/// The default channel base; `<base>/<channel>/latest.json` or
/// `<base>/<channel>/v/<version>.json`, each with a `.sig` next to it.
pub const CHANNEL_BASE: &str = "https://cmux.com/server/channel";

/// The machine's roles for package selection (server.md 5 defaults).
pub const ROLES: &[&str] = &["server", "session", "apps", "postgres", "health", "updater"];

pub(super) fn layout(ctx: &Context<'_>, system_flag: bool) -> Result<Layout> {
    host::layout_for(host::resolve_mode(system_flag), &ctx.env)
}

pub(super) fn config(layout: &Layout) -> Result<ServerConfig> {
    ServerConfig::load(&fsx::local(&layout.config_file))
}

pub(super) fn services<'a>(ctx: &'a Context<'_>, layout: &'a Layout) -> Result<Services<'a>> {
    let uid = sys::uid();
    let user = host::current_user()?;
    Ok(Services { layout, runner: ctx.runner, uid, user })
}

pub(super) fn pg_options(args: &Args) -> PgOptions {
    PgOptions { pg_bin: args.value("pg-bin").map(PathBuf::from), cmux_bin: None }
}

/// Refuses system mode without root and user mode as root; never
/// escalates. Every verb that changes the install calls it with the
/// resolved mode.
fn check_privilege(mode: InstallMode) -> Result<()> {
    match (mode, sys::is_root()) {
        (InstallMode::System, false) => Err(Error::rejected(
            "system mode needs root; this command never escalates. Run it with sudo",
        )),
        (InstallMode::User, true) => Err(Error::rejected(
            "refusing to change a user-mode server as root; use --system or CMUX_SERVER_MODE=system",
        )),
        _ => Ok(()),
    }
}

/// The layout for a verb that changes the install, after the privilege
/// check.
pub(super) fn mutating_layout(ctx: &Context<'_>, system_flag: bool) -> Result<Layout> {
    let mode = host::resolve_mode(system_flag);
    check_privilege(mode)?;
    host::layout_for(mode, &ctx.env)
}

/// A channel name: `[a-z][a-z0-9-]{0,31}` (the manifest's channel rule).
fn valid_channel(channel: &str) -> bool {
    let b = channel.as_bytes();
    !b.is_empty()
        && b.len() <= 32
        && b[0].is_ascii_lowercase()
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

fn manifest_url(base: &str, channel: &str, version: Option<&str>) -> Result<String> {
    if !valid_channel(channel) {
        return Err(Error::usage(format!("invalid channel {channel:?}")));
    }
    let base = base.trim_end_matches('/');
    match version {
        None => Ok(format!("{base}/{channel}/latest.json")),
        Some(v)
            if !v.is_empty()
                && v.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-+".contains(&b)) =>
        {
            Ok(format!("{base}/{channel}/v/{v}.json"))
        }
        Some(v) => Err(Error::usage(format!("invalid version {v:?}"))),
    }
}

fn no_keys() -> Error {
    Error::verification(
        "this build has no baked release keys (CMUX_SERVER_RELEASE_KEYS at build time); refusing",
    )
}

/// Fetches and applies the channel manifest (or `version`).
fn apply_channel(
    ctx: &Context<'_>,
    args: &Args,
    layout: &Layout,
    cfg: &ServerConfig,
) -> Result<ApplyReport> {
    let version = args.value("version").map(str::to_owned).or_else(|| cfg.pinned_version());
    let base = args.value("channel-url").unwrap_or(CHANNEL_BASE);
    let channel = cfg.channel();
    let url = manifest_url(base, &channel, version.as_deref())?;
    if ctx.keys.is_empty() {
        return Err(no_keys());
    }
    ctx.with_fetcher(|fetcher| {
        let manifest = fetch_small(fetcher, &url, MANIFEST_LIMIT)?;
        let signature = fetch_small(fetcher, &format!("{url}.sig"), 1024)?;
        let request = ApplyRequest {
            manifest: &manifest,
            signature: &signature,
            keys: &ctx.keys,
            channel: &channel,
            running_cmux: &ctx.running_cmux,
            roles: ROLES,
            now_ms: ctx.now_ms,
        };
        Store::new(layout).apply(&request, fetcher)
    })
}

/// `~/.local/bin/cmux` -> `<current>/bin/cmux`, unless something else is
/// there (then a warning; never clobbered).
fn ensure_shim(layout: &Layout, warnings: &mut Vec<String>) -> Result<()> {
    let shim = fsx::local(&layout.cli_shim);
    let target = fsx::local(&layout.current_cmux);
    match std::fs::read_link(&shim) {
        Ok(existing) if existing == target => return Ok(()),
        Ok(_) | Err(_) if fsx::exists_no_follow(&shim) => {
            warnings.push(format!("{} exists and is not our shim; left as is", shim.display()));
            return Ok(());
        }
        _ => {}
    }
    if let Some(dir) = shim.parent() {
        fsx::ensure_dir(dir, 0o755)?;
    }
    fsx::swap_symlink(&shim, &target)
}

fn report_json(report: &ApplyReport) -> Value {
    json!({
        "from": report.from, "to": report.to, "changed": report.changed,
        "reapply": report.reapply, "fetched": report.fetched, "store_hits": report.store_hits,
        "removed_profiles": report.removed_profiles, "removed_packages": report.removed_packages,
    })
}

pub fn install(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, args.has("system"))?;
    let mode = layout.mode;
    if ctx.keys.is_empty() {
        return Err(no_keys());
    }
    if let Some(channel) = args.value("channel")
        && !valid_channel(channel)
    {
        return Err(Error::usage(format!("invalid channel {channel:?}")));
    }
    access::ensure(&access_policy(&layout), ctx.runner)?;
    let mut cfg = config(&layout)?;
    let (_, new_id) = cfg.ensure_install_id()?;
    let channel_changed = args.value("channel").is_some_and(|c| c != cfg.channel());
    if let Some(channel) = args.value("channel") {
        cfg.set_channel(channel);
    }
    if new_id || channel_changed {
        cfg.save()?;
    }
    let report = apply_channel(ctx, args, &layout, &cfg)?;
    let mut warnings = Vec::new();
    ensure_shim(&layout, &mut warnings)?;
    let svc = services(ctx, &layout)?;
    // The service restarts for a new generation here, and for a changed
    // unit inside `install`.
    let service = svc.install(report.changed)?;
    warnings.extend(service.warnings.iter().cloned());
    let changed = report.changed || service.changed;
    let json = json!({
        "installed": true, "generation": report.to, "unit": service.unit, "changed": changed,
        "mode": host::mode_str(mode), "store": report_json(&report), "linger": service.linger,
        "restarted": service.restarted, "warnings": warnings,
    });
    let mut human = format!(
        "cmux server: generation {} ({}), unit {}{}\n",
        report.to,
        if changed { "changed" } else { "no change" },
        service.unit.display(),
        if service.restarted { ", restarted" } else { "" }
    );
    for w in &warnings {
        human.push_str(&format!("warning: {w}\n"));
    }
    Ok(Output::new(json, human))
}

/// The final backup before `--purge` (server.md 4.4): self-contained
/// (`-X stream`), because the WAL archive is deleted with the state.
fn final_backup(ctx: &Context<'_>, args: &Args, layout: &Layout) -> Result<Option<PathBuf>> {
    let cfg = config(layout)?;
    if !fsx::local(&layout.postgres_data()).join("PG_VERSION").is_file() {
        return Ok(None);
    }
    let pg = Postgres::open_existing(layout, ctx.runner, &cfg, &pg_options(args)).map_err(|e| {
        Error::new(
            e.kind,
            format!("cannot take the final backup ({e}); pass --no-backup to skip it"),
        )
    })?;
    let cwd = std::env::current_dir().map_err(|e| Error::io("current directory", e))?;
    let dest = final_backup_dest(&cwd, &fsx::local(&layout.state), ctx.now_ms)?;
    pg.ensure_cluster()?;
    let path = pg.basebackup(&dest, WalMethod::Stream)?;
    Ok(Some(path))
}

/// `<cwd>/cmux-server-final-backup-<stamp>`, refused when `cwd` is inside
/// the state directory that `--purge` is about to delete.
pub(super) fn final_backup_dest(cwd: &Path, state: &Path, now_ms: u64) -> Result<PathBuf> {
    let real = |p: &Path| std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
    if real(cwd).starts_with(real(state)) {
        return Err(Error::rejected(format!(
            "the final backup would land in {}, which --purge deletes; run from another directory",
            cwd.display()
        )));
    }
    Ok(cwd.join(format!("cmux-server-final-backup-{}", utc_stamp(now_ms))))
}

/// The pid in `postmaster.pid` when that process is alive.
fn live_postmaster(layout: &Layout) -> Option<u32> {
    let text =
        std::fs::read_to_string(fsx::local(&layout.postgres_data()).join("postmaster.pid")).ok()?;
    let pid: u32 = text.lines().next()?.trim().parse().ok()?;
    sys::process_alive(pid).then_some(pid)
}

/// Runs before anything is removed. A live postmaster that this command
/// cannot stop (no Postgres binaries, or system mode) blocks `--purge`,
/// which would delete its data directory under it; without `--purge` it is
/// left running and reported.
fn postgres_guard(
    ctx: &Context<'_>,
    args: &Args,
    layout: &Layout,
    purge: bool,
) -> Result<Option<String>> {
    let Some(pid) = live_postmaster(layout) else { return Ok(None) };
    let cfg = config(layout)?;
    let Err(e) = Postgres::open_existing(layout, ctx.runner, &cfg, &pg_options(args)) else {
        return Ok(None);
    };
    let message = format!("Postgres (pid {pid}) is running and this command cannot stop it ({e})");
    if purge {
        return Err(Error::rejected(format!("{message}; stop it first or pass --pg-bin <dir>")));
    }
    Ok(Some(format!("{message}; it is left running")))
}

fn stop_postgres(ctx: &Context<'_>, args: &Args, layout: &Layout) -> Result<()> {
    if !fsx::local(&layout.postgres_data()).join("PG_VERSION").is_file() {
        return Ok(());
    }
    let cfg = config(layout)?;
    match Postgres::open_existing(layout, ctx.runner, &cfg, &pg_options(args)) {
        Ok(pg) => pg.stop().map(|_| ()),
        // `postgres_guard` already refused or reported a live cluster that
        // this command cannot stop.
        Err(_) => Ok(()),
    }
}

pub fn uninstall(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, false)?;
    let purge = args.has("purge");
    let warning = postgres_guard(ctx, args, &layout, purge)?;
    let backup =
        if purge && !args.has("no-backup") { final_backup(ctx, args, &layout)? } else { None };
    let svc = services(ctx, &layout)?;
    let mut removed: Vec<PathBuf> = svc.uninstall()?;
    stop_postgres(ctx, args, &layout)?;
    let shim = fsx::local(&layout.cli_shim);
    if std::fs::read_link(&shim).is_ok_and(|t| t == fsx::local(&layout.current_cmux)) {
        fsx::remove_tree(&shim)?;
        removed.push(shim);
    }
    let store = Store::new(&layout);
    store.remove_all()?;
    removed.extend([store.store, store.profiles, store.current]);
    let state = fsx::local(&layout.state);
    let kept_state = if purge {
        fsx::remove_tree(&state)?;
        fsx::remove_tree(&fsx::local(&layout.config_file))?;
        removed.push(state);
        None
    } else {
        Some(state)
    };
    let warnings: Vec<String> = warning.into_iter().collect();
    let json = json!({"removed": removed, "kept_state": kept_state, "backup": backup, "warnings": warnings});
    let mut human = String::from("cmux server: uninstalled\n");
    for w in &warnings {
        human.push_str(&format!("warning: {w}\n"));
    }
    if let Some(path) = &kept_state {
        human.push_str(&format!("kept state: {}\n", path.display()));
    }
    if let Some(path) = &backup {
        human.push_str(&format!("final backup: {}\n", path.display()));
    }
    Ok(Output::new(json, human))
}

fn postgres_state(layout: &Layout) -> &'static str {
    let data = fsx::local(&layout.postgres_data());
    match (data.join("PG_VERSION").is_file(), data.join("postmaster.pid").is_file()) {
        (false, _) => "absent",
        (true, true) => "running",
        (true, false) => "stopped",
    }
}

pub fn status(ctx: &Context<'_>, _args: &Args) -> Result<Output> {
    let layout = layout(ctx, false)?;
    let cfg = config(&layout)?;
    let store = Store::new(&layout);
    let generation = store.current_generation();
    let entries = store.current_entries().unwrap_or_default();
    let version = entries.iter().find(|e| e.name == "cmux").map(|e| e.version.clone());
    let service = services(ctx, &layout)?.state();
    let last = store.last_applied()?.map(|a| a.sequence);
    let json = json!({
        "enabled": service.installed, "mode": host::mode_str(layout.mode),
        "store": {"generation": generation, "version": version, "channel": cfg.channel(),
            "pinned": cfg.pinned_version(), "generations": store.generations(),
            "last_applied_sequence": last, "packages": entries},
        "service": {"installed": service.installed, "active": service.active, "enabled": service.enabled},
        "postgres": {"port": cfg.postgres_port(), "state": postgres_state(&layout)},
        "roles": [], "apps": [], "alerts": [],
    });
    let human = format!(
        "cmux server ({})\n  generation: {}\n  version:    {}\n  channel:    {}{}\n  service:    {}\n  postgres:   {} (port {})\n",
        host::mode_str(layout.mode),
        generation.map_or("none".to_owned(), |g| g.to_string()),
        version.as_deref().unwrap_or("-"),
        cfg.channel(),
        cfg.pinned_version().map(|v| format!(" (pinned {v})")).unwrap_or_default(),
        match service.active {
            Some(true) => "active",
            Some(false) => "inactive",
            None => "unknown",
        },
        postgres_state(&layout),
        cfg.postgres_port().map_or("-".to_owned(), |p| p.to_string()),
    );
    Ok(Output::new(json, human))
}

fn restart_if(ctx: &Context<'_>, layout: &Layout, changed: bool) -> Result<Vec<String>> {
    if !changed {
        return Ok(Vec::new());
    }
    let svc = services(ctx, layout)?;
    if !svc.state().installed {
        return Ok(Vec::new());
    }
    svc.restart()?;
    Ok(vec!["cmux-server".to_owned()])
}

pub fn upgrade(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, false)?;
    if args.has("generation") && args.has("version") {
        return Err(Error::usage("pass --version or --generation, not both"));
    }
    let (from, to, changed) = match args.number("generation")? {
        Some(g) => {
            let flip = Store::new(&layout).switch_to(g)?;
            (flip.from, flip.to, flip.from != Some(flip.to))
        }
        None => {
            let report = apply_channel(ctx, args, &layout, &config(&layout)?)?;
            (report.from, report.to, report.changed)
        }
    };
    let restarted = restart_if(ctx, &layout, changed)?;
    let json = json!({"from": from, "to": to, "restarted": restarted});
    let human = format!(
        "cmux server: generation {} -> {to}{}\n",
        from.map_or("none".to_owned(), |g| g.to_string()),
        if restarted.is_empty() { "" } else { " (restarted)" }
    );
    Ok(Output::new(json, human))
}

pub fn rollback(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, false)?;
    let flip = Store::new(&layout).rollback(args.number("generation")?)?;
    restart_if(ctx, &layout, flip.from != Some(flip.to))?;
    let json = json!({"from": flip.from, "to": flip.to});
    let human = format!(
        "cmux server: rolled back {} -> {}\n",
        flip.from.map_or("none".to_owned(), |g| g.to_string()),
        flip.to
    );
    Ok(Output::new(json, human))
}

pub fn pin(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, false)?;
    let mut cfg = config(&layout)?;
    let pinned = match (args.positionals.first(), args.has("clear")) {
        (Some(_), true) | (None, false) => {
            return Err(Error::usage("usage: cmux server pin <version> | --clear"));
        }
        (Some(v), false) => {
            cmux_server_core::manifest::SemVer::parse(v)
                .ok_or_else(|| Error::usage(format!("invalid version {v:?}")))?;
            Some(v.clone())
        }
        (None, true) => None,
    };
    cfg.set_pinned_version(pinned.as_deref());
    cfg.save()?;
    let human = match &pinned {
        Some(v) => format!("cmux server: pinned {v}\n"),
        None => "cmux server: pin cleared\n".to_owned(),
    };
    Ok(Output::new(json!({"pinned": pinned}), human))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn final_backup_never_lands_in_the_state_it_purges() {
        let tmp = tempfile::tempdir().unwrap();
        let state = tmp.path().join("state");
        std::fs::create_dir_all(state.join("sub")).unwrap();
        assert!(final_backup_dest(&state, &state, 0).is_err());
        assert!(final_backup_dest(&state.join("sub"), &state, 0).is_err());
        let ok = final_backup_dest(tmp.path(), &state, 0).unwrap();
        assert_eq!(ok, tmp.path().join("cmux-server-final-backup-19700101T000000Z"));
    }

    #[test]
    fn channel_names_follow_the_manifest_rule() {
        assert!(valid_channel("stable") && valid_channel("beta-2"));
        for bad in ["", "Beta", "2beta", "a b", "../x", &"a".repeat(33)] {
            assert!(!valid_channel(bad), "{bad:?}");
        }
    }
}

//! `install`, `uninstall`, `status`, `upgrade`, `rollback`, `pin`
//! (server.md 4.4).

use std::path::PathBuf;

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

/// Refuses `--system` without root and user mode as root; never escalates.
fn check_privilege(mode: InstallMode) -> Result<()> {
    match (mode, sys::is_root()) {
        (InstallMode::System, false) => Err(Error::rejected(
            "--system needs root; this command never escalates. Run: sudo <this cmux> server install --system",
        )),
        (InstallMode::User, true) => {
            Err(Error::rejected("refusing to install a user-mode server as root; use --system"))
        }
        _ => Ok(()),
    }
}

fn manifest_url(base: &str, channel: &str, version: Option<&str>) -> Result<String> {
    if !channel.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') {
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
    let mode = host::resolve_mode(args.has("system"));
    check_privilege(mode)?;
    let layout = host::layout_for(mode, &ctx.env)?;
    if ctx.keys.is_empty() {
        return Err(no_keys());
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
    let service = svc.install(report.changed && report.from.is_some())?;
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
    let mut cfg = config(layout)?;
    if !fsx::local(&layout.postgres_data()).join("PG_VERSION").is_file() {
        return Ok(None);
    }
    let pg = Postgres::open(layout, ctx.runner, &mut cfg, &pg_options(args)).map_err(|e| {
        Error::new(
            e.kind,
            format!("cannot take the final backup ({e}); pass --no-backup to skip it"),
        )
    })?;
    pg.ensure_cluster()?;
    let cwd = std::env::current_dir().map_err(|e| Error::io("current directory", e))?;
    let dest = cwd.join(format!("cmux-server-final-backup-{}", utc_stamp(ctx.now_ms)));
    let path = pg.basebackup(&dest, WalMethod::Stream)?;
    Ok(Some(path))
}

fn stop_postgres(ctx: &Context<'_>, args: &Args, layout: &Layout) -> Result<()> {
    if !fsx::local(&layout.postgres_data()).join("PG_VERSION").is_file() {
        return Ok(());
    }
    let mut cfg = config(layout)?;
    match Postgres::open(layout, ctx.runner, &mut cfg, &pg_options(args)) {
        Ok(pg) => pg.stop().map(|_| ()),
        // No binaries left to stop it with: the cluster cannot be running
        // from this install's store either way.
        Err(e) if e.kind == crate::error::ExitKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn uninstall(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = layout(ctx, false)?;
    let purge = args.has("purge");
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
    let json = json!({"removed": removed, "kept_state": kept_state, "backup": backup});
    let mut human = String::from("cmux server: uninstalled\n");
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
    let layout = layout(ctx, false)?;
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
    let layout = layout(ctx, false)?;
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
    let layout = layout(ctx, false)?;
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

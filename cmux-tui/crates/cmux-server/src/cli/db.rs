//! `db create|url|archive-wal|backup` (server.md 8) and `health`
//! (server.md 9).

use std::path::{Path, PathBuf};

use cmux_server_core::health::{CheckId, HostId, fixes_for};
use cmux_server_core::pg::{AppDb, AppId, DbMode};
use cmux_server_core::{InstallMode, Platform};
use serde_json::{Value, json};

use super::lifecycle::{config, layout, mutating_layout, pg_options};
use super::{Args, Context, Output};
use crate::error::{Error, Result};
use crate::fsx;
use crate::health::{HealthRole, MemorySink, ProbeInput, collect, inhibit};
use crate::pg::{Postgres, archive_wal as archive};

/// `notes` (an app id) or `publisher/name` (a manifest id, mapped).
fn app_id(text: &str) -> Result<(AppId, Option<String>)> {
    if text.contains('/') {
        let id = AppId::from_manifest_id(text)
            .map_err(|e| Error::usage(format!("invalid app id {text:?}: {e:?}")))?;
        return Ok((id, Some(text.to_owned())));
    }
    let id =
        AppId::parse(text).map_err(|e| Error::usage(format!("invalid app id {text:?}: {e:?}")))?;
    Ok((id, None))
}

pub fn create(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, false)?;
    let mut cfg = config(&layout)?;
    let (id, manifest_id) = app_id(&args.positionals[0])?;
    let mode = match args.value("mode") {
        None => DbMode::Database,
        Some(m) => crate::pg::parse_mode(m)
            .ok_or_else(|| Error::usage(format!("--mode takes database or schema, got {m:?}")))?,
    };
    let pg = Postgres::open(&layout, ctx.runner, &mut cfg, &pg_options(args))?;
    pg.ensure_cluster()?;
    let report = pg.ensure_app(&AppDb { id, mode, tcp: false }, manifest_id.as_deref())?;
    let json = json!({
        "app": report.app, "url": report.url, "created": report.created_role || report.created_database,
        "mode": if mode == DbMode::Schema { "schema" } else { "database" },
    });
    Ok(Output::new(json, format!("{}\n", report.url)))
}

pub fn url(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = layout(ctx, false)?;
    let mut cfg = config(&layout)?;
    let (id, _) = app_id(&args.positionals[0])?;
    let pg = Postgres::open(&layout, ctx.runner, &mut cfg, &pg_options(args))?;
    let url = pg.url(&pg.find_app(&id)?);
    Ok(Output::new(json!({"url": url}), format!("{url}\n")))
}

/// Postgres's `archive_command`. The WAL directory comes from
/// `CMUX_SERVER_WAL_DIR` (set by the runner on the postmaster), else the
/// layout.
pub fn archive_wal(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let wal_dir = match std::env::var_os("CMUX_SERVER_WAL_DIR") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => fsx::local(&layout(ctx, false)?.wal_archive()),
    };
    let (src, name) = (Path::new(&args.positionals[0]), &args.positionals[1]);
    let outcome = archive(&wal_dir, src, name)?;
    let stored = matches!(outcome, crate::pg::Archived::Stored);
    Ok(Output::new(json!({"archived": name, "stored": stored}), String::new()))
}

pub fn backup(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = mutating_layout(ctx, false)?;
    let mut cfg = config(&layout)?;
    let pg = Postgres::open(&layout, ctx.runner, &mut cfg, &pg_options(args))?;
    pg.ensure_cluster()?;
    let path = pg.backup_now(ctx.now_ms)?;
    let wal_last = pg.last_wal();
    let json = json!({"base_backup": path, "wal_last": wal_last});
    Ok(Output::new(json, format!("{}\n", path.display())))
}

fn alert_json(
    check: CheckId,
    subject: Option<&str>,
    severity: &str,
    mode: (Platform, InstallMode),
) -> Value {
    let fixes: Vec<Value> = fixes_for(check, mode.0, mode.1)
        .map(|f| json!({"id": f.id, "title_key": f.title_key, "needs_admin": f.needs_admin}))
        .collect();
    json!({"check": check.as_str(), "subject": subject, "severity": severity,
        "title_key": check.title_key(), "fixes": fixes})
}

pub fn health(ctx: &Context<'_>, args: &Args) -> Result<Output> {
    let layout = layout(ctx, false)?;
    let cfg = config(&layout)?;
    let host_id = cfg
        .install_id()
        .and_then(HostId::parse)
        .unwrap_or_else(|| HostId::parse("inst_local").expect("valid literal"));
    let inhibitors = (layout.platform == Platform::Linux).then(inhibit::probe_all);
    let input = ProbeInput { link_up: args.has("link-up"), inhibitors };
    let facts = collect(&layout, host_id, ctx.runner, &input);
    let mut role = HealthRole::new();
    role.observe(&facts, ctx.now_ms, &MemorySink::default());
    let mode = (layout.platform, layout.mode);
    let alerts: Vec<Value> = role
        .alerts()
        .alerts()
        .iter()
        .map(|(k, a)| alert_json(k.check, k.subject.as_deref(), a.severity.as_str(), mode))
        .collect();
    let pending: Vec<Value> = role
        .alerts()
        .pending()
        .iter()
        .map(|(k, since)| json!({"check": k.check.as_str(), "since_ms": since}))
        .collect();
    let disk =
        facts.disk.map(|d| json!({"free_bytes": d.free_bytes, "total_bytes": d.total_bytes}));
    let power = facts.power.map(|p| {
        json!({"on_battery": p.source == cmux_server_core::health::PowerSource::Battery,
            "battery_percent": p.battery_percent})
    });
    let inhibit = facts.inhibitors.map(
        |i| json!({"idle": i.idle, "sleep": i.sleep, "handle_lid_switch": i.handle_lid_switch}),
    );
    let json = json!({
        "alerts": alerts, "pending": pending, "wake_at_ms": role.wake_at_ms(),
        "facts": {"disk": disk, "power": power, "link_up": facts.link_up,
            "has_route": facts.has_route, "linger": facts.linger, "inhibitors": inhibit,
            "power_assertions": if cfg!(target_os = "macos") { "unsupported" } else { "n/a" }},
    });
    let mut human = String::new();
    if alerts.is_empty() {
        human.push_str("cmux server health: no alerts\n");
    }
    for (key, alert) in role.alerts().alerts() {
        human.push_str(&format!("{:9} {}\n", alert.severity.as_str(), key.check.as_str()));
    }
    Ok(Output::new(json, human))
}

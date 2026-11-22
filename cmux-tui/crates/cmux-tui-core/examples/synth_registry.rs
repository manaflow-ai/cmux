//! Writes a synthetic workspace registry shaped like a long-lived owner's
//! (`cmux_tui_core::synth_registry`), then prints what it wrote as one JSON
//! line on stdout.
//!
//! ```sh
//! cargo run --release -p cmux-tui-core --example synth_registry -- \
//!   --out /tmp/synth/sessions --session synth \
//!   --session-puts 1500000 --agent-events 60000 --output-bytes 0 \
//!   --seal --roster-version-bump
//! ```
//!
//! `--out` is the state root an owner later opens (`CMUX_TUI_STATE_DIR`);
//! the session must not exist there yet. About 96% session puts of ~6 KiB
//! each is the 2026-11-09 shape: rows x 6.3 KiB is about the file size, so
//! 1.6M puts make about 10 GB. Options:
//!
//! - `--session NAME` (default `synth`)
//! - `--session-puts N`, `--agent-events M`, `--output-bytes B` (legacy
//!   `terminal.output` content, in 4 KiB rows)
//! - `--workspaces W` (default 4), `--payload-bytes P` (default 6144)
//! - `--batch-rows R` rows per transaction (default 20000)
//! - `--seal`: seal the first half of the journal into segments
//! - `--seal-segments N`: seal about N full segments (1,024 records each)
//!   instead, capped at the whole journal
//! - `--roster-version-bump`: write the roster snapshot one version behind,
//!   so the next start re-folds the whole journal
//! - `--quiet`: no progress on stderr
//!
//! Modes for an existing registry (`daemon-registry-start.sh
//! registry=`), which write no rows:
//!
//! - `--print-registry-path`: print the registry path an owner of
//!   `--session` opens below `--out`, and exit
//! - `--print-roster-version`: print the current roster reducer version
//! - `--rebind-pepper --out ROOT --registry PATH`: write a new resource
//!   receipt pepper in ROOT and bind that registry to it
//!   (`synth_registry::rebind_resource_pepper`), for a copy whose own
//!   pepper is not at hand. Only on a copy
//! - `--bump-only --registry PATH`: set that registry's roster snapshot one
//!   version behind (`synth_registry::bump_roster_version`), and print
//!   `{"roster_version_before":V|null,"roster_version":V,...}`. Only on a
//!   copy: it writes to the file.
//! - `--trees --registry PATH`: print the pages and the bytes of each b-tree
//!   of that registry (`dbstat`), the largest first, with the file's page
//!   size, page count and free pages, as one JSON line. Read only: names of
//!   tables and indexes and sizes, no row. It reads the whole file.

use std::path::{Path, PathBuf};

use cmux_tui_core::synth_registry::{
    ROSTER_REDUCER_VERSION, SynthOptions, bump_roster_version, generate, rebind_resource_pepper,
    registry_path,
};
use rusqlite::{Connection, OpenFlags};

/// The b-trees of the registry at `registry` and its free pages (`--trees`).
fn trees(registry: &Path) -> anyhow::Result<serde_json::Value> {
    let connection = Connection::open_with_flags(registry, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let pragma = |name: &str| -> rusqlite::Result<i64> {
        connection.query_row(&format!("PRAGMA {name}"), [], |row| row.get(0))
    };
    // One row for each b-tree: `pageno` is then the count of its pages, and
    // the other columns are sums over them.
    let mut statement = connection.prepare(
        "SELECT name, pageno, pgsize, payload, unused FROM dbstat WHERE aggregate = TRUE
         ORDER BY pgsize DESC, name",
    )?;
    let trees = statement
        .query_map([], |row| {
            Ok(serde_json::json!({
                "name": row.get::<_, String>(0)?,
                "pages": row.get::<_, i64>(1)?,
                "bytes": row.get::<_, i64>(2)?,
                "payload_bytes": row.get::<_, i64>(3)?,
                "unused_bytes": row.get::<_, i64>(4)?,
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(serde_json::json!({
        "page_size": pragma("page_size")?,
        "page_count": pragma("page_count")?,
        "freelist_count": pragma("freelist_count")?,
        "trees": trees,
    }))
}

fn main() -> anyhow::Result<()> {
    let mut options = SynthOptions { progress: true, ..SynthOptions::default() };
    let mut out = None;
    let mut registry = None;
    let (mut print_registry_path, mut bump_only, mut rebind_pepper) = (false, false, false);
    let mut trees_only = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| anyhow::anyhow!("{arg} needs a value"));
        match arg.as_str() {
            "--out" => out = Some(PathBuf::from(value()?)),
            "--session" => options.session = value()?,
            "--session-puts" => options.session_puts = value()?.parse()?,
            "--agent-events" => options.agent_events = value()?.parse()?,
            "--output-bytes" => options.output_bytes = value()?.parse()?,
            "--workspaces" => options.workspaces = value()?.parse()?,
            "--payload-bytes" => options.payload_bytes = value()?.parse()?,
            "--batch-rows" => options.batch_rows = value()?.parse()?,
            "--seal" => options.seal = true,
            "--seal-segments" => options.seal_segments = Some(value()?.parse()?),
            "--roster-version-bump" => options.roster_version_bump = true,
            "--quiet" => options.progress = false,
            "--registry" => registry = Some(PathBuf::from(value()?)),
            "--print-registry-path" => print_registry_path = true,
            "--bump-only" => bump_only = true,
            "--rebind-pepper" => rebind_pepper = true,
            "--trees" => trees_only = true,
            "--print-roster-version" => {
                println!("{ROSTER_REDUCER_VERSION}");
                return Ok(());
            }
            other => anyhow::bail!("unknown option {other} (see the example's doc comment)"),
        }
    }
    if trees_only {
        let registry = registry.ok_or_else(|| anyhow::anyhow!("--trees needs --registry"))?;
        println!("{}", trees(&registry)?);
        return Ok(());
    }
    if bump_only {
        let registry = registry.ok_or_else(|| anyhow::anyhow!("--bump-only needs --registry"))?;
        let before = bump_roster_version(&registry)?;
        let after = before.map(|_| ROSTER_REDUCER_VERSION - 1);
        println!(
            "{}",
            serde_json::json!({
                "roster_version_before": before,
                "roster_version": after,
                "roster_current_version": ROSTER_REDUCER_VERSION,
            })
        );
        return Ok(());
    }
    let out = out.ok_or_else(|| anyhow::anyhow!("--out DIR is required"))?;
    if rebind_pepper {
        let registry =
            registry.ok_or_else(|| anyhow::anyhow!("--rebind-pepper needs --registry"))?;
        return rebind_resource_pepper(&out, &registry);
    }
    if print_registry_path {
        println!("{}", registry_path(&out, &options.session).display());
        return Ok(());
    }
    std::fs::create_dir_all(&out)?;
    let report = generate(&out, &options)?;
    println!("{}", report.to_json());
    Ok(())
}

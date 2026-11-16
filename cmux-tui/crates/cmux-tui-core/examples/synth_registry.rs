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
//! Two modes for an existing registry (`daemon-registry-start.sh
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

use std::path::PathBuf;

use cmux_tui_core::synth_registry::{
    ROSTER_REDUCER_VERSION, SynthOptions, bump_roster_version, generate, rebind_resource_pepper,
    registry_path,
};

fn main() -> anyhow::Result<()> {
    let mut options = SynthOptions { progress: true, ..SynthOptions::default() };
    let mut out = None;
    let mut registry = None;
    let (mut print_registry_path, mut bump_only, mut rebind_pepper) = (false, false, false);
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
            "--print-roster-version" => {
                println!("{ROSTER_REDUCER_VERSION}");
                return Ok(());
            }
            other => anyhow::bail!("unknown option {other} (see the example's doc comment)"),
        }
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

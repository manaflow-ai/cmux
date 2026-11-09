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
//! - `--roster-version-bump`: write the roster snapshot one version behind,
//!   so the next start re-folds the whole journal
//! - `--quiet`: no progress on stderr

use std::path::PathBuf;

use cmux_tui_core::synth_registry::{SynthOptions, generate};

fn main() -> anyhow::Result<()> {
    let mut options = SynthOptions { progress: true, ..SynthOptions::default() };
    let mut out = None;
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
            "--roster-version-bump" => options.roster_version_bump = true,
            "--quiet" => options.progress = false,
            other => anyhow::bail!("unknown option {other} (see the example's doc comment)"),
        }
    }
    let out = out.ok_or_else(|| anyhow::anyhow!("--out DIR is required"))?;
    std::fs::create_dir_all(&out)?;
    let report = generate(&out, &options)?;
    println!("{}", report.to_json());
    Ok(())
}

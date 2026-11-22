//! `cmux-duress`: writes the offline duress simulator's replay files.
//!
//! ```text
//! cmux-duress gen --spec SPEC --out DIR [--pty FILE] [--chat FILE] [--repo ROOT]
//! cmux-duress presets
//! ```
//!
//! SPEC is `PRESET[,knob=value...]` (`heavy,link=2g-trickle,cpu_threads=6`). The recordings
//! default to the repository's fixtures under ROOT, which defaults to the nearest folder at or
//! above the working directory that holds `cmux-tui/`.

use std::path::PathBuf;
use std::process::ExitCode;

use cmux_duress::{Inputs, Knobs, inputs};

const USAGE: &str = "usage:
  cmux-duress gen --spec PRESET[,knob=value...] --out DIR [--pty FILE] [--chat FILE] [--repo ROOT]
  cmux-duress presets";

fn main() -> ExitCode {
    match run(std::env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("cmux-duress: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: Vec<String>) -> Result<(), String> {
    let mut args = args.into_iter();
    match args.next().as_deref() {
        Some("presets") => {
            print!("{}", cmux_duress::knobs::presets_table());
            Ok(())
        }
        Some("gen") => generate(args),
        Some("-h" | "--help") => {
            println!("{USAGE}");
            Ok(())
        }
        _ => Err(USAGE.to_owned()),
    }
}

fn generate(mut args: impl Iterator<Item = String>) -> Result<(), String> {
    let (mut spec, mut out, mut pty, mut chat, mut repo) = (None, None, None, None, None);
    while let Some(flag) = args.next() {
        let slot = match flag.as_str() {
            "--spec" => &mut spec,
            "--out" => &mut out,
            "--pty" => &mut pty,
            "--chat" => &mut chat,
            "--repo" => &mut repo,
            other => return Err(format!("unknown flag {other}\n{USAGE}")),
        };
        *slot = Some(args.next().ok_or_else(|| format!("{flag} needs a value"))?);
    }
    let spec = spec.ok_or_else(|| format!("--spec is required\n{USAGE}"))?;
    let out = PathBuf::from(out.ok_or_else(|| format!("--out is required\n{USAGE}"))?);
    let knobs = Knobs::parse(&spec)?;
    let repo = match repo {
        Some(repo) => PathBuf::from(repo),
        None => {
            let cwd = std::env::current_dir().map_err(|error| error.to_string())?;
            cmux_duress::find_repo(&cwd).ok_or_else(|| {
                format!("no folder holding cmux-tui/ at or above {}; pass --repo", cwd.display())
            })?
        }
    };
    let pty = pty.map_or_else(|| repo.join(inputs::DEFAULT_PTY), PathBuf::from);
    let chat = chat.map_or_else(|| repo.join(inputs::DEFAULT_CHAT), PathBuf::from);
    let inputs = Inputs::load(&pty, &chat)?;
    let generated = cmux_duress::generate(&knobs, &inputs)?;
    let counts = generated.write(&out, &inputs)?;
    println!("{}", cmux_duress::summary(&out, &knobs, &counts));
    Ok(())
}

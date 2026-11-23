//! `cmux-duress`: writes the offline duress simulator's replay files.
//!
//! ```text
//! cmux-duress gen --spec SPEC --out DIR [--pty FILE] [--chat FILE] [--repo ROOT]
//! cmux-duress presets
//! cmux-duress scenario list [--dir DIR]
//! cmux-duress scenario run NAME|all [--sim] [--dir DIR] [--repo ROOT]
//!     [--spec SPEC] [--link NAME] [--path terminal|projection] [--cols N] [--coalesce-ms MS]
//!     [--phone-event-ms MS] [--merge-ready]
//! ```
//!
//! `scenario run` replays a named scenario (`scenarios/NAME.toml`) headless through the phone's
//! Rust paths and prints its verdict for people on stderr and one JSON line on stdout; it exits 1
//! when a check fails. `--sim` prints the iOS sim step's arguments instead.
//!
//! SPEC is `PRESET[,knob=value...]` (`heavy,link=2g-trickle,cpu_threads=6`). The recordings
//! default to the repository's fixtures under ROOT, which defaults to the nearest folder at or
//! above the working directory that holds `cmux-tui/`.

use std::path::PathBuf;
use std::process::ExitCode;

use cmux_duress::{Inputs, Knobs, inputs, scenario};

const USAGE: &str = "usage:
  cmux-duress gen --spec PRESET[,knob=value...] --out DIR [--pty FILE] [--chat FILE] [--repo ROOT]
  cmux-duress presets
  cmux-duress scenario list [--dir DIR]
  cmux-duress scenario run NAME|all [--sim] [--dir DIR] [--repo ROOT]
      [--spec SPEC] [--link NAME] [--path terminal|projection] [--cols N] [--coalesce-ms MS]
      [--phone-event-ms MS] [--merge-ready]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("scenario") {
        return match scenario(args.into_iter().skip(1)) {
            Ok(true) => ExitCode::SUCCESS,
            Ok(false) => ExitCode::FAILURE,
            Err(error) => {
                eprintln!("cmux-duress: {error}");
                ExitCode::from(2)
            }
        };
    }
    match run(args) {
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
    let repo = repo_root(repo)?;
    let pty = pty.map_or_else(|| repo.join(inputs::DEFAULT_PTY), PathBuf::from);
    let chat = chat.map_or_else(|| repo.join(inputs::DEFAULT_CHAT), PathBuf::from);
    let inputs = Inputs::load(&pty, &chat)?;
    let generated = cmux_duress::generate(&knobs, &inputs)?;
    let counts = generated.write(&out, &inputs)?;
    println!("{}", cmux_duress::summary(&out, &knobs, &counts));
    Ok(())
}

/// `--repo`, else the nearest folder at or above the working directory holding `cmux-tui/`, else
/// the checkout this binary was built from.
fn repo_root(repo: Option<String>) -> Result<PathBuf, String> {
    if let Some(repo) = repo {
        return Ok(PathBuf::from(repo));
    }
    let cwd = std::env::current_dir().map_err(|error| error.to_string())?;
    cmux_duress::find_repo(&cwd)
        .or_else(|| cmux_duress::find_repo(std::path::Path::new(env!("CARGO_MANIFEST_DIR"))))
        .ok_or_else(|| {
            format!("no folder holding cmux-tui/ at or above {}; pass --repo", cwd.display())
        })
}

/// `scenario list|run`. `Ok(false)`: a check failed.
fn scenario(mut args: impl Iterator<Item = String>) -> Result<bool, String> {
    let verb = args.next().unwrap_or_default();
    let (mut name, mut dir, mut repo, mut sim) = (None, None, None, false);
    // Overrides of each scenario's own fields: the same case under another link, path or width.
    let (mut spec, mut path, mut cols, mut coalesce_ms) = (None, None, None, None);
    let mut link: Option<String> = None;
    let (mut phone_event_ms, mut merge_ready) = (None, false);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--sim" => sim = true,
            "--spec" => spec = Some(args.next().ok_or("--spec needs a value")?),
            "--link" => link = Some(args.next().ok_or("--link needs a value")?),
            "--path" => {
                let value = args.next().ok_or("--path needs a value")?;
                path = Some(match value.as_str() {
                    "terminal" => scenario::PathKind::Terminal,
                    "projection" => scenario::PathKind::Projection,
                    other => return Err(format!("--path {other}: terminal or projection")),
                });
            }
            "--cols" => {
                let value = args.next().ok_or("--cols needs a value")?;
                cols = Some(value.parse::<u16>().map_err(|_| format!("--cols {value}"))?);
            }
            "--coalesce-ms" => {
                let value = args.next().ok_or("--coalesce-ms needs a value")?;
                coalesce_ms =
                    Some(value.parse::<u64>().map_err(|_| format!("--coalesce-ms {value}"))?);
            }
            "--phone-event-ms" => {
                let value = args.next().ok_or("--phone-event-ms needs a value")?;
                phone_event_ms =
                    Some(value.parse::<f64>().map_err(|_| format!("--phone-event-ms {value}"))?);
            }
            "--merge-ready" => merge_ready = true,
            "--dir" => dir = Some(args.next().ok_or("--dir needs a value")?),
            "--repo" => repo = Some(args.next().ok_or("--repo needs a value")?),
            flag if flag.starts_with('-') => return Err(format!("unknown flag {flag}\n{USAGE}")),
            _ if name.is_none() => name = Some(arg),
            _ => return Err(format!("one scenario name, got {arg:?} too\n{USAGE}")),
        }
    }
    let repo = repo_root(repo).ok();
    let dir = dir.map_or_else(|| scenario::default_dir(repo.as_deref()), PathBuf::from);
    match verb.as_str() {
        "list" => {
            print!("{}", scenario::list_table(&scenario::load_dir(&dir)?));
            Ok(true)
        }
        "run" => {
            let name = name.ok_or_else(|| format!("scenario run needs a NAME or all\n{USAGE}"))?;
            let mut scenarios = if name == "all" {
                scenario::load_dir(&dir)?
            } else {
                vec![scenario::find(&dir, &name)?]
            };
            for scenario in &mut scenarios {
                if let Some(spec) = &spec {
                    scenario.spec.clone_from(spec);
                }
                if let Some(link) = &link {
                    scenario.link = scenario::Scenario::named_link(link)?;
                    if scenario.link.is_none() {
                        scenario.spec = format!("{},link={link}", scenario.spec);
                    }
                }
                if let Some(path) = path {
                    scenario.path = path;
                }
                if let Some(cols) = cols {
                    scenario.cols = cols;
                }
                if coalesce_ms.is_some() {
                    scenario.coalesce_ms = coalesce_ms;
                }
                if phone_event_ms.is_some() {
                    scenario.phone_event_ms = phone_event_ms;
                }
                scenario.merge_ready |= merge_ready;
                scenario.validate()?;
            }
            if sim {
                for scenario in &scenarios {
                    println!("scripts/ci/cmux-next-ios-sim.sh {}", scenario.sim_args());
                }
                return Ok(true);
            }
            run_scenarios(&scenarios, repo.as_deref())
        }
        _ => Err(format!("scenario list or scenario run\n{USAGE}")),
    }
}

#[cfg(feature = "paths")]
fn run_scenarios(
    scenarios: &[scenario::Scenario],
    repo: Option<&std::path::Path>,
) -> Result<bool, String> {
    let repo = repo.ok_or("no checkout for the recordings; pass --repo")?;
    let inputs = Inputs::load_repo(repo)?;
    let commit = scenario::commit(Some(repo));
    let mut all_pass = true;
    for scenario in scenarios {
        if !scenario.headless {
            let json = scenario::report_json(
                scenario,
                scenario.knobs()?.seed,
                commit.as_deref(),
                &Default::default(),
                &[],
                0.0,
            );
            eprint!("{}", scenario::report_text(scenario, &Default::default(), &[]));
            println!("{json}");
            continue;
        }
        let (json, text, pass) =
            cmux_duress::replay::run_and_report(scenario, &inputs, commit.as_deref())?;
        eprint!("{text}");
        eprintln!("  verdict: {}", if pass { "PASS" } else { "FAIL" });
        println!("{json}");
        all_pass &= pass;
    }
    Ok(all_pass)
}

#[cfg(not(feature = "paths"))]
fn run_scenarios(_: &[scenario::Scenario], _: Option<&std::path::Path>) -> Result<bool, String> {
    Err("this cmux-duress was built without the `paths` feature; scenario run needs it (cargo run --release -p cmux-duress -- scenario run NAME)".to_owned())
}

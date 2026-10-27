//! `cmux chief usage [--chief ID] [--since 7d] [--by chief|agent|model] [--json]`:
//! tokens, cost, cache hit and latency of this build's Chiefs over time
//! (plans/cmux-next/chief-usage-analytics-DESIGN.md). The Chief's own
//! `optchat-chief usage` owns the ledger and its fold; this command finds the
//! Chief home as `cmux chief` does, the `optchat-chief` this CLI ships with,
//! and runs it. Read-only, and no daemon or brain needs to run.

use std::path::{Path, PathBuf};

use super::GlobalArgs;
use super::home::ChiefHome;
use crate::cli::OutputMode;

/// The flags passed through to `optchat-chief usage` (each takes a value).
const PASSED: [&str; 5] = ["--since", "--until", "--bucket", "--by", "--top"];

/// The `optchat-chief usage` invocation: the tool and its arguments.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Invocation {
    pub tool: PathBuf,
    pub args: Vec<String>,
}

/// Where `optchat-chief` is: `CMUX_OPTCHAT_CHIEF`, else beside this CLI (the
/// app's Contents/Resources/bin), else on `PATH`.
pub(super) fn find_tool(
    env: &dyn Fn(&str) -> Option<String>,
    exe_dir: Option<&Path>,
) -> Option<PathBuf> {
    let executable = |p: &Path| {
        use std::os::unix::fs::PermissionsExt;
        cmux_blocking::fs::metadata(p)
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if let Some(path) = env("CMUX_OPTCHAT_CHIEF").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(path));
    }
    if let Some(path) = exe_dir.map(|d| d.join("optchat-chief")).filter(|p| executable(p)) {
        return Some(path);
    }
    env("PATH")?.split(':').map(|d| Path::new(d).join("optchat-chief")).find(|p| executable(p))
}

/// The invocation for `args` (after `usage`) on the Chief home `home`: one
/// Chief with `--chief ID` (its directory under the home, as the daemon names
/// it), else the home's Chief and every Chief under it.
pub(super) fn invocation(
    args: &[String],
    home: &Path,
    tool: PathBuf,
    json: bool,
) -> Result<Invocation, String> {
    let mut out = vec!["usage".to_owned()];
    let mut chief = None;
    let mut json = json;
    let mut i = 0;
    while i < args.len() {
        let (flag, inline) = match args[i].split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => {
                (flag.to_owned(), Some(value.to_owned()))
            }
            _ => (args[i].clone(), None),
        };
        let mut value = || -> Result<String, String> {
            if let Some(value) = &inline {
                return Ok(value.clone());
            }
            i += 1;
            args.get(i).cloned().ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag.as_str() {
            "--json" => json = true,
            "--chief-home" => {
                // Resolved by the caller.
                value()?;
            }
            "--chief" => chief = Some(value()?),
            name if PASSED.contains(&name) => {
                let v = value()?;
                out.push(name.to_owned());
                out.push(v);
            }
            other => return Err(format!("unknown argument {other} (cmux chief usage --help)")),
        }
        i += 1;
    }
    match chief.as_deref() {
        Some(id) if id != "default" => {
            let dir = cmux_tui_core::chief_brains::brain_home(home, id);
            out.extend(["--mux-home".to_owned(), dir.display().to_string()]);
        }
        _ => {
            out.extend([
                "--mux-home".to_owned(),
                home.display().to_string(),
                "--chiefs".to_owned(),
            ]);
        }
    }
    if json {
        out.push("--json".to_owned());
    }
    Ok(Invocation { tool, args: out })
}

/// `--chief-home DIR` among `args`, if given.
fn explicit_home(args: &[String]) -> Option<PathBuf> {
    args.iter().enumerate().find_map(|(i, a)| match a.split_once('=') {
        Some(("--chief-home", v)) => Some(PathBuf::from(v)),
        _ if a == "--chief-home" => args.get(i + 1).map(PathBuf::from),
        _ => None,
    })
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let m = super::messages();
    if args.iter().any(|a| matches!(a.as_str(), "-h" | "--help" | "help")) {
        println!("{}", m.usage_help);
        return 0;
    }
    let env = |key: &str| std::env::var(key).ok();
    let user_home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into());
    let cwd = std::env::current_dir().unwrap_or_else(|_| "/".into());
    let home = ChiefHome::resolve(explicit_home(args).as_deref(), env, &user_home, &cwd);
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf));
    let Some(tool) = find_tool(&env, exe_dir.as_deref()) else {
        eprintln!("cmux: {}", m.usage_no_tool);
        return 1;
    };
    let json = matches!(global.output, OutputMode::Json);
    let invocation = match invocation(args, &home.root, tool, json) {
        Ok(invocation) => invocation,
        Err(error) => {
            eprintln!("cmux: {error}\n\n{}", m.usage_help);
            return 2;
        }
    };
    match cmux_process::Command::new(&invocation.tool)
        .args(&invocation.args)
        .inherit_like_std()
        .status()
    {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("cmux: {}: {error}", invocation.tool.display());
            1
        }
    }
}

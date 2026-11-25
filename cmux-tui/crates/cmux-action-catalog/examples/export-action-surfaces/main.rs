//! Writes the action-catalog exports the Mac's Swift tests write, without a Mac:
//!
//! - `plans/cmux-next/action-surfaces.json` (`ActionSurfaceExport.json`)
//! - the generated block of `plans/cmux-next/actions.md` (`ActionSurfaceReport.markdown`)
//! - `plans/cmux-next/action-catalog.json` (`ActionCatalogDumpTests.json`)
//!
//! ```text
//! cargo run -p cmux-action-catalog --example export-action-surfaces -- --repo-root R \
//!     [--check] [--only surfaces|catalog] [--catalog-json FILE]
//! ```
//!
//! The catalog is this crate's (`json::catalog_value`), or `--catalog-json`: a dump of another commit's, which
//! is how `scripts/cmux-next/export-action-surfaces-linux.sh` exports the catalog the app's pinned FFI holds.
//! Titles come from the module's `.xcstrings` files. Exit 0: written, or fresh under `--check`; 1: stale under
//! `--check` (the files on stderr); 2: an error.
//!
//! It lives in `examples/` so the app FFI pin (`scripts/ci/app_ffi_pin.py`) does not count it as an input.

mod apple_json;
mod dump;
mod surfaces;
mod swift_tables;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde_json::Value;

const SURFACES_JSON: &str = "plans/cmux-next/action-surfaces.json";
const ACTIONS_MD: &str = "plans/cmux-next/actions.md";
const CATALOG_JSON: &str = "plans/cmux-next/action-catalog.json";
const STRINGS_DIR: &str = "Packages/macOS/CmuxNext/Sources/CmuxNextActions";

struct Options {
    root: PathBuf,
    check: bool,
    surfaces: bool,
    catalog: bool,
    catalog_json: Option<PathBuf>,
}

fn options() -> Result<Options, String> {
    let mut args = std::env::args().skip(1);
    let mut root = None;
    let mut check = false;
    let mut only = None;
    let mut catalog_json = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--repo-root" => {
                root = Some(PathBuf::from(args.next().ok_or("--repo-root needs a path")?))
            }
            "--check" => check = true,
            "--only" => only = Some(args.next().ok_or("--only needs surfaces or catalog")?),
            "--catalog-json" => {
                catalog_json =
                    Some(PathBuf::from(args.next().ok_or("--catalog-json needs a file")?))
            }
            "-h" | "--help" => {
                return Err("usage: export-action-surfaces --repo-root R [--check] [--only surfaces|catalog] [--catalog-json FILE]".into());
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let (surfaces, catalog) = match only.as_deref() {
        None => (true, true),
        Some("surfaces") => (true, false),
        Some("catalog") => (false, true),
        Some(other) => return Err(format!("--only takes surfaces or catalog, not {other}")),
    };
    Ok(Options {
        root: root.ok_or("--repo-root is required")?,
        check,
        surfaces,
        catalog,
        catalog_json,
    })
}

fn read(path: &Path) -> Result<String, String> {
    std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))
}

fn parse(path: &Path, text: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|error| format!("{}: {error}", path.display()))
}

/// The module's string catalogs, by file name, each with its table name (the file stem).
fn string_catalogs(root: &Path) -> Result<Vec<(String, Value)>, String> {
    let dir = root.join(STRINGS_DIR);
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map_err(|error| format!("{}: {error}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "xcstrings"))
        .collect();
    files.sort();
    files
        .iter()
        .map(|path| {
            let table = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_owned();
            Ok((table, parse(path, &read(path)?)?))
        })
        .collect()
}

fn run(options: &Options) -> Result<Vec<&'static str>, String> {
    let catalog = match &options.catalog_json {
        Some(path) => parse(path, &read(path)?)?,
        None => cmux_action_catalog::json::catalog_value(0),
    };
    let mut outputs: Vec<(&'static str, String)> = Vec::new();
    if options.surfaces {
        let titles = surfaces::Titles::new(&string_catalogs(&options.root)?)?;
        let (json, block) = surfaces::export(&catalog, &titles);
        outputs.push((SURFACES_JSON, json));
        let path = options.root.join(ACTIONS_MD);
        let markdown = surfaces::replace_block(&read(&path)?, &block).ok_or_else(|| {
            format!("{ACTIONS_MD}: no `{}` … `{}` block", surfaces::BEGIN, surfaces::END)
        })?;
        outputs.push((ACTIONS_MD, markdown));
    }
    if options.catalog {
        outputs.push((CATALOG_JSON, dump::export(&catalog)?));
    }
    let mut stale = Vec::new();
    for (file, text) in outputs {
        let path = options.root.join(file);
        if std::fs::read_to_string(&path).ok().as_deref() == Some(text.as_str()) {
            continue;
        }
        stale.push(file);
        if !options.check {
            std::fs::write(&path, text).map_err(|error| format!("{}: {error}", path.display()))?;
        }
    }
    Ok(stale)
}

fn main() -> ExitCode {
    let options = match options() {
        Ok(options) => options,
        Err(message) => {
            eprintln!("export-action-surfaces: {message}");
            return ExitCode::from(2);
        }
    };
    match run(&options) {
        Ok(stale) if options.check && !stale.is_empty() => {
            for file in stale {
                eprintln!("stale: {file}");
            }
            ExitCode::from(1)
        }
        Ok(stale) => {
            for file in stale {
                eprintln!("wrote {file}");
            }
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("export-action-surfaces: {message}");
            ExitCode::from(2)
        }
    }
}

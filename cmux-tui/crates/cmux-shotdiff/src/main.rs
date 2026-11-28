//! The cmux-shotdiff CLI. Exit codes: 0 pass, 1 fail (a verdict or report that does not pass), 2 usage or I/O
//! error.

use cmux_shotdiff::{BatchOptions, Spec, Store, compare, decode_png, encode_png, inputkey, store};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const HELP: &str = "\
cmux-shotdiff: compare screenshots and keep goldens (SSIM + per-pixel tolerance, ignore masks, regions)

USAGE
  cmux-shotdiff compare BASE.png HEAD.png [--spec SPEC.json] [--diff DIFF.png] [--json OUT.json]
  cmux-shotdiff hash PNG...
  cmux-shotdiff bless --store DIR (--name NAME PNG | --dir HEADS) [--spec SPEC.json]
  cmux-shotdiff check --store DIR --name NAME HEAD.png [--spec SPEC.json] [--diff DIFF.png] [--json OUT.json]
  cmux-shotdiff batch --store DIR --heads DIR [--out DIR] [--summary FILE] [--title T]
                      [--allow-new] [--require-all]
  cmux-shotdiff get --store DIR (--name NAME | --hash HASH) OUT.png
  cmux-shotdiff key --inputs FILE --family F [--variant V] [--rev REV] [--repo DIR]

key prints {family, variant, key, files, rev} (schema cmux-shotdiff.key/v1): the SHA-256 of family F's
entry in FILE (.github/golden-inputs.json) and of every file at REV (HEAD) its paths match. Goldens rendered
from those inputs are filed under it, so a Mac renders them once per change of what they depend on.

compare/check print the verdict JSON (schema cmux-shotdiff.verdict/v1) to stdout or --json.
batch checks every HEADS/<name>.png against the golden <name>; writes OUT/report.json
(cmux-shotdiff.report/v1) and OUT/diff/<name>.png, and appends a markdown table to --summary
(pass $GITHUB_STEP_SUMMARY in CI).

SPEC (JSON, every field optional):
  {\"channel_tolerance\": 16, \"max_changed_ratio\": 0.01, \"min_ssim\": 0.98, \"scale\": 1,
   \"ignore\":  [{\"x\":0,\"y\":0,\"w\":80,\"h\":20,\"why\":\"menu bar clock\"}],
   \"regions\": [{\"name\":\"sidebar\",\"x\":0,\"y\":0,\"w\":240,\"h\":800,\"min_ssim\":0.995}]}
A pass needs changed_ratio <= max_changed_ratio and ssim >= min_ssim, globally and per region.

EXIT  0 pass   1 fail   2 error
";

struct Args {
    positional: Vec<String>,
    flags: Vec<(String, Option<String>)>,
}

const BOOL_FLAGS: &[&str] = &["--allow-new", "--require-all", "--help", "-h"];

impl Args {
    fn parse(raw: Vec<String>) -> Result<Self, String> {
        let mut positional = Vec::new();
        let mut flags = Vec::new();
        let mut it = raw.into_iter();
        while let Some(a) = it.next() {
            if a.starts_with('-') && a.len() > 1 {
                if BOOL_FLAGS.contains(&a.as_str()) {
                    flags.push((a, None));
                } else {
                    let v = it.next().ok_or_else(|| format!("{a} needs a value"))?;
                    flags.push((a, Some(v)));
                }
            } else {
                positional.push(a);
            }
        }
        Ok(Args { positional, flags })
    }
    fn get(&self, name: &str) -> Option<&str> {
        self.flags.iter().rev().find(|(k, _)| k == name).and_then(|(_, v)| v.as_deref())
    }
    fn has(&self, name: &str) -> bool {
        self.flags.iter().any(|(k, _)| k == name)
    }
    fn need(&self, name: &str) -> Result<&str, String> {
        self.get(name).ok_or_else(|| format!("{name} is required"))
    }
    fn check_known(&self, known: &[&str]) -> Result<(), String> {
        for (k, _) in &self.flags {
            if !known.contains(&k.as_str()) {
                return Err(format!("unknown option {k}"));
            }
        }
        Ok(())
    }
}

fn read_png(path: &str) -> Result<cmux_shotdiff::Rgba, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    decode_png(&bytes).map_err(|e| format!("{path}: {e}"))
}

fn read_spec(path: Option<&str>) -> Result<Option<Spec>, String> {
    let Some(path) = path else { return Ok(None) };
    let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    let spec: Spec = serde_json::from_slice(&bytes).map_err(|e| format!("{path}: {e}"))?;
    spec.validate().map_err(|e| format!("{path}: {e}"))?;
    Ok(Some(spec))
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

fn emit_verdict(args: &Args, cmp: cmux_shotdiff::Comparison) -> Result<ExitCode, String> {
    if let (Some(path), Some(img)) = (args.get("--diff"), cmp.diff_image.as_ref()) {
        write_file(Path::new(path), &encode_png(img).map_err(|e| e.to_string())?)?;
    }
    let mut text = serde_json::to_string_pretty(&cmp.verdict).map_err(|e| e.to_string())?;
    text.push('\n');
    match args.get("--json") {
        Some(path) => write_file(Path::new(path), text.as_bytes())?,
        None => print!("{text}"),
    }
    Ok(if cmp.verdict.pass { ExitCode::SUCCESS } else { ExitCode::from(1) })
}

fn run(raw: Vec<String>) -> Result<ExitCode, String> {
    let Some((cmd, rest)) = raw.split_first() else {
        print!("{HELP}");
        return Ok(ExitCode::from(2));
    };
    let args = Args::parse(rest.to_vec())?;
    if args.has("--help") || args.has("-h") || cmd == "help" || cmd == "--help" || cmd == "-h" {
        print!("{HELP}");
        return Ok(ExitCode::SUCCESS);
    }
    match cmd.as_str() {
        "compare" => {
            args.check_known(&["--spec", "--diff", "--json"])?;
            let [base, head] = args.positional.as_slice() else {
                return Err("compare takes BASE.png HEAD.png".into());
            };
            let spec = read_spec(args.get("--spec"))?.unwrap_or_default();
            let cmp = compare(&read_png(base)?, &read_png(head)?, &spec);
            emit_verdict(&args, cmp)
        }
        "hash" => {
            args.check_known(&[])?;
            if args.positional.is_empty() {
                return Err("hash takes one or more PNGs".into());
            }
            for p in &args.positional {
                println!("{}  {p}", read_png(p)?.content_hash());
            }
            Ok(ExitCode::SUCCESS)
        }
        "bless" => {
            args.check_known(&["--store", "--name", "--dir", "--spec"])?;
            let st = Store::open(args.need("--store")?);
            let spec = read_spec(args.get("--spec"))?;
            let items: Vec<(String, PathBuf)> = match (args.get("--name"), args.get("--dir")) {
                (Some(name), None) => {
                    let [png] = args.positional.as_slice() else {
                        return Err("bless --name NAME takes one PNG".into());
                    };
                    vec![(name.to_string(), PathBuf::from(png))]
                }
                (None, Some(dir)) => store::collect_pngs(Path::new(dir))?,
                _ => return Err("bless takes --name NAME PNG or --dir HEADS".into()),
            };
            for (name, path) in items {
                let img = read_png(&path.to_string_lossy())?;
                let g = st.bless(&name, &img, spec.clone())?;
                println!("{}  {name}  {}x{}", g.hash, g.width, g.height);
            }
            Ok(ExitCode::SUCCESS)
        }
        "check" => {
            args.check_known(&["--store", "--name", "--spec", "--diff", "--json"])?;
            let st = Store::open(args.need("--store")?);
            let name = args.need("--name")?;
            let [head] = args.positional.as_slice() else {
                return Err("check takes HEAD.png".into());
            };
            let m = st.manifest()?;
            let golden = m
                .goldens
                .get(name)
                .ok_or_else(|| format!("no golden named {name}; bless it first"))?;
            let spec = match read_spec(args.get("--spec"))? {
                Some(s) => s,
                None => st.spec_for(&m, name),
            };
            let cmp = compare(&st.get(&golden.hash)?, &read_png(head)?, &spec);
            emit_verdict(&args, cmp)
        }
        "batch" => {
            args.check_known(&[
                "--store",
                "--heads",
                "--out",
                "--summary",
                "--title",
                "--allow-new",
                "--require-all",
            ])?;
            let st = Store::open(args.need("--store")?);
            let heads = PathBuf::from(args.need("--heads")?);
            let out = args.get("--out").map(PathBuf::from);
            let opts = BatchOptions {
                allow_new: args.has("--allow-new"),
                require_all: args.has("--require-all"),
            };
            let report = cmux_shotdiff::batch(&st, &heads, out.as_deref(), opts)?;
            let md = store::markdown(
                &report,
                args.get("--title").unwrap_or("Screenshots against goldens"),
            );
            if let Some(path) = args.get("--summary") {
                use std::io::Write;
                let mut f = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                    .map_err(|e| format!("{path}: {e}"))?;
                f.write_all(md.as_bytes()).map_err(|e| format!("{path}: {e}"))?;
            }
            eprint!("{md}");
            Ok(if report.pass { ExitCode::SUCCESS } else { ExitCode::from(1) })
        }
        "get" => {
            args.check_known(&["--store", "--name", "--hash"])?;
            let st = Store::open(args.need("--store")?);
            let [out] = args.positional.as_slice() else {
                return Err("get takes OUT.png".into());
            };
            let hash = match (args.get("--name"), args.get("--hash")) {
                (Some(name), None) => st
                    .manifest()?
                    .goldens
                    .get(name)
                    .map(|g| g.hash.clone())
                    .ok_or_else(|| format!("no golden named {name}"))?,
                (None, Some(h)) => h.to_string(),
                _ => return Err("get takes --name NAME or --hash HASH".into()),
            };
            write_file(Path::new(out), &encode_png(&st.get(&hash)?).map_err(|e| e.to_string())?)?;
            Ok(ExitCode::SUCCESS)
        }
        "key" => {
            args.check_known(&["--inputs", "--family", "--variant", "--rev", "--repo"])?;
            if !args.positional.is_empty() {
                return Err("key takes no positional arguments".into());
            }
            let family =
                inputkey::load_family(Path::new(args.need("--inputs")?), args.need("--family")?)?;
            let variant = family.variant(args.get("--variant"))?;
            let rev = args.get("--rev").unwrap_or("HEAD");
            let k = inputkey::input_key(
                &family,
                variant,
                Path::new(args.get("--repo").unwrap_or(".")),
                rev,
            )?;
            let out = serde_json::json!({
                "schema": "cmux-shotdiff.key/v1",
                "version": inputkey::KEY_VERSION,
                "family": k.family,
                "variant": k.variant,
                "key": k.key,
                "files": k.files,
                "rev": rev,
            });
            println!("{out}");
            Ok(ExitCode::SUCCESS)
        }
        other => Err(format!("unknown command {other} (try --help)")),
    }
}

fn main() -> ExitCode {
    match run(std::env::args().skip(1).collect()) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("cmux-shotdiff: {e}");
            ExitCode::from(2)
        }
    }
}

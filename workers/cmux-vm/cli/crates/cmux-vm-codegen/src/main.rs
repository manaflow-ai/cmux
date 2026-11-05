//! Generates `crates/cmux-vm-client/src/generated.rs` from the cmux VM
//! OpenAPI document. Run it through `scripts/regenerate.sh`, never by hand:
//! CI reruns that script and fails when the checked-in file differs.
//!
//!   cmux-vm-codegen --spec <openapi.json> --out <generated.rs> \
//!     [--raw-out <generated_raw.rs>] --label <text> \
//!     [--tags <file> [--selected-out <openapi.json>]] [--script <regenerate script>] \
//!     [--panicking-new omit]
//!
//! `--out` gets the typed client. `--raw-out` gets the same client with every
//! success body returned as raw bytes, for callers (the CLI's `--json`) that
//! must pass the server's response through unchanged, unknown fields included.
//! `--tags` names a file with one OpenAPI tag per line (`#` comments): only
//! operations whose first tag is listed are generated, with the schemas they
//! reach (`cmux-cloud-client` keeps the Cloud groups of cmux-platform's spec).
//! `--selected-out` writes that selection, before normalization, as the
//! document a client vendors. `--script` is the regenerate script the
//! generated header points at. `--panicking-new omit` leaves out progenitor's
//! `Client::new(baseurl)`, which unwraps `reqwest::ClientBuilder::build()`: a
//! client crate whose callers build it with `Client::new_with_client` (as
//! `cmux-cloud-client`'s `client_for` does) then carries no panic path.

mod normalize;
mod select;

use std::path::PathBuf;
use std::process::{Command, ExitCode};

struct Args {
    spec: PathBuf,
    out: PathBuf,
    raw_out: Option<PathBuf>,
    label: String,
    tags: Option<PathBuf>,
    selected_out: Option<PathBuf>,
    script: String,
    omit_panicking_new: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut spec = None;
    let mut out = None;
    let mut raw_out = None;
    let mut label = None;
    let mut tags = None;
    let mut script = None;
    let mut selected_out = None;
    let mut omit_panicking_new = false;
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        let value = args.next().ok_or_else(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--spec" => spec = Some(PathBuf::from(value)),
            "--out" => out = Some(PathBuf::from(value)),
            "--raw-out" => raw_out = Some(value),
            "--label" => label = Some(value),
            "--tags" => tags = Some(PathBuf::from(value)),
            "--script" => script = Some(value),
            "--selected-out" => selected_out = Some(PathBuf::from(value)),
            "--panicking-new" if value == "omit" => omit_panicking_new = true,
            "--panicking-new" => return Err(format!("--panicking-new {value}: only `omit`")),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(Args {
        spec: spec.ok_or("--spec is required")?,
        out: out.ok_or("--out is required")?,
        raw_out: raw_out.map(PathBuf::from),
        label: label.ok_or("--label is required")?,
        tags,
        selected_out,
        script: script.unwrap_or_else(|| "workers/cmux-vm/cli/scripts/regenerate.sh".to_owned()),
        omit_panicking_new,
    })
}

fn generate(args: &Args) -> Result<(), String> {
    let text = std::fs::read_to_string(&args.spec)
        .map_err(|e| format!("read {}: {e}", args.spec.display()))?;
    let mut doc: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("parse {}: {e}", args.spec.display()))?;
    if let Some(path) = &args.tags {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("read {}: {e}", path.display()))?;
        let tags = text
            .lines()
            .map(|line| line.split('#').next().unwrap_or_default().trim())
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect();
        let missing = select::keep_tags(&mut doc, &tags);
        if !missing.is_empty() {
            return Err(format!(
                "{} names tags no operation carries: {}",
                path.display(),
                missing.join(", ")
            ));
        }
        if let Some(out) = &args.selected_out {
            let text = serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())?;
            std::fs::write(out, format!("{text}\n"))
                .map_err(|e| format!("write {}: {e}", out.display()))?;
        }
    }
    normalize::normalize(&mut doc);
    emit(doc.clone(), &args.out, args)?;
    let Some(raw_out) = &args.raw_out else {
        return Ok(());
    };
    normalize::raw_success_bodies(&mut doc);
    emit(doc, raw_out, args)
}

fn emit(doc: serde_json::Value, out: &std::path::Path, args: &Args) -> Result<(), String> {
    let (label, spec_path) = (&args.label, &args.spec);
    let spec: openapiv3::OpenAPI = serde_json::from_value(doc).map_err(|e| {
        format!(
            "{} is not an OpenAPI 3.0 document after normalization: {e}",
            spec_path.display()
        )
    })?;

    let settings = progenitor::GenerationSettings::default();
    let mut generator = progenitor::Generator::new(&settings);
    let tokens = generator
        .generate_tokens(&spec)
        .map_err(|e| format!("progenitor: {e}"))?;
    let mut file: syn::File =
        syn::parse2(tokens).map_err(|e| format!("generated code does not parse: {e}"))?;
    if args.omit_panicking_new && !omit_client_new(&mut file) {
        return Err(
            "--panicking-new omit: the generated code has no `impl Client { fn new }`".into(),
        );
    }
    let body = prettyplease::unparse(&file);

    let header = format!(
        "// @generated by cmux-vm-codegen from {label}. Do not edit; run\n\
         // {} instead.\n\n",
        args.script
    );
    std::fs::write(out, format!("{header}{body}"))
        .map_err(|e| format!("write {}: {e}", out.display()))?;

    // rustfmt after prettyplease, so `cargo fmt --check` accepts the file.
    let status = Command::new("rustfmt")
        .args(["--edition", "2024"])
        .arg(out)
        .status()
        .map_err(|e| format!("run rustfmt: {e}"))?;
    if !status.success() {
        return Err(format!("rustfmt failed on {}", out.display()));
    }
    Ok(())
}

/// Removes `fn new` from the generated `impl Client` (not a trait impl); false when there is none.
fn omit_client_new(file: &mut syn::File) -> bool {
    let mut removed = false;
    for item in &mut file.items {
        let syn::Item::Impl(block) = item else {
            continue;
        };
        let is_client = block.trait_.is_none()
            && matches!(&*block.self_ty, syn::Type::Path(p) if p.qself.is_none() && p.path.is_ident("Client"));
        if !is_client {
            continue;
        }
        block.items.retain(|member| {
            let is_new = matches!(member, syn::ImplItem::Fn(f) if f.sig.ident == "new");
            removed |= is_new;
            !is_new
        });
    }
    removed
}

fn main() -> ExitCode {
    match parse_args().and_then(|args| generate(&args)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("cmux-vm-codegen: {message}");
            ExitCode::FAILURE
        }
    }
}

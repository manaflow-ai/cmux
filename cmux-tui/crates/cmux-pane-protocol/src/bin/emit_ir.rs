//! Writes the committed IR and conformance vectors, or checks them.
//!
//! ```text
//! emit-ir            write spec/pane-protocol.json and spec/pane-protocol-vectors.json
//! emit-ir --check    exit 1 if either committed file differs from the generated one
//! ```

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cmux_pane_protocol::catalog::{IR_PATH, VECTORS_PATH, catalog};
use cmux_pane_protocol::ir::ShapeValidator;
use cmux_pane_protocol::vectors::vectors_text;

fn main() -> ExitCode {
    let mut check = false;
    let mut root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--check" => check = true,
            "--root" => match arguments.next() {
                Some(path) => root = PathBuf::from(path),
                None => return usage(),
            },
            _ => return usage(),
        }
    }
    // The emitted IR must pass the same rules as any fragment (names,
    // keywords, paths, tool names).
    let ir = catalog().ir();
    let fragment = cmux_pane_protocol::ir::strip_derived(&ir);
    if let Err(error) =
        cmux_pane_protocol::ir::merge(&serde_json::json!({}), &fragment, &ShapeValidator)
    {
        eprintln!("error: the catalog breaks the IR rules: {error}");
        return ExitCode::FAILURE;
    }
    let files = [(IR_PATH, catalog().ir_text()), (VECTORS_PATH, vectors_text())];
    let mut drift = false;
    for (relative, text) in files {
        let path = root.join(relative);
        if check {
            if std::fs::read_to_string(&path).ok().as_deref() != Some(text.as_str()) {
                eprintln!("drift: {} differs from the generated file", path.display());
                drift = true;
            }
        } else if let Err(error) = write(&path, &text) {
            eprintln!("error: {}: {error}", path.display());
            return ExitCode::FAILURE;
        }
    }
    if drift {
        eprintln!("run: cargo run -p cmux-pane-protocol --bin emit-ir");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn write(path: &Path, text: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, text)
}

fn usage() -> ExitCode {
    eprintln!("usage: emit-ir [--check] [--root <crate dir>]");
    ExitCode::from(2)
}

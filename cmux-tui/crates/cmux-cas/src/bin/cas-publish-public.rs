//! `cas-publish-public`: opt-in, local, offline. Publishes content that a public source's own
//! checksum proves (hq `docs/design/cold-storage-and-shared-tier.md`, P1) into a public-tier
//! directory (`--dir`): chunks named by plain BLAKE3, one manifest per artifact, an index. It
//! uploads nothing and nothing runs it by default; private data has no route in, because every
//! command checks the bytes against a checksum first and refuses a mismatch.
//!
//! ```text
//! cas-publish-public archive --dir D --kind K --name N --version V (--sha256 H | --sha512 H) [--strip N] FILE
//! cas-publish-public cargo-lock --dir D --lock Cargo.lock --crates DIR   # DIR of NAME-VERSION.crate
//! cas-publish-public list --dir D
//! ```

use cmux_cas::public::{Algo, Checksum, Kind, Public, Source, cargo_lock_checksums};
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cas-publish-public: {e}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().ok_or("a command: archive, cargo-lock or list")?;
    let (mut dir, mut kind, mut name, mut version) = (None, None, None, None);
    let (mut sum, mut strip, mut file, mut lock, mut crates) = (None, 0usize, None, None, None);
    while let Some(a) = args.next() {
        let mut val = || args.next().ok_or_else(|| format!("{a} needs a value"));
        match a.as_str() {
            "--dir" => dir = Some(PathBuf::from(val()?)),
            "--kind" => kind = Some(val()?.parse::<Kind>()?),
            "--name" => name = Some(val()?),
            "--version" => version = Some(val()?),
            "--sha256" => {
                sum = Some(Checksum::new(Algo::Sha256, &val()?).map_err(|e| e.to_string())?)
            }
            "--sha512" => {
                sum = Some(Checksum::new(Algo::Sha512, &val()?).map_err(|e| e.to_string())?)
            }
            "--strip" => strip = val()?.parse().map_err(|_| "--strip needs a number")?,
            "--lock" => lock = Some(PathBuf::from(val()?)),
            "--crates" => crates = Some(PathBuf::from(val()?)),
            _ if !a.starts_with("--") => file = Some(PathBuf::from(a)),
            _ => return Err(format!("unknown option {a}")),
        }
    }
    let public = Public::new(dir.ok_or("--dir is required")?);
    match cmd.as_str() {
        "list" => {
            for e in public.entries().map_err(|e| e.to_string())? {
                println!(
                    "{:?}\t{}\t{}\t{}",
                    e.source.kind, e.source.name, e.source.version, e.manifest
                );
            }
        }
        "archive" => {
            let file = file.ok_or("an archive FILE")?;
            let source = Source {
                kind: kind.ok_or("--kind")?,
                name: name.ok_or("--name")?,
                version: version.ok_or("--version")?,
                checksum: sum.ok_or("--sha256 or --sha512: nothing is published unchecked")?,
            };
            let bytes = std::fs::read(&file).map_err(|e| format!("{}: {e}", file.display()))?;
            let p = public.publish_archive(&source, &bytes, strip).map_err(|e| e.to_string())?;
            println!("{}", serde_json::to_string(&p).map_err(|e| e.to_string())?);
        }
        "cargo-lock" => {
            let (lock, crates) = (lock.ok_or("--lock")?, crates.ok_or("--crates")?);
            let text =
                std::fs::read_to_string(&lock).map_err(|e| format!("{}: {e}", lock.display()))?;
            let (mut published, mut missing, mut refused) = (0u64, 0u64, 0u64);
            for (n, v, c) in cargo_lock_checksums(&text) {
                let path = crates.join(format!("{n}-{v}.crate"));
                let Ok(bytes) = std::fs::read(&path) else {
                    missing += 1;
                    continue;
                };
                let source = Source {
                    kind: Kind::Crate,
                    name: n.clone(),
                    version: v,
                    checksum: Checksum::new(Algo::Sha256, &c).map_err(|e| e.to_string())?,
                };
                match public.publish_archive(&source, &bytes, 0) {
                    Ok(_) => published += 1,
                    Err(e) => {
                        refused += 1;
                        eprintln!("refused {n}: {e}");
                    }
                }
            }
            println!("{{\"published\":{published},\"missing\":{missing},\"refused\":{refused}}}");
        }
        other => return Err(format!("unknown command {other}")),
    }
    Ok(())
}

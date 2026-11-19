//! Run on Linux CI, never a developer's active target directory.
//! rustc --edition 2024 scripts/measure/rust-ci-cache.rs -o /tmp/rust-ci-cache
//! /tmp/rust-ci-cache OUTPUT_DIRECTORY
//!
//! Small real-workspace experiment, not a full application build estimate. Each
//! mode gets fresh targets; network priming is separate from offline timings.
use std::env;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn checked(command: &mut Command) -> Result<Output> {
    let output = command.output()?;
    if !output.status.success() {
        return Err(format!(
            "{command:?}: {}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    Ok(output)
}

fn cargo(root: &Path, target: &Path, incremental: &str, debug: &str) -> Command {
    let mut cmd = Command::new("cargo");
    cmd.current_dir(root)
        .env("CARGO_TARGET_DIR", target)
        .env("CARGO_INCREMENTAL", incremental)
        .env("CARGO_PROFILE_DEV_DEBUG", debug)
        .env("CARGO_BUILD_JOBS", "4")
        .env_remove("RUSTC_WRAPPER")
        .env_remove("RUSTC_WORKSPACE_WRAPPER")
        .env_remove("RUSTFLAGS")
        .env_remove("CARGO_ENCODED_RUSTFLAGS")
        .env("CARGO_TERM_COLOR", "never");
    cmd
}

fn refresh_sources(path: &Path) -> io::Result<()> {
    for item in fs::read_dir(path)? {
        let entry = item?;
        if entry.file_type()?.is_dir() {
            refresh_sources(&entry.path())?;
        } else if entry.path().extension().is_some_and(|ext| ext == "rs") {
            let bytes = fs::read(entry.path())?;
            fs::write(entry.path(), bytes)?;
        }
    }
    Ok(())
}

fn measure(
    out: &Path,
    rows: &mut File,
    round: usize,
    mode: &str,
    case: &str,
    cmd: &mut Command,
) -> Result<()> {
    let start = Instant::now();
    let result = cmd.output()?;
    let seconds = start.elapsed().as_secs_f64();
    let stderr = String::from_utf8_lossy(&result.stderr);
    let compiled = stderr
        .lines()
        .filter(|line| line.trim_start().starts_with("Compiling "))
        .count();
    let log = format!("{round}-{mode}-{case}");
    fs::write(out.join(format!("{log}.stderr")), &result.stderr)?;
    fs::write(out.join(format!("{log}.stdout")), &result.stdout)?;
    let row = format!(
        "{round}\t{mode}\t{case}\t{seconds:.6}\t{compiled}\t{}",
        result.status.code().unwrap_or(-1)
    );
    println!("{row}");
    writeln!(rows, "{row}")?;
    rows.flush()?;
    if !result.status.success() {
        return Err(format!("{log}: {}\n{stderr}", result.status).into());
    }
    Ok(())
}

fn main() -> Result<()> {
    let out = PathBuf::from(env::args_os().nth(1).ok_or("expected output directory")?);
    fs::create_dir_all(&out)?;
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let path = env::temp_dir().join(format!("rust-ci-cache-{}-{nonce}", std::process::id()));
    fs::create_dir(&path)?;
    let scratch = Scratch(path);
    let archive = scratch.0.join("source.tar");
    checked(
        Command::new("git")
            .args(["archive", "--format=tar", "HEAD", "cmux-screen"])
            .stdout(Stdio::from(File::create(&archive)?)),
    )?;
    checked(
        Command::new("tar")
            .arg("-xf")
            .arg(&archive)
            .arg("-C")
            .arg(&scratch.0),
    )?;
    let root = scratch.0.join("cmux-screen");
    let source = root.join("crates/cmux-screen-proto/src/lib.rs");
    let original = fs::read_to_string(&source)?;
    let head = checked(Command::new("git").args(["rev-parse", "HEAD"]))?;
    let rustc = checked(Command::new("rustc").arg("-Vv"))?;
    let cargo_version = checked(Command::new("cargo").arg("-V"))?;
    let cpu = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    fs::write(
        out.join("environment.txt"),
        format!(
            "head={}{}{}jobs=4\nrunner={}\ncpu={}\n",
            String::from_utf8_lossy(&head.stdout),
            String::from_utf8_lossy(&rustc.stdout),
            String::from_utf8_lossy(&cargo_version.stdout),
            env::var("RUNNER_NAME").unwrap_or_default(),
            cpu.lines()
                .find(|line| line.starts_with("model name"))
                .unwrap_or("unknown")
        ),
    )?;
    // Prime only selected package dependencies. cargo fetch would also fetch
    // the host workspace member's native WebRTC dependencies, which we don't use.
    let prime = checked(cargo(&root, &scratch.0.join("prime"), "0", "2").args([
        "build",
        "--locked",
        "-p",
        "cmux-screen-proto",
    ]))?;
    fs::write(out.join("prime.stderr"), prime.stderr)?;
    let mut rows = File::create(out.join("results.tsv"))?;
    writeln!(rows, "round\tmode\tcase\tseconds\tcompiled\texit")?;
    let modes = [
        ("no-incremental", "0", "2"),
        ("incremental", "1", "2"),
        ("no-debuginfo", "0", "0"),
    ];
    // Rotate order to reduce systematic first-run bias. Separate targets each
    // round; the registry and OS page cache remain warm for every cold build.
    for round in 0..3 {
        for offset in 0..3 {
            let (mode, incremental, debug) = modes[(round + offset) % modes.len()];
            let target = scratch.0.join(format!("target-{round}-{mode}"));
            fs::write(&source, &original)?;
            let mut run = |case: &str| -> Result<()> {
                measure(
                    &out,
                    &mut rows,
                    round,
                    mode,
                    case,
                    cargo(&root, &target, incremental, debug).args([
                        "build",
                        "--offline",
                        "--locked",
                        "-p",
                        "cmux-screen-proto",
                    ]),
                )
            };
            run("cold-target")?;
            run("warm-unchanged")?;
            refresh_sources(&root.join("crates/cmux-screen-proto/src"))?;
            run("fresh-source-mtimes")?;
            fs::write(
                &source,
                format!("{original}\n#[doc(hidden)] pub fn ci_cache_probe() -> u64 {{ 41 }}\n"),
            )?;
            run("add-function")?;
            fs::write(
                &source,
                format!("{original}\n#[doc(hidden)] pub fn ci_cache_probe() -> u64 {{ 42 }}\n"),
            )?;
            run("edit-function")?;
            // Exact workspace-package eviction; dependencies stay. This models
            // dependency-only retention, not the entire cache action lifecycle.
            checked(cargo(&root, &target, incremental, debug).args([
                "clean",
                "--offline",
                "-p",
                "cmux-screen-proto",
            ]))?;
            run("workspace-evicted")?;
            let test_source = format!(
                "{}\n#[test] fn ci_cache_probe_reads_new_value() {{ assert_eq!(ci_cache_probe(), 42); }}\n",
                fs::read_to_string(&source)?
            );
            fs::write(&source, test_source)?;
            measure(
                &out,
                &mut rows,
                round,
                mode,
                "test-after-edit",
                cargo(&root, &target, incremental, debug).args([
                    "test",
                    "--offline",
                    "--locked",
                    "-p",
                    "cmux-screen-proto",
                    "--lib",
                ]),
            )?;
            fs::remove_dir_all(&target)?;
        }
    }
    Ok(())
}

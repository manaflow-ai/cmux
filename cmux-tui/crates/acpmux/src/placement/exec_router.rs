//! The exec router: every heavy command an agent, its helpers or their subprocesses start goes
//! where `run_vm.rs` places it, whoever started it. Leo, 2026-11-25: "how can everybody know to do
//! that and the data gets read properly and the work gets routed properly and the work itself
//! reads and writes and works as expected?" Nobody has to know: routing lives in the execution
//! layer, not in agents' heads.
//!
//! Until this, the run VM placer (RFD 0144 piece 3) saw only Claude Code's own `Bash` calls (the
//! PreToolUse rewrite in `bg_hook.rs`). A `cargo build` started by a script, by `make`, by a
//! Codex or OpenCode shell, or by a helper's tool ran here. Now:
//!
//! 1. **PATH shims.** A session acpmux starts on a Cloud machine with run VMs on gets
//!    `$ACPMUX_HOME/exec-shims` first on its `PATH` ([`session_path`]). Each shim ([`SHIMMED`])
//!    is a few lines of `sh` this file writes ([`shim_script`]): already decided (`CMUX_EXEC_ROUTED`
//!    set), killed (`CMUX_RUN_VMS=0`) or no Cloud machine id, it execs the real program with the
//!    shim folder left off `PATH`; otherwise it execs `acpmux run-vm --shim PROGRAM -- ARGS`
//!    ([`shim_main`]), which runs a heavy class on a fork ([`super::run_vm::fork_or_here`]) and
//!    execs everything else here, stdin, tty and signals untouched.
//! 2. **One decision per command tree.** Whatever ran it sets `CMUX_EXEC_ROUTED` (`fork` on the
//!    run VM's shell, `here` when it runs here), so a `cargo build` under a routed `make` or a
//!    build script's `cc` never routes again.
//! 3. **A hook for the conformance suite.** `CMUX_EXEC_ROUTE=local` keeps a command here,
//!    `CMUX_EXEC_ROUTE=routed` sends it to a run VM whatever its class ([`Force`]); both write a
//!    trace row, so the suite runs one command each way and compares stdout, exit and the tree.
//!    The kill switch still wins over `routed`.
//! 4. **`acpmux exec-router trace`** prints each decision from `run-vm.jsonl`: where it ran, why, what
//!    started it (hook, shim, cli), how long, the bytes that came back ([`trace_main`]).
//!
//! Any failure before the command's first output line runs it here (`run_vm.rs`'s rule).

use std::path::{Path, PathBuf};

/// Set on every command whose placement is decided: `fork` on a run VM's shell, `here` when it
/// runs here. A shim that sees it runs the real program at once.
pub const ROUTED_ENV: &str = "CMUX_EXEC_ROUTED";
/// The conformance suite's switch: `local` or `routed` (unset or `auto`: the placer decides).
pub const FORCE_ENV: &str = "CMUX_EXEC_ROUTE";
/// The shim folder's name under `$ACPMUX_HOME`.
pub const SHIM_DIR: &str = "exec-shims";

/// The programs that get a shim: exactly the programs [`super::run_vm`]'s heavy table names (a
/// test holds the two together). A program here that is not heavy for its words (`cargo
/// --version`, `npm view`) execs straight through. Not `make`, `ninja`, `docker` or package
/// installs yet: their outputs are `.gitignore`d (`target/`, `node_modules`, an image) and a run
/// VM sends back only tracked changes, so they wait for the shared chat namespace (step 2 of the
/// decision, cloud-projection-finish) before they route.
pub const SHIMMED: &[&str] = &[
    "cargo",
    "swift",
    "xcodebuild",
    "go",
    "pnpm",
    "npm",
    "bun",
    "yarn",
    "pytest",
    "gradle",
    "gradlew",
    "mvn",
    "bazel",
];

/// What the conformance switch asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Force {
    /// The placer decides (unset, empty, `auto`, or anything it does not know).
    Auto,
    /// Always here.
    Local,
    /// Always a run VM when there is one, whatever the class.
    Routed,
}

impl Force {
    /// The switch from its environment value.
    pub fn parse(value: Option<&str>) -> Self {
        match value.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
            Some("local" | "here") => Force::Local,
            Some("routed" | "fork" | "remote") => Force::Routed,
            _ => Force::Auto,
        }
    }

    /// The switch from this process's environment.
    pub fn from_env() -> Self {
        Self::parse(std::env::var(FORCE_ENV).ok().as_deref())
    }
}

/// The class a command goes to a run VM as, or None to run it here: run VMs `on`, a Cloud
/// `machine`, then the switch, then the heavy table. Run VMs off or no machine is here even when
/// forced `routed`: the kill switch wins.
pub fn route(on: bool, machine: Option<&str>, command: &str, force: Force) -> Option<&'static str> {
    machine.map(str::trim).filter(|m| !m.is_empty())?;
    if !on {
        return None;
    }
    match force {
        Force::Local => None,
        Force::Routed => Some(
            super::run_vm::heavy_class(command).unwrap_or("a command CMUX_EXEC_ROUTE=routed sent"),
        ),
        Force::Auto => super::run_vm::heavy_class(command),
    }
}

/// The shim folder: `$ACPMUX_HOME/exec-shims`.
pub fn shim_dir() -> PathBuf {
    crate::config::home().join(SHIM_DIR)
}

/// One `sh` word for `s`, single-quoted.
fn sh_word(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The shim for `program`: it runs `acpmux` (`bin`, absolute) only when the command can route,
/// and the real program otherwise, with `dir` left off `PATH` so nothing under it sees a shim.
pub fn shim_script(bin: &Path, dir: &Path, program: &str) -> String {
    let bin = sh_word(&bin.to_string_lossy());
    let dir = sh_word(&dir.to_string_lossy());
    let prog = sh_word(program);
    format!(
        "#!/bin/sh\n\
         # acpmux exec router shim for {program} (written by acpmux; `acpmux exec-router trace` shows\n\
         # where each routed command ran). CMUX_RUN_VMS=0 turns it into a plain pass-through.\n\
         if [ -z \"${{{ROUTED_ENV}:-}}\" ] && [ -n \"${{CMUX_VM_ID:-}}\" ] && [ \"${{CMUX_RUN_VMS:-1}}\" != 0 ]; then\n\
         \x20 exec {bin} run-vm --shim {prog} -- \"$@\"\n\
         fi\n\
         _d={dir}\n\
         _p=\n\
         _ifs=$IFS\n\
         set -f\n\
         IFS=:\n\
         for _e in $PATH; do\n\
         \x20 [ \"$_e\" = \"$_d\" ] || _p=\"${{_p:+$_p:}}$_e\"\n\
         done\n\
         IFS=$_ifs\n\
         set +f\n\
         PATH=$_p\n\
         export PATH\n\
         exec {prog} \"$@\"\n"
    )
}

/// Write every shim into `dir` for `bin`, leaving one that already reads the same alone.
pub fn install(dir: &Path, bin: &Path) -> std::io::Result<()> {
    crate::home_fs::create_dirs(dir)?;
    for program in SHIMMED {
        let path = dir.join(program);
        let want = shim_script(bin, dir, program);
        if std::fs::read_to_string(&path).is_ok_and(|have| have == want) {
            continue;
        }
        let tmp = dir.join(format!(".{program}.{}", std::process::id()));
        crate::home_fs::write(&tmp, &want)?;
        #[cfg(unix)]
        crate::home_fs::set_mode(&tmp, 0o755)?;
        crate::home_fs::rename(&tmp, &path)?;
    }
    Ok(())
}

/// `path` with `dir` first (and nowhere else).
pub fn prepend(path: &str, dir: &Path) -> String {
    let dir = dir.to_string_lossy();
    let rest = strip(path, &dir);
    if rest.is_empty() { dir.into_owned() } else { format!("{dir}:{rest}") }
}

/// `path` without `dir`.
pub fn strip(path: &str, dir: &str) -> String {
    path.split(':').filter(|e| !e.is_empty() && *e != dir).collect::<Vec<_>>().join(":")
}

/// The `PATH` a session acpmux starts gets: the shim folder first, when this is a Cloud machine
/// with run VMs on and the shims are written. Anything else (no machine, killed, a write that
/// failed) is None: the session keeps the `PATH` it had.
pub fn session_path(current: &str) -> Option<String> {
    super::sub_fork::this_machine()?;
    if !super::run_vm::run_vms_on() {
        return None;
    }
    let dir = shim_dir();
    let bin = crate::cli_caller::own_bin().or_else(|| std::env::current_exe().ok())?;
    if let Err(e) = install(&dir, &bin) {
        tracing::warn!(error = %e, dir = %dir.display(), "exec router: shims not written");
        return None;
    }
    Some(prepend(current, &dir))
}

/// Replace this process with `program args` here: the shim folder left off `PATH`, the command
/// tree marked decided. Returns only when the exec failed.
#[cfg(unix)]
fn exec_here(program: &str, args: &[String]) -> std::io::Error {
    use std::os::unix::process::CommandExt as _;
    let path = std::env::var("PATH").unwrap_or_default();
    let path = strip(&path, &shim_dir().to_string_lossy());
    // The program is looked up in the stripped PATH, never the shim again.
    std::process::Command::new(program).args(args).env("PATH", path).env(ROUTED_ENV, "here").exec()
}

/// `acpmux run-vm --shim PROGRAM -- ARGS`: what a shim runs when the command can route.
pub async fn shim_main(program: &str, args: &[String]) -> anyhow::Result<i32> {
    let mut words = vec![program.to_owned()];
    words.extend(args.iter().cloned());
    let command = crate::agent_tools::quoted(&words);
    let machine = super::sub_fork::this_machine();
    let force = Force::from_env();
    let class = route(super::run_vm::run_vms_on(), machine.as_deref(), &command, force);
    if let (Some(machine), Some(class)) = (machine, class)
        && let Some(exit) = super::run_vm::fork_or_here(&machine, class, &command, "shim").await?
    {
        return Ok(exit);
    }
    if force == Force::Local {
        super::run_vm::write_forced_here(&command, "shim");
    }
    #[cfg(unix)]
    {
        let e = exec_here(program, args);
        anyhow::bail!("{program}: {e}");
    }
    #[cfg(not(unix))]
    {
        let status =
            std::process::Command::new(program).args(args).env(ROUTED_ENV, "here").status()?;
        Ok(status.code().unwrap_or(1))
    }
}

/// One line of `acpmux exec-router trace` for a row of `run-vm.jsonl`.
pub fn trace_line(row: &serde_json::Value) -> String {
    let s = |k: &str| row.get(k).and_then(serde_json::Value::as_str).unwrap_or("");
    let n = |k: &str| row.get(k).and_then(serde_json::Value::as_u64);
    let mut line = format!(
        "{at}  {ran:<4}  via {via:<5}  {class}",
        at = s("at").get(..19).unwrap_or(s("at")),
        ran = s("ran"),
        via = if s("via").is_empty() { "hook" } else { s("via") },
        class = s("class"),
    );
    if !s("program").is_empty() {
        line.push_str(&format!(" ({})", s("program")));
    }
    if let Some(ms) = n("wallMs") {
        line.push_str(&format!(", {:.1} s", ms as f64 / 1000.0));
    }
    if let Some(x) = row.get("exit").and_then(serde_json::Value::as_i64) {
        line.push_str(&format!(", exit {x}"));
    }
    let bytes = n("patchBytes").unwrap_or(0) + n("outBytes").unwrap_or(0);
    if row.get("patchBytes").is_some() || row.get("outBytes").is_some() {
        line.push_str(&format!(", {bytes} B back"));
    }
    if let Some(f) = n("files") {
        line.push_str(&format!(", {f} file(s)"));
    }
    if !s("fork").is_empty() {
        line.push_str(&format!(", fork {}", s("fork")));
    }
    if !s("cause").is_empty() {
        line.push_str(&format!(" — {}", s("cause")));
    }
    line
}

/// `acpmux exec-router trace`: the last `last` decisions, newest last, as lines or JSON rows.
pub fn trace_main(last: usize, json: bool) -> anyhow::Result<()> {
    let path = super::run_vm::rows_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            println!("no routed commands yet ({} does not exist)", path.display());
            return Ok(());
        }
        Err(e) => return Err(e.into()),
    };
    let rows: Vec<serde_json::Value> =
        text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    let skip = rows.len().saturating_sub(last);
    for row in rows.iter().skip(skip) {
        if json { println!("{row}") } else { println!("{}", trace_line(row)) }
    }
    Ok(())
}

#[cfg(test)]
#[path = "exec_router_tests.rs"]
mod tests;

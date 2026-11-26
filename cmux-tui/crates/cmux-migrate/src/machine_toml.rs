//! A project's `.cmux/machine.toml` (cmux-cloud-start-core `machine_config`), rendered from a
//! [`MachineConfig`]: `version = 1`, `[env]`, `[secrets] names`, `[setup] run` and `check`.
//!
//! Each `[setup]` line runs in a login shell of its own (`bash -l`), which neither activates mise
//! nor has every toolchain: a reader's `go mod download` failed on a staging machine with no Go
//! (the SSH journey, 2026-11-25). So a line whose first word is a known tool gets mise's shims on
//! `PATH` and installs that tool through mise when the machine lacks it ([`with_toolchain`]).

use crate::plan::MachineConfig;
use crate::sources::project_files::ENSURE_MISE;

/// The file's text. Always `version = 1`; an empty table is left out.
pub fn render(config: &MachineConfig) -> String {
    let mut root = toml::Table::new();
    root.insert("version".into(), toml::Value::Integer(1));
    if !config.env.is_empty() {
        let env: toml::Table =
            config.env.iter().map(|(k, v)| (k.clone(), toml::Value::String(v.clone()))).collect();
        root.insert("env".into(), toml::Value::Table(env));
    }
    if !config.secret_names.is_empty() {
        let mut secrets = toml::Table::new();
        secrets.insert("names".into(), strings(config.secret_names.iter()));
        root.insert("secrets".into(), toml::Value::Table(secrets));
    }
    if !config.setup.is_empty() || !config.check.is_empty() {
        let mut setup = toml::Table::new();
        if !config.setup.is_empty() {
            let run: Vec<String> = config.setup.iter().map(|line| with_toolchain(line)).collect();
            setup.insert("run".into(), strings(run.iter()));
        }
        if !config.check.is_empty() {
            let check: Vec<String> = config.check.iter().map(|line| with_toolchain(line)).collect();
            setup.insert("check".into(), strings(check.iter()));
        }
        root.insert("setup".into(), toml::Value::Table(setup));
    }
    toml::to_string(&root).unwrap_or_else(|_| "version = 1\n".to_owned())
}

fn strings<'a>(items: impl Iterator<Item = &'a String>) -> toml::Value {
    toml::Value::Array(items.map(|s| toml::Value::String(s.clone())).collect())
}

/// Puts mise's shims and `~/.local/bin` on `PATH` for this line.
const MISE_PATH: &str = "export PATH=\"$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH\"";

/// The mise tool a setup command's first word needs, for the package managers the readers write.
fn mise_tool(command: &str) -> Option<&'static str> {
    Some(match command {
        "go" => "go",
        "cargo" => "rust",
        "bundle" => "ruby",
        "npm" | "npx" => "node",
        "pnpm" => "pnpm",
        "yarn" => "yarn",
        "bun" => "bun",
        "uv" => "uv",
        "pip" => "python",
        "poetry" => "poetry",
        "deno" => "deno",
        _ => return None,
    })
}

/// A setup line that also works on a machine without its tool: mise's shims on `PATH`, then the
/// tool installed through mise when it is missing, then the line. A line whose first word is not a
/// known tool (`mise ...`, `docker compose ...`, a script) is only given the `PATH`, so a tool an
/// earlier `mise use -g` line installed is found.
pub fn with_toolchain(line: &str) -> String {
    let first = line.split_whitespace().next().unwrap_or("");
    let Some(tool) = mise_tool(first) else {
        return format!("{MISE_PATH}; {line}");
    };
    format!(
        "{MISE_PATH}; command -v {first} >/dev/null 2>&1 || {{ {{ {ENSURE_MISE}; }} && mise use -g {tool}@latest; }}; {line}"
    )
}

#[cfg(test)]
#[path = "machine_toml_tests.rs"]
mod tests;

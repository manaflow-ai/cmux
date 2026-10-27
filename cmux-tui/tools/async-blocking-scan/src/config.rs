//! The rules file (`blocking-paths.toml`): which calls block, spawn, run
//! between fork and exec, start a process or make an unbounded queue.

use std::collections::BTreeMap;

use serde::Deserialize;

/// The rules file shipped next to the tool; `--paths FILE` replaces it.
pub const DEFAULT_RULES: &str = include_str!("../blocking-paths.toml");

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub scan: ScanConfig,
    pub blocking: BlockingConfig,
    pub spawn: SpawnConfig,
    pub pre_exec: PreExecConfig,
    pub child: ChildConfig,
    pub unbounded: UnboundedConfig,
    #[serde(default)]
    pub types: Vec<TypeRule>,
    #[serde(default)]
    pub pairs: Vec<PairRule>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScanConfig {
    pub skip_dirs: Vec<String>,
    pub skip_file_names: Vec<String>,
    pub skip_file_suffixes: Vec<String>,
    pub exempt_files: Vec<String>,
    pub passthrough: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BlockingConfig {
    pub modules: Vec<String>,
    pub not_blocking: Vec<String>,
    pub functions: Vec<String>,
    pub methods: Vec<MethodRule>,
    pub offload_functions: Vec<String>,
    pub offload_methods: Vec<String>,
    pub guard_methods: Vec<MethodRule>,
    pub future_macros: Vec<String>,
}

/// A method by name and argument count.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MethodRule {
    pub name: String,
    pub args: usize,
    /// Blocks even when awaited (tokio's `blocking_*` panic on a runtime thread).
    #[serde(default)]
    pub always: bool,
    /// tokio has a method of this name that returns a future, so an unawaited
    /// call handed to another call as an argument is that future, not a wait.
    #[serde(default)]
    pub async_twin: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SpawnConfig {
    pub task_functions: Vec<String>,
    pub thread_functions: Vec<String>,
    pub supervisor_prefixes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreExecConfig {
    pub signal_safe: Vec<String>,
    pub safe_methods: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChildConfig {
    pub spawn_methods: Vec<MethodRule>,
    pub spawn_functions: Vec<String>,
    pub reap_methods: Vec<String>,
    /// Builder methods that make the Child killed and reaped on drop.
    pub drop_kills: Vec<String>,
    /// Methods that reap when awaited (tokio's `kill().await` waits).
    pub awaited_reap_methods: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UnboundedConfig {
    pub functions: Vec<String>,
}

/// A receiver type the scan follows inside one function.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TypeRule {
    pub path: String,
    #[serde(default)]
    pub constructors: Vec<String>,
    /// Methods that return the same value (`&mut Self` builders).
    #[serde(default)]
    pub chain: Vec<String>,
    #[serde(default)]
    pub blocking: Vec<String>,
    /// Methods that return a value of another followed type.
    #[serde(default)]
    pub returns: BTreeMap<String, String>,
    #[serde(default)]
    pub spawns_tasks: Vec<String>,
    #[serde(default)]
    pub spawns_threads: Vec<String>,
}

/// A constructor that returns a tuple of followed types.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairRule {
    pub function: String,
    pub types: Vec<String>,
}

/// A rules file that could not be read.
#[derive(Debug)]
pub struct ConfigError(pub String);

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "rules file: {}", self.0)
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    pub fn parse(text: &str) -> Result<Config, ConfigError> {
        toml::from_str(text).map_err(|e| ConfigError(e.to_string()))
    }

    pub fn default_rules() -> Result<Config, ConfigError> {
        Config::parse(DEFAULT_RULES)
    }

    pub fn type_rule(&self, path: &str) -> Option<&TypeRule> {
        self.types.iter().find(|t| t.path == path)
    }

    /// The followed type a call to `function` returns.
    pub fn constructed_type(&self, function: &str) -> Option<&str> {
        self.types
            .iter()
            .find(|t| t.constructors.iter().any(|c| c == function))
            .map(|t| t.path.as_str())
    }

    pub fn pair_types(&self, function: &str) -> Option<&[String]> {
        self.pairs.iter().find(|p| p.function == function).map(|p| p.types.as_slice())
    }

    /// Whether a call to `path` blocks.
    pub fn is_blocking_function(&self, path: &str) -> bool {
        let b = &self.blocking;
        if b.not_blocking.iter().any(|n| path_is_or_under(path, n)) {
            return false;
        }
        b.functions.iter().any(|f| f == path) || b.modules.iter().any(|m| path_is_or_under(path, m))
    }

    pub fn blocking_method(&self, name: &str, args: usize) -> Option<&MethodRule> {
        self.blocking.methods.iter().find(|m| m.name == name && m.args == args)
    }

    pub fn is_guard_method(&self, name: &str, args: usize) -> bool {
        self.blocking.guard_methods.iter().any(|m| m.name == name && m.args == args)
    }

    pub fn is_offload_function(&self, path: &str) -> bool {
        self.blocking.offload_functions.iter().any(|f| f == path)
    }

    pub fn is_offload_method(&self, name: &str) -> bool {
        self.blocking.offload_methods.iter().any(|f| f == name)
    }

    pub fn is_future_macro(&self, name: &str) -> bool {
        self.blocking.future_macros.iter().any(|f| f == name)
    }

    pub fn is_supervisor(&self, path: &str) -> bool {
        self.spawn.supervisor_prefixes.iter().any(|p| path.starts_with(p.as_str()))
    }

    pub fn is_passthrough(&self, name: &str) -> bool {
        self.scan.passthrough.iter().any(|p| p == name)
    }

    pub fn is_child_spawn_method(&self, name: &str, args: usize) -> bool {
        self.child.spawn_methods.iter().any(|m| m.name == name && m.args == args)
    }

    pub fn is_reap_method(&self, name: &str) -> bool {
        self.child.reap_methods.iter().any(|m| m == name)
    }

    pub fn is_signal_safe(&self, path: &str) -> bool {
        self.pre_exec.signal_safe.iter().any(|s| s == path)
    }

    pub fn is_unbounded(&self, path: &str) -> bool {
        self.unbounded.functions.iter().any(|f| f == path)
    }
}

/// `std::fs::read` is under `std::fs`; `std::fsx` is not.
fn path_is_or_under(path: &str, prefix: &str) -> bool {
    path == prefix || (path.starts_with(prefix) && path[prefix.len()..].starts_with("::"))
}

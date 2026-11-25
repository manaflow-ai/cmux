//! A project's `.cmux/machine.toml` (cmux-cloud-start-core `machine_config`), rendered from a
//! [`MachineConfig`]: `version = 1`, `[env]`, `[secrets] names`, `[setup] run` and `check`.

use crate::plan::MachineConfig;

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
            setup.insert("run".into(), strings(config.setup.iter()));
        }
        if !config.check.is_empty() {
            setup.insert("check".into(), strings(config.check.iter()));
        }
        root.insert("setup".into(), toml::Value::Table(setup));
    }
    toml::to_string(&root).unwrap_or_else(|_| "version = 1\n".to_owned())
}

fn strings<'a>(items: impl Iterator<Item = &'a String>) -> toml::Value {
    toml::Value::Array(items.map(|s| toml::Value::String(s.clone())).collect())
}

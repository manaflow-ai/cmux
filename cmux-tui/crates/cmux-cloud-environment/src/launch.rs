//! Cache-first app bootstrap, shared with the CLI's launch argument parser.
use crate::{Environment, Resolver, Selection};
use std::collections::BTreeMap;
use std::path::Path;

/// Resolve a launch without starting a child or doing network I/O.
/// None preserves the CLI fetch path for custom backends and unreadable caches.
pub fn local(
    bundle_id: &str,
    home: &Path,
    arguments: &[String],
    environment: &BTreeMap<String, String>,
) -> Result<Option<Selection>, String> {
    let override_backend = backend(arguments)?;
    let seed = override_backend
        .as_deref()
        .or_else(|| environment.get("CMUX_NEXT_CLOUD_BACKEND").map(String::as_str))
        .or_else(|| environment.get("CMUX_NEXT_CLOUD_ENV").map(String::as_str));
    let resolver = Resolver::new(bundle_id, home)?;
    let selection = resolver.resolve(seed)?;
    Ok(resolver.client_config_local(selection))
}

/// The app's explicit --cloud-backend wins over its environment for this launch only.
pub fn backend(args: &[String]) -> Result<Option<String>, String> {
    let mut found = None;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if let Some(value) = arg.strip_prefix("--cloud-backend=") {
            if value.is_empty() || found.is_some() {
                return Err("duplicate or empty --cloud-backend".into());
            }
            found = Some(value.to_owned());
        } else if arg == "--cloud-backend" {
            let value = args.next().ok_or("--cloud-backend requires a value")?;
            if value.is_empty() || value.starts_with('-') || found.is_some() {
                return Err("duplicate or empty --cloud-backend".into());
            }
            found = Some(value.clone());
        }
    }
    if let Some(value) = &found {
        Environment::parse(value)?;
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ClientConfig, ConfigSource, tests::Home};

    const BUNDLE: &str = "com.cmuxterm.app.debug.recovery";

    #[test]
    fn launch_local_cache_keeps_backend_configuration_and_namespace() {
        let home = Home::new();
        let resolver = Resolver::new(BUNDLE, &home.0).unwrap();
        let selected = resolver.resolve(Some("staging")).unwrap();
        let mut config = ClientConfig {
            version: 1,
            configuration: selected.configuration.clone(),
            capabilities: serde_json::json!({"machine_create": {"bootstrap": true}}),
            image_channel: "nightly-next".into(),
        };
        // A backend changes its auth project: the shared cache validator must isolate credentials.
        config.configuration.stack_project_id = "changed-project".into();
        let cache = resolver
            .state_path()
            .parent()
            .unwrap()
            .join("client-config")
            .join(format!("{}.json", crate::namespace(&selected.api_origin)));
        std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
        std::fs::write(&cache, serde_json::to_vec(&config).unwrap()).unwrap();
        let env = BTreeMap::from([("CMUX_NEXT_CLOUD_ENV".into(), "staging".into())]);
        let answer = local(BUNDLE, &home.0, &[], &env).unwrap().unwrap();
        assert_eq!(answer.config_source, ConfigSource::Cache);
        assert_eq!(answer.configuration, config.configuration);
        assert_eq!(answer.capabilities, config.capabilities);
        assert_eq!(answer.auth_namespace, selected.auth_namespace);
        assert!(!answer.legacy_storage);
        assert_eq!(answer.image_channel.as_deref(), Some("nightly-next"));

        // A corrupt cache asks the same existing HTTP path to validate/repair it; no stale success.
        std::fs::write(cache, b"not json").unwrap();
        assert!(local(BUNDLE, &home.0, &[], &env).unwrap().is_none());
    }

    #[test]
    fn launch_local_rejects_invalid_state_and_preserves_empty_override_precedence() {
        let home = Home::new();
        let resolver = Resolver::new(BUNDLE, &home.0).unwrap();
        resolver.set(Environment::Staging).unwrap();
        let env = BTreeMap::from([
            ("CMUX_NEXT_CLOUD_BACKEND".into(), "".into()),
            ("CMUX_NEXT_CLOUD_ENV".into(), "prod".into()),
        ]);
        assert_eq!(local(BUNDLE, &home.0, &[], &env).unwrap().unwrap().name, "staging");
        std::fs::write(resolver.state_path(), b"bad state").unwrap();
        assert!(
            local(BUNDLE, &home.0, &[], &BTreeMap::new())
                .unwrap_err()
                .contains("invalid cloud environment state")
        );
        assert!(local("../escape", &home.0, &[], &env).is_err());
    }
}

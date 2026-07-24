use serde_json::Value;

/// The build identity that must match between a local client and server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReleaseIdentity {
    pub version: String,
    pub build_commit: Option<String>,
    pub ghostty_commit: Option<String>,
    pub protocol: u32,
}

impl ReleaseIdentity {
    pub fn current(protocol: u32) -> Self {
        Self {
            version: distribution_version().to_string(),
            build_commit: stamped_build_commit().map(str::to_string),
            ghostty_commit: stamped_ghostty_commit().map(str::to_string),
            protocol,
        }
    }

    pub fn from_protocol_data(data: &Value) -> Self {
        Self {
            version: data
                .get("version")
                .and_then(Value::as_str)
                .filter(|version| !version.is_empty())
                .unwrap_or("unknown")
                .to_string(),
            build_commit: optional_string(data, "build_commit"),
            ghostty_commit: optional_string(data, "ghostty_commit"),
            protocol: data
                .get("protocol")
                .and_then(Value::as_u64)
                .and_then(|protocol| u32::try_from(protocol).ok())
                .unwrap_or(0),
        }
    }

    pub fn exactly_matches(&self, other: &Self) -> bool {
        self == other
    }

    pub fn version_with_build_metadata(&self) -> String {
        match (&self.build_commit, &self.ghostty_commit) {
            (Some(commit), Some(ghostty)) => {
                format!("{} ({commit}; ghostty {ghostty})", self.version)
            }
            (Some(commit), None) => format!("{} ({commit})", self.version),
            (None, _) => self.version.clone(),
        }
    }
}

pub fn distribution_version() -> &'static str {
    option_env!("CMUX_TUI_DISTRIBUTION_VERSION")
        .filter(|version| !version.is_empty())
        .unwrap_or(env!("CARGO_PKG_VERSION"))
}

pub fn stamped_build_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_BUILD_COMMIT")
        .filter(|commit| !commit.is_empty())
        .or_else(|| option_env!("CMUX_MUX_BUILD_COMMIT").filter(|commit| !commit.is_empty()))
        .or_else(|| option_env!("CMUX_TUI_SOURCE_COMMIT").filter(|commit| !commit.is_empty()))
}

pub fn stamped_ghostty_commit() -> Option<&'static str> {
    option_env!("CMUX_TUI_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty()).or_else(|| {
        option_env!("CMUX_TUI_SOURCE_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty())
    })
}

fn optional_string(data: &Value, key: &str) -> Option<String> {
    data.get(key).and_then(Value::as_str).filter(|value| !value.is_empty()).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn protocol_data_defaults_missing_identity_fields_conservatively() {
        assert_eq!(
            ReleaseIdentity::from_protocol_data(&json!({"protocol": 9})),
            ReleaseIdentity {
                version: "unknown".to_string(),
                build_commit: None,
                ghostty_commit: None,
                protocol: 9,
            }
        );
    }

    #[test]
    fn exact_matching_includes_source_identities() {
        let current = ReleaseIdentity::current(9);
        assert!(current.build_commit.is_some());
        assert!(current.ghostty_commit.is_some());
        let mut other = current.clone();
        assert!(current.exactly_matches(&other));

        other.build_commit = Some("different".to_string());
        assert!(!current.exactly_matches(&other));
    }
}

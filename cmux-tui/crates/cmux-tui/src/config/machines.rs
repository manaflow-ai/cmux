//! Machine and provider config: configured machines, machine providers and the Cloud provider.

use super::*;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineCreationSourceConfig {
    pub id: String,
    pub name: String,
    pub subtitle: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MachineProviderConfig {
    pub cloud: CloudProviderConfig,
    /// Argv of a machine-provider process to spawn, exactly like
    /// `--machine-provider-command program arg -- `. CLI provider modes
    /// override it.
    pub command: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudProviderConfig {
    pub enabled: bool,
    pub host: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<PathBuf>,
}

impl Default for CloudProviderConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            host: "cmux.cloud".to_string(),
            user: None,
            port: None,
            identity_file: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MachineConfig {
    pub id: String,
    pub name: String,
    pub subtitle: String,
    pub target: MachineTargetConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MachineTargetConfig {
    Unix {
        socket: PathBuf,
    },
    Ssh {
        host: String,
        user: Option<String>,
        port: Option<u16>,
        identity_file: Option<PathBuf>,
        session: String,
        binary: String,
    },
}

//! Headless enrollment: exchange a one-use provisioning token for a device
//! credential, mint the device identity, and register the binding slot.

use std::path::PathBuf;

use anyhow::{Context, bail};

use crate::broker::{BrokerClient, BrokerConfig};
use crate::identity::{
    load_credential, load_or_mint_identity, save_credential, save_identity, state_root,
};

pub struct EnrollArgs {
    pub state: Option<PathBuf>,
    pub broker: Option<String>,
    pub tag: Option<String>,
    pub token: Option<String>,
    pub token_file: Option<PathBuf>,
    /// Register with pairing enabled (the listener/server role). The client
    /// role enrolls with pairing disabled.
    pub pairing_enabled: bool,
}

pub async fn run(args: EnrollArgs) -> anyhow::Result<()> {
    let root = state_root(args.state.as_deref())?;
    let config = BrokerConfig::resolve(args.broker.as_deref())?;
    let mut identity = load_or_mint_identity(&root, args.tag.as_deref())?;

    let credential = match load_credential(&root)? {
        Some(existing) => {
            eprintln!("cmux-tui-iroh: device credential already present; re-registering");
            existing
        }
        None => {
            let token = enrollment_token(&args)?;
            let http = crate::broker::credential_http_client()?;
            let credential = BrokerClient::enroll(&http, &config, token.trim()).await?;
            save_credential(&root, &credential)?;
            eprintln!("cmux-tui-iroh: enrolled; device credential stored in the state root");
            credential
        }
    };

    let broker = BrokerClient::new(config, credential, root.clone())?;
    let registration = broker.register(&identity, args.pairing_enabled).await?;
    identity.binding_id = Some(registration.binding_id.clone());
    save_identity(&root, &identity)?;
    println!(
        "enrolled device {} (tag {}, endpoint {}…, binding {})",
        identity.device_id,
        identity.tag,
        crate::endpoint::log_id(&identity.endpoint_id_hex()?),
        registration.binding_id,
    );
    Ok(())
}

fn enrollment_token(args: &EnrollArgs) -> anyhow::Result<String> {
    if let Some(token) = &args.token {
        return Ok(token.clone());
    }
    if let Some(path) = &args.token_file {
        let contents = std::fs::read_to_string(path)
            .with_context(|| format!("reading enrollment token from {}", path.display()))?;
        return Ok(contents);
    }
    if let Ok(token) = std::env::var("CMUX_TUI_IROH_ENROLL_TOKEN")
        && !token.is_empty()
    {
        return Ok(token);
    }
    bail!(
        "no enrollment token: pass --token, --token-file, or set CMUX_TUI_IROH_ENROLL_TOKEN \
         (mint one with POST /api/devices/iroh/enrollment-tokens as a signed-in user)"
    );
}

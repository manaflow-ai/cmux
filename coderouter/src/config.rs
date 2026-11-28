use std::fs;
use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::cli::Error;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub api_url: String,
    pub stack_api_url: String,
    pub stack_project_id: String,
    pub stack_publishable_client_key: String,
    pub stack_access_token: String,
    pub stack_refresh_token: String,
    pub team_id: String,
    pub team_name: String,
    pub route_token: String,
    pub route_token_expires_at: String,
    pub openai_base_url: String,
}

impl Config {
    pub fn logged_in(&self) -> bool {
        !self.stack_refresh_token.is_empty()
            && !self.team_id.is_empty()
            && !self.route_token.is_empty()
    }

    pub fn clear_session(&mut self) {
        self.stack_access_token.clear();
        self.stack_refresh_token.clear();
        self.team_id.clear();
        self.team_name.clear();
        self.route_token.clear();
        self.route_token_expires_at.clear();
        self.openai_base_url.clear();
    }

    pub fn clear_route(&mut self) {
        self.route_token.clear();
        self.route_token_expires_at.clear();
        self.openai_base_url.clear();
    }
}

pub fn load() -> Result<Config, Error> {
    let path = path()?;
    match fs::read(&path) {
        Ok(body) => serde_json::from_slice(&body)
            .map_err(|error| Error::Backend(format!("invalid coderouter config: {error}"))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
        Err(error) => Err(error.into()),
    }
}

pub fn save(config: &Config) -> Result<(), Error> {
    let path = path()?;
    let parent = path
        .parent()
        .ok_or_else(|| Error::Backend("invalid coderouter config path".into()))?;
    fs::create_dir_all(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    let body = serde_json::to_vec_pretty(config)
        .map_err(|error| Error::Backend(format!("encode coderouter config: {error}")))?;
    temporary.write_all(&body)?;
    temporary.write_all(b"\n")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    temporary
        .persist(&path)
        .map_err(|error| Error::Io(error.error))?;
    Ok(())
}

pub fn path() -> Result<PathBuf, Error> {
    Ok(data_directory()?.join("coderouter").join("config.json"))
}

pub fn data_directory() -> Result<PathBuf, Error> {
    if let Some(path) = std::env::var_os("CODEROUTER_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    dirs::data_local_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| Error::Backend("could not determine a user data directory".into()))
}

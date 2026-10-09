//! Config file I/O: locating the config file, bounded reads, and atomic, durably synced writes of plugin entries.

use super::*;

pub fn config_path() -> anyhow::Result<PathBuf> {
    platform::config_path().ok_or_else(|| anyhow::anyhow!("could not resolve mux config path"))
}

/// Read a UTF-8 file with an explicit byte bound. The extra byte distinguishes
/// an exact-size file from one that exceeds the limit without allocating an
/// unbounded buffer.
pub(crate) fn read_bounded_utf8_file(path: &Path, max_bytes: usize) -> io::Result<String> {
    let file = std::fs::File::open(path)?;
    let mut text = String::new();
    file.take(u64::try_from(max_bytes).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_string(&mut text)?;
    if text.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file exceeds {max_bytes}-byte limit"),
        ));
    }
    Ok(text)
}

pub(crate) fn read_config_text(path: &Path) -> io::Result<String> {
    read_bounded_utf8_file(path, CONFIG_FILE_MAX_BYTES)
}

/// The result of replacing the config file. A committed replacement is a
/// successful operation even when the parent directory could not be synced.
#[must_use = "inspect config durability after a committed write"]
#[derive(Debug)]
pub(crate) enum ConfigWriteOutcome {
    /// The replacement and all relevant directory entries were synced.
    Committed,
    /// The replacement committed, but this platform does not support syncing
    /// directory entries. The staged file itself was synced before rename.
    CommittedWithoutDirectorySync,
    /// The replacement committed, but a supported directory sync failed.
    CommittedButUnsynced { error: anyhow::Error },
}

impl ConfigWriteOutcome {
    /// Takes the parent-sync error, if the replacement committed without a
    /// durability confirmation.
    pub(crate) fn into_unsynced_error(self) -> Option<anyhow::Error> {
        match self {
            Self::Committed | Self::CommittedWithoutDirectorySync => None,
            Self::CommittedButUnsynced { error } => Some(error),
        }
    }
}

/// Writes the sidebar plugin selection to the configured path.
pub(crate) fn write_sidebar_plugin(
    plugin: Option<&SidebarPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let path = config_path()?;
    write_sidebar_plugin_at_path(&path, plugin)
}

/// Writes the sidebar plugin selection to an explicit path.
pub(crate) fn write_sidebar_plugin_at_path(
    path: &Path,
    plugin: Option<&SidebarPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let mut root = read_config_value(path)?;
    let Some(root_object) = root.as_object_mut() else {
        anyhow::bail!("{} must contain a JSON object", path.display());
    };
    match plugin {
        Some(plugin) => {
            let sidebar = root_object.entry("sidebar").or_insert_with(|| json!({}));
            if !sidebar.is_object() {
                *sidebar = json!({});
            }
            let sidebar_object = sidebar.as_object_mut().expect("sidebar was just made an object");
            let mut plugin_value = json!({ "command": &plugin.command });
            if let Some(cwd) = &plugin.cwd {
                plugin_value["cwd"] = json!(cwd);
            }
            sidebar_object.insert("plugin".to_string(), plugin_value);
        }
        None => {
            if let Some(sidebar) = root_object.get_mut("sidebar")
                && let Some(sidebar_object) = sidebar.as_object_mut()
            {
                sidebar_object.remove("plugin");
            }
        }
    }
    write_config_value_atomic(path, &root)
}

/// Writes the userland agent plugin selection to the configured path.
pub(crate) fn write_agent_plugin(
    plugin: Option<&AgentPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let path = config_path()?;
    write_agent_plugin_at_path(&path, plugin)
}

pub(crate) fn write_agent_plugin_at_path(
    path: &Path,
    plugin: Option<&AgentPluginConfig>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let mut root = read_config_value(path)?;
    let Some(root_object) = root.as_object_mut() else {
        anyhow::bail!("{} must contain a JSON object", path.display());
    };
    match plugin {
        Some(plugin) => {
            let agents = root_object.entry("agents").or_insert_with(|| json!({}));
            if !agents.is_object() {
                *agents = json!({});
            }
            let agents_object = agents.as_object_mut().expect("agents was just made an object");
            let mut plugin_value = json!({
                "id": &plugin.id,
                "command": &plugin.command,
            });
            if let Some(cwd) = &plugin.cwd {
                plugin_value["cwd"] = json!(cwd);
            }
            if let Some(revision) = &plugin.revision {
                plugin_value["revision"] = json!(revision);
            }
            agents_object.insert("plugin".to_string(), plugin_value);
        }
        None => {
            if let Some(agents) = root_object.get_mut("agents")
                && let Some(agents_object) = agents.as_object_mut()
            {
                agents_object.remove("plugin");
            }
        }
    }
    write_config_value_atomic(path, &root)
}

pub(super) fn read_config_value(path: &Path) -> anyhow::Result<Value> {
    match read_config_text(path) {
        Ok(text) if text.trim().is_empty() => Ok(json!({})),
        Ok(text) => serde_json::from_str(&text)
            .map_err(|err| anyhow::anyhow!("failed to parse {}: {err}", path.display())),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(anyhow::anyhow!("failed to read {}: {err}", path.display())),
    }
}

/// Serializes a config value to a private staging file before atomically
/// replacing the destination and durably syncing its parent directories. An
/// `Err` means that replacement did not commit. A
/// [`ConfigWriteOutcome::CommittedWithoutDirectorySync`] means the rename
/// committed on a platform without directory-sync support. A
/// [`ConfigWriteOutcome::CommittedButUnsynced`] value means a supported
/// directory sync failed.
pub(super) fn write_config_value_atomic(
    path: &Path,
    value: &Value,
) -> anyhow::Result<ConfigWriteOutcome> {
    write_config_value_atomic_with_sync(path, value, &sync_config_parent_directory)
}

pub(super) fn write_config_value_atomic_with_sync(
    path: &Path,
    value: &Value,
    sync_parent: &dyn Fn(&Path) -> anyhow::Result<ConfigParentSyncOutcome>,
) -> anyhow::Result<ConfigWriteOutcome> {
    let file_name = path.file_name().and_then(|name| name.to_str()).unwrap_or("cmux-tui.json");
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    let process_id = std::process::id();
    let staging_path = move |parent: &Path, attempt: usize| {
        let suffix = if attempt == 0 {
            format!(".{file_name}.{process_id}.{stamp}.tmp")
        } else {
            format!(".{file_name}.{process_id}.{stamp}.{attempt}.tmp")
        };
        parent.join(suffix)
    };
    write_config_value_atomic_with_sync_and_staging(path, value, sync_parent, &staging_path)
}

pub(super) const CONFIG_STAGING_ATTEMPTS: usize = 16;

pub(super) fn write_config_value_atomic_with_sync_and_staging(
    path: &Path,
    value: &Value,
    sync_parent: &dyn Fn(&Path) -> anyhow::Result<ConfigParentSyncOutcome>,
    staging_path: &dyn Fn(&Path, usize) -> PathBuf,
) -> anyhow::Result<ConfigWriteOutcome> {
    let parent = config_parent_directory(path);
    let created_directories = ensure_config_parent_directory(parent)?;
    let mut staged = None;
    for attempt in 0..CONFIG_STAGING_ATTEMPTS {
        let tmp_path = staging_path(parent, attempt);
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;

            // The config can contain the server authentication token. Create
            // the staging file private from the start, independent of umask,
            // and reject a pre-existing symlink if a concurrent writer races
            // with this process before open(2).
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        match options.open(&tmp_path) {
            Ok(file) => {
                staged = Some((tmp_path, file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    let Some((tmp_path, mut file)) = staged else {
        anyhow::bail!("could not create a unique config staging file")
    };
    let result = (|| -> anyhow::Result<()> {
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp_path, path)?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(error);
    }

    #[cfg(unix)]
    {
        Ok(match sync_config_parent_directories(parent, &created_directories, sync_parent) {
            Ok(ConfigParentSyncOutcome::Synced) => ConfigWriteOutcome::Committed,
            Ok(ConfigParentSyncOutcome::Unsupported) => {
                ConfigWriteOutcome::CommittedWithoutDirectorySync
            }
            Err(error) => ConfigWriteOutcome::CommittedButUnsynced { error },
        })
    }
    #[cfg(not(unix))]
    {
        let _ = (created_directories, sync_parent);
        Ok(ConfigWriteOutcome::CommittedWithoutDirectorySync)
    }
}

pub(super) fn ensure_config_parent_directory(parent: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut created_directories = Vec::new();
    let mut current = PathBuf::new();
    for component in parent.components() {
        current.push(component.as_os_str());
        // Prefix, root, and navigation components establish path syntax;
        // only normal components identify directory entries to create.
        if !matches!(component, Component::Normal(_)) {
            continue;
        }
        match std::fs::create_dir(&current) {
            Ok(()) => created_directories.push(current.clone()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                if !std::fs::metadata(&current)?.is_dir() {
                    anyhow::bail!(
                        "config parent component {} is not a directory",
                        current.display()
                    );
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(created_directories)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ConfigParentSyncOutcome {
    Synced,
    Unsupported,
}

#[cfg(unix)]
pub(super) fn sync_config_parent_directory(
    parent: &Path,
) -> anyhow::Result<ConfigParentSyncOutcome> {
    let result = std::fs::File::open(parent).and_then(|directory| directory.sync_all());
    #[cfg(target_os = "macos")]
    if let Err(error) = &result
        && matches!(error.raw_os_error(), Some(code) if code == libc::EINVAL || code == libc::ENOTSUP)
    {
        return Ok(ConfigParentSyncOutcome::Unsupported);
    }
    result.map(|()| ConfigParentSyncOutcome::Synced).map_err(Into::into)
}

#[cfg(not(unix))]
pub(super) fn sync_config_parent_directory(
    _parent: &Path,
) -> anyhow::Result<ConfigParentSyncOutcome> {
    Ok(ConfigParentSyncOutcome::Unsupported)
}

#[cfg(unix)]
pub(super) fn sync_config_parent_directories(
    parent: &Path,
    created_directories: &[PathBuf],
    sync_parent: &dyn Fn(&Path) -> anyhow::Result<ConfigParentSyncOutcome>,
) -> anyhow::Result<ConfigParentSyncOutcome> {
    let mut unsupported = false;
    for directory in std::iter::once(parent)
        .chain(created_directories.iter().rev().map(|directory| config_parent_directory(directory)))
    {
        if matches!(sync_parent(directory)?, ConfigParentSyncOutcome::Unsupported) {
            unsupported = true;
        }
    }
    Ok(if unsupported {
        ConfigParentSyncOutcome::Unsupported
    } else {
        ConfigParentSyncOutcome::Synced
    })
}

pub(super) fn config_parent_directory(path: &Path) -> &Path {
    path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."))
}

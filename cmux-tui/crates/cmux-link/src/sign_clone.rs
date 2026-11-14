//! A macOS update clone is an installed app only after its signatures agree.

use std::path::{Component, Path, PathBuf};

/// Facts returned only after the complete static signature validates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Identity {
    pub team: String,
    pub identifier: String,
}

/// Keep the path parser independent of Security.framework for Linux tests.
/// The reader must validate Apple-anchored signatures, not just read metadata.
pub(crate) fn resolve(
    executable: &Path,
    mut signature: impl FnMut(&Path) -> Option<Identity>,
) -> Option<PathBuf> {
    if !executable.is_absolute()
        || executable
            .components()
            .any(|part| matches!(part, Component::ParentDir) || part.as_os_str() == "_work")
    {
        return None;
    }
    let bundle = executable.ancestors().find(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".app.bundle"))
            && executable.starts_with(path.join("Contents"))
    })?;
    let clone_dir = bundle.parent()?;
    let nonce = clone_dir.file_name()?.to_str()?.strip_prefix("code_sign_clone.")?;
    if nonce.is_empty() {
        return None;
    }
    let expected_identifier =
        clone_dir.parent()?.file_name()?.to_str()?.strip_suffix(".code_sign_clone")?;
    if !(expected_identifier == "com.cmuxterm.app"
        || expected_identifier.starts_with("com.cmuxterm.app."))
        || !crate::app_caller::plain_bundle_identifier(expected_identifier)
    {
        return None;
    }
    let installed_name = bundle.file_name()?.to_str()?.strip_suffix(".bundle")?;
    let installed_bundle = Path::new("/Applications").join(installed_name);
    let installed_executable = installed_bundle.join(executable.strip_prefix(bundle).ok()?);
    let installed = signature(&installed_bundle)?;
    if installed.identifier != expected_identifier || signature(bundle)? != installed {
        return None;
    }
    // A nested helper has its own signed identifier. Check both executables,
    // not merely the enclosing bundle's main executable and resource seal.
    let installed_binary = signature(&installed_executable)?;
    if installed_binary.team != installed.team || signature(executable)? != installed_binary {
        return None;
    }
    Some(installed_executable)
}

#[cfg(test)]
mod tests;

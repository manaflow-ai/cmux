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
mod tests {
    use super::*;

    const CLONE: &str = "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux";
    const INSTALLED: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/acpmux";

    fn signed(path: &Path) -> Option<Identity> {
        Some(Identity {
            team: "ABCDEFGHIJ".into(),
            identifier: if path.file_name()? == "acpmux" {
                "acpmux"
            } else {
                "com.cmuxterm.app.nightly"
            }
            .into(),
        })
    }

    #[test]
    fn sign_clone_matching_valid_signatures_resolve_to_installed_executable() {
        assert_eq!(resolve(Path::new(CLONE), signed), Some(PathBuf::from(INSTALLED)));
    }

    #[test]
    fn sign_clone_missing_or_mismatching_signature_at_every_level_is_refused() {
        let paths = [
            "/Applications/cmux NIGHTLY.app",
            "/private/var/folders/a/b/T/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.9gP34C/cmux NIGHTLY.app.bundle",
            INSTALLED,
            CLONE,
        ];
        for target in paths {
            assert_eq!(
                resolve(Path::new(CLONE), |path| if path == Path::new(target) {
                    None
                } else {
                    signed(path)
                }),
                None,
                "missing/invalid signature: {target}"
            );
            for change_team in [false, true] {
                assert_eq!(
                    resolve(Path::new(CLONE), |path| {
                        let mut identity = signed(path)?;
                        if path == Path::new(target) {
                            if change_team {
                                identity.team = "OTHERTEAM1".into();
                            } else {
                                identity.identifier = "other.app".into();
                            }
                        }
                        Some(identity)
                    }),
                    None,
                    "mismatching signature: {target}"
                );
            }
        }
    }

    #[test]
    fn sign_clone_plain_temp_runner_and_unrelated_shapes_never_read_signatures() {
        for path in [
            "/tmp/acpmux",
            "/tmp/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
            "/tmp/code_sign_clone.fake/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
            "/runner/actions-runner-1/_work/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.a/cmux NIGHTLY.app.bundle/Contents/Resources/bin/acpmux",
            "/tmp/com.cmuxterm.app.nightly.code_sign_clone/code_sign_clone.a/cmux NIGHTLY.app.bundle/Contents/../acpmux",
        ] {
            assert_eq!(resolve(Path::new(path), |_| panic!("untrusted shape: {path}")), None);
        }
    }
}

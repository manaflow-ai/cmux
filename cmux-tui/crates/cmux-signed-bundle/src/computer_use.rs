//! The signed bundle that owns Computer Use and Screen Sharing grants on macOS.

use std::path::{Path, PathBuf};

const BUNDLES: [(&str, &str); 2] = [
    ("cmux Computer Use.app", "com.cmuxterm.cua"),
    ("cmux Computer Use (dev).app", "com.cmuxterm.cua.dev"),
];

/// The app's bundled helper carrying the requested executable.
pub fn embedded(contents: &Path, executable: &str) -> Option<PathBuf> {
    BUNDLES
        .iter()
        .map(|(name, _)| contents.join("Library").join(name))
        .find(|bundle| bundle.join("Contents/MacOS").join(executable).is_file())
}

/// Every channel requires the team's signature. Release also requires Developer ID Application.
pub fn requirement(bundle: &Path, id: &str) -> Option<String> {
    // An explicitly supplied helper path may have its own name. A shipped name must carry
    // the identity for that channel, including when an externally supplied path uses it.
    if BUNDLES
        .iter()
        .any(|(name, expected)| bundle.file_name().is_some_and(|n| n == *name) && id != *expected)
    {
        return None;
    }
    let release = id == BUNDLES[0].1;
    if !release && id != BUNDLES[1].1 {
        return None;
    }
    let mut requirement = super::team_requirement(id, "7WLXT3NR37");
    if release {
        requirement.push_str(concat!(
            " and certificate 1[field.1.2.840.113635.100.6.2.6]",
            " and certificate leaf[field.1.2.840.113635.100.6.1.13]",
        ));
    }
    Some(requirement)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_requires_the_executable_inside_the_renamed_bundle() {
        let temp = tempfile::tempdir().unwrap();
        let contents = temp.path();
        let bin = "cmux-remote";
        for name in ["cmux Remote.app", BUNDLES[1].0, BUNDLES[0].0] {
            let macos = contents.join("Library").join(name).join("Contents/MacOS");
            std::fs::create_dir_all(&macos).unwrap();
            std::fs::write(macos.join(bin), "binary").unwrap();
            let expected = (name != "cmux Remote.app").then(|| contents.join("Library").join(name));
            assert_eq!(embedded(contents, bin), expected);
        }
        assert_eq!(embedded(contents, "missing"), None);
    }

    #[test]
    fn the_release_identity_requires_developer_id() {
        let release_app = Path::new(BUNDLES[0].0);
        let dev_app = Path::new(BUNDLES[1].0);
        let release = requirement(release_app, "com.cmuxterm.cua").unwrap();
        assert!(release.contains("7WLXT3NR37"));
        assert!(release.contains("1.2.840.113635.100.6.1.13"));
        assert!(requirement(dev_app, "com.cmuxterm.cua.dev").unwrap().contains("7WLXT3NR37"));
        assert!(requirement(release_app, "com.cmuxterm.cua.dev").is_none());
        assert!(requirement(dev_app, "com.cmuxterm.cua").is_none());
        assert!(requirement(release_app, "com.cmuxterm.remote").is_none());
    }
}

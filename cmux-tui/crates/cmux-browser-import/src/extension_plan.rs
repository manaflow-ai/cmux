//! What an import of extensions does in one cmux browser profile (`chromium.extension_install_plan`):
//! which store pages to open and which unpacked folders to copy, leaving out what the profile
//! already has, so importing the same browser twice installs nothing twice.

use crate::chromium;
use crate::model::{Extension, InstalledExtension};
use crate::place::Place;
use std::collections::HashSet;

/// The steps for one target profile, in the order the extensions came.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InstallPlan {
    /// Web Store installs the profile lacks: each opens its store page there.
    pub store: Vec<Extension>,
    /// Unpacked extensions the profile lacks, each with the folder its copy goes to.
    pub unpacked: Vec<(Extension, String)>,
    /// Extensions the profile already has (by id, or an unpacked copy by its folder), left alone.
    pub installed: usize,
}

/// Plans `extensions` (several source profiles' lists, an id named twice counts once, the first
/// wins) into the cmux profile at `profile`, whose unpacked copies live under `copy_root`
/// (`<copy_root>/<id>`, so a second import finds the copy the first one loaded). `None` when
/// `copy_root` is not an absolute path.
pub fn install_plan<'a>(
    extensions: &[Extension],
    profile: impl Into<Place<'a>>,
    copy_root: &str,
) -> Option<InstallPlan> {
    plan(extensions, &chromium::installed_extensions(profile), copy_root)
}

/// [`install_plan`] over a profile's installed list already read.
pub fn plan(
    extensions: &[Extension],
    installed: &[InstalledExtension],
    copy_root: &str,
) -> Option<InstallPlan> {
    if !copy_root.starts_with('/') {
        return None;
    }
    let root = copy_root.trim_end_matches('/');
    let ids: HashSet<&str> = installed.iter().map(|e| e.id.as_str()).collect();
    let folders: HashSet<&str> = installed.iter().filter_map(|e| e.path.as_deref()).collect();
    let mut seen = HashSet::new();
    let mut result = InstallPlan::default();
    for extension in extensions {
        if !Extension::is_valid_id(&extension.id) || !seen.insert(extension.id.as_str()) {
            continue;
        }
        if ids.contains(extension.id.as_str()) {
            result.installed += 1;
        } else if extension.from_web_store {
            result.store.push(extension.clone());
        } else if extension.unpacked_path.is_some() {
            let copy = format!("{root}/{}", extension.id);
            if folders.contains(copy.as_str()) {
                result.installed += 1;
            } else {
                result.unpacked.push((extension.clone(), copy));
            }
        }
    }
    Some(result)
}

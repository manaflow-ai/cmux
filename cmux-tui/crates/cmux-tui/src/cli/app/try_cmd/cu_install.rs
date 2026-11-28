//! `cmux computer-use install [--from nightly|PR|SHA|branch] [--dry-run]`: the signed Computer
//! Use helper on a Mac with no cmux app, for a standalone `cmux` CLI (the wheel, a release
//! binary). The daemon's launcher (cmux-tui-core `computer_use_host/macos.rs` `find_helper`)
//! looks in the app holding it, then the installed apps, then the folder this command fills,
//! `cmux_signed_bundle::standalone_app` (`~/Library/Application Support/cmux-next/standalone`,
//! laid out as an app's `Contents/Library`), so an installed app's own helper always wins.
//!
//! The checks are `cmux computer-use upgrade`'s (try_cmd/helper.rs `fetch_checked`): the
//! build's signed `mac-live.json` (Ed25519, the updater's trusted keys) names the helper zip,
//! its sha256, size, bundle id, team and designated requirement, which must be the Developer
//! ID form of that bundle id and team ([`helper::developer_id_requirement`]); the zip is
//! fetched, its size and sha256 checked, unpacked (no entry may leave its folder), and its one
//! bundle verified with `codesign` against that requirement. With no installed helper to anchor
//! the trust, the anchor is the signed build record and cmux's own team. Then the bundle is
//! swapped in (`renamex_np(RENAME_SWAP)`) and staged to the fixed path the worker runs from, so
//! macOS asks for Screen Recording and Accessibility once, for the helper, at its first use.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::cu_upgrade::{self, Host, Source};
use super::helper::{self, Signing, WantedHelper};
use super::live::Store;
use super::{GlobalArgs, OutputMode};

/// The team every published helper is signed by (cmux-tui-team-signed.yml).
pub(super) const TEAM: &str = "7WLXT3NR37";
/// The receipt of the last install, in the standalone folder.
pub(super) const RECEIPT: &str = "install.json";
/// The prefix of an install's temporary folder beside the installed helper.
const STAGING_PREFIX: &str = ".install-";
/// Where macOS lists the grants the helper asks for.
const SCREEN_RECORDING_PANE: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";

/// The refusal for `--machine`: the install puts the helper on this Mac only.
pub(in crate::cli) const NOT_REMOTE: &str = "cmux computer-use install puts the helper on this Mac only; run it on that machine itself (it takes no --machine)";

/// A parsed `cmux computer-use install`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Request {
    pub source: Source,
    pub dry_run: bool,
}

/// The words after `install`: `--from V`, `--dry-run`.
pub(in crate::cli) fn parse(rest: &[&str]) -> Result<Request, String> {
    let upgrade = cu_upgrade::parse(rest).map_err(|error| {
        if error == cu_upgrade::NOT_REMOTE { NOT_REMOTE.to_owned() } else { error }
    })?;
    if upgrade.undo {
        return Err(
            "install takes no --undo; run `cmux computer-use install` again to replace the helper"
                .into(),
        );
    }
    Ok(Request { source: upgrade.source, dry_run: upgrade.dry_run })
}

/// The helper bundles already in `library` (sorted), the hidden install folders left out.
fn present(library: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = fs::read_dir(library)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            !name.starts_with('.') && helper::is_helper_name(&name)
        })
        .map(|entry| entry.path())
        .collect();
    found.sort();
    found
}

/// The install into `standalone` (the testable core). `existing` is a cmux app's own helper,
/// when one is installed: it is the one the daemon runs, so nothing is installed beside it.
#[allow(clippy::too_many_arguments)]
pub(super) fn install_with(
    standalone: &Path,
    existing: Option<&Path>,
    wanted: &WantedHelper,
    store: &Store,
    signing: &dyn Signing,
    host: &dyn Host,
    dry_run: bool,
    build: Value,
) -> Result<Value, String> {
    let mut receipt = Map::new();
    receipt.insert("action".into(), json!("computer-use-install"));
    if let Value::Object(build) = build {
        receipt.extend(build);
    }
    if let Some(existing) = existing {
        receipt.insert("did".into(), json!("untouched"));
        receipt.insert("bundle".into(), json!(existing.to_string_lossy()));
        receipt.insert(
            "why".into(),
            json!(format!(
                "{} already has the signed helper; change it with `cmux computer-use upgrade`",
                cmux_signed_bundle::app_of(existing)
                    .unwrap_or_else(|| existing.to_path_buf())
                    .display()
            )),
        );
        return Ok(Value::Object(receipt));
    }
    let _lock = store.lock()?;
    // `wanted` already checked the requirement is the Developer ID form of its bundle id and
    // team; the team must also be cmux's own, as the cmux app's helper always is.
    if wanted.file.team.as_deref() != Some(TEAM) {
        return Err(format!(
            "the build's helper is signed by team {}, not cmux's ({TEAM}); nothing was installed",
            wanted.file.team.as_deref().unwrap_or("(none)")
        ));
    }
    let requirement = helper::developer_id_requirement(&wanted.file.bundle_id, TEAM);
    let library = standalone.join(helper::LIBRARY);
    cmux_signed_bundle::private_dir(standalone)?;
    fs::create_dir_all(&library).map_err(|e| format!("{}: {e}", library.display()))?;
    let staging = tempfile::Builder::new()
        .prefix(STAGING_PREFIX)
        .tempdir_in(&library)
        .map_err(|e| format!("{}: {e}", library.display()))?;
    let checked = helper::fetch_checked(
        wanted,
        store,
        signing,
        staging.path(),
        &wanted.file.bundle_id,
        &requirement,
    )?;
    let name = checked.file_name().ok_or("the helper has no name")?.to_owned();
    let dest = library.join(&name);
    let to = helper::digest(&checked)?;
    let before = present(&library);
    let from = dest.is_dir().then(|| helper::digest(&dest).ok()).flatten();
    receipt.insert("bundle".into(), json!(dest.to_string_lossy()));
    receipt.insert("bundle_id".into(), json!(wanted.file.bundle_id));
    receipt.insert("from_digest".into(), json!(from));
    receipt.insert("to_digest".into(), json!(to));
    if dry_run {
        receipt.insert("did".into(), json!("checked"));
        return Ok(Value::Object(receipt));
    }
    if from.as_deref() != Some(to.as_str()) {
        cmux_signed_bundle::swap_into(&checked, &dest)
            .map_err(|e| format!("{}: {e}", dest.display()))?;
    }
    // One helper in the folder: an older name's bundle would be a second Screen Recording holder.
    for other in before.iter().filter(|path| **path != dest) {
        let _ = fs::remove_dir_all(other);
    }
    drop(staging);
    let staged = host.restage(&dest)?;
    receipt.insert(
        "did".into(),
        json!(if from.as_deref() == Some(to.as_str()) { "current" } else { "installed" }),
    );
    receipt.insert("staged".into(), json!(staged.to_string_lossy()));
    receipt.insert("at".into(), json!(super::now()));
    let receipt = Value::Object(receipt);
    cu_upgrade::write_json(&standalone.join(RECEIPT), &receipt)?;
    Ok(receipt)
}

fn human(receipt: &Value) -> String {
    let text = |key: &str| receipt.get(key).and_then(Value::as_str).unwrap_or_default();
    let short = |digest: &str| digest.get(..12).unwrap_or(digest).to_owned();
    let next = format!(
        "\nNext: turn Computer Use on (`cmux settings set computerUse.mode ask`), then run \
         `cmux computer-use doctor`. At its first capture macOS asks for Screen Recording and \
         Accessibility for the helper, not for your terminal (System Settings > Privacy & \
         Security; `open \"{SCREEN_RECORDING_PANE}\"`)."
    );
    match text("did") {
        "untouched" => format!("Computer Use helper not installed: {}", text("why")),
        "checked" => format!(
            "Computer Use helper {} checked for {}; nothing installed (--dry-run)",
            short(text("to_digest")),
            text("bundle")
        ),
        "current" => format!("Computer Use helper already installed at {}{next}", text("bundle")),
        _ => format!(
            "Computer Use helper {} installed at {}{next}",
            short(text("to_digest")),
            text("bundle")
        ),
    }
}

fn print(global: &GlobalArgs, result: Result<Value, String>) -> i32 {
    match result {
        Ok(receipt) if global.output == OutputMode::Human => {
            println!("{}", human(&receipt));
            0
        }
        Ok(receipt) => crate::cli::wire::print_local_success(&receipt, global.output),
        Err(message) => super::failure("computer_use.install", &message, global.output),
    }
}

/// A cmux app's own helper on this Mac, as the daemon searches for one before the standalone
/// folder: the app holding this CLI, then the installed apps.
fn app_helper() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let apps = cmux_signed_bundle::search_apps(&exe, &cmux_signed_bundle::INSTALLED_APPS);
    cmux_signed_bundle::first_helper(&apps, helper::EXECUTABLE)
}

/// Runs `request` on this Mac.
pub(in crate::cli) fn run(global: &GlobalArgs, request: &Request, host: &dyn Host) -> i32 {
    if !cfg!(target_os = "macos") {
        return print(
            global,
            Err("Computer Use on Linux and Windows runs inside cmux itself; there is no helper to install".into()),
        );
    }
    let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()).map(PathBuf::from)
    else {
        return print(
            global,
            Err("cmux can't find your home folder (HOME is empty): run this from a login shell"
                .into()),
        );
    };
    let standalone = cmux_signed_bundle::standalone_app(&home);
    let store = Store { root: standalone.join("downloads") };
    let existing = app_helper();
    let result = cu_upgrade::commit_of(&request.source).and_then(|(commit, build)| {
        let wanted = cu_upgrade::wanted_of(&commit)?;
        install_with(
            &standalone,
            existing.as_deref(),
            &wanted,
            &store,
            &helper::SystemSigning,
            host,
            request.dry_run,
            build,
        )
    });
    print(global, result)
}

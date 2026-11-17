//! `cmux ext new NAME [--kind sidebar|session-info|pane|newtab|command]`: a working extension
//! folder from templates embedded in the binary (manifest v2, `src/main.ts`
//! on the public SDK, its built `dist/main.js`, a README with the loop, and
//! the API types). Each kind loads as written, and a save to its source is
//! on screen within a second (`ext::kinds_tests`).
//!
//! `dist/main.js` is the packer's build of `src/main.ts` (with its
//! placeholders), so the folder loads before bun is installed; `ext::tests`
//! checks each one against a fresh build.
//!
//! The SDK comes with the folder: `sdk/` is `cmux-extension-sdk` exactly as
//! this binary was built with it (its TypeScript source and the runtime's
//! event and scope tables, embedded at build time), and `tsconfig.json`
//! points the import there. So the scaffold needs no npm account or
//! registry, works offline, and its SDK `API_VERSION` is always the one of
//! the cmux that made it (the app bundle carries this binary).

use std::path::{Path, PathBuf};

use super::publish::{self, Repo};

/// The kinds `--kind` takes (`section` is `sidebar`'s first name).
pub(super) const KINDS: &[&str] =
    &["sidebar", "section", "session-info", "pane", "newtab", "command"];

/// The first lines of every kind's `dist/main.js`; the packer's build follows.
#[cfg(test)]
pub(super) const FIRST_BUILD_HEADER: &str = "// The packer's build of src/main.ts, so this folder loads before bun is installed. `cmux ext dev`\n\
// rebuilds it on every save. Do not edit; edit src/main.ts.\n\
";

/// Kinds whose cmux interface has not landed: the kind, the interface it
/// needs, and what to make meanwhile. `ext new` refuses them by name rather
/// than scaffold an API this cmux does not have.
pub(super) const PENDING: &[(&str, &str, &str)] =
    &[("menu", "cmux.context_menu/1", "--kind command makes a command for the command palette")];

/// Why `kind` cannot be made, when it is one of `PENDING`.
pub(super) fn pending(kind: &str) -> Option<String> {
    PENDING.iter().find(|(name, ..)| *name == kind).map(|(_, needs, meanwhile)| {
        format!(
            "--kind {kind} needs the {needs} interface, which this cmux does not have yet; meanwhile {meanwhile}"
        )
    })
}

const SECTION: &[(&str, &str)] = &[
    ("cmux-app.json", include_str!("templates/section/cmux-app.json")),
    ("src/main.ts", include_str!("templates/section/src/main.ts")),
    ("dist/main.js", include_str!("templates/section/dist/main.js")),
];

const PANE: &[(&str, &str)] = &[
    ("cmux-app.json", include_str!("templates/pane/cmux-app.json")),
    ("src/main.ts", include_str!("templates/pane/src/main.ts")),
    ("dist/main.js", include_str!("templates/pane/dist/main.js")),
];

const SESSION_INFO: &[(&str, &str)] = &[
    ("cmux-app.json", include_str!("templates/session-info/cmux-app.json")),
    ("src/main.ts", include_str!("templates/session-info/src/main.ts")),
    ("dist/main.js", include_str!("templates/session-info/dist/main.js")),
];

const NEWTAB: &[(&str, &str)] = &[
    ("cmux-app.json", include_str!("templates/newtab/cmux-app.json")),
    ("src/main.ts", include_str!("templates/newtab/src/main.ts")),
    ("dist/main.js", include_str!("templates/newtab/dist/main.js")),
];

const COMMAND: &[(&str, &str)] = &[
    ("cmux-app.json", include_str!("templates/command/cmux-app.json")),
    ("catalog.json", include_str!("templates/command/catalog.json")),
    ("src/main.ts", include_str!("templates/command/src/main.ts")),
    ("dist/main.js", include_str!("templates/command/dist/main.js")),
];

/// Every kind's project files around the code.
const COMMON: &[(&str, &str)] = &[
    ("README.md", include_str!("templates/common/README.md")),
    // Stored without its dot, so it does not apply to the templates folder.
    (".gitignore", include_str!("templates/common/gitignore")),
    ("package.json", include_str!("templates/common/package.json")),
    ("tsconfig.json", include_str!("templates/common/tsconfig.json")),
];

/// The types `src/main.ts` and the SDK reference: the generated app global
/// from the capability manifest, the same file `cmux script types` starts
/// with. `cmux ext dev` refreshes it from the running cmux when that one differs.
const TYPES: &str = cmux_app_manifest::capabilities::APP_TYPES;

/// The public SDK as this binary was built with it.
pub(super) const SDK_INDEX: &str =
    include_str!("../../../../cmux-extension-sdk/typescript/src/index.ts");
const SDK_PACKAGE: &str = include_str!("../../../../cmux-extension-sdk/typescript/package.json");
const SDK_README: &str = include_str!("../../../../cmux-extension-sdk/README.md");
const SDK_EVENTS: &str = include_str!("../../../../cmux-app-host/schema/v2/events.json");
/// The scope table, whose `apiVersion` is the SDK's `API_VERSION`.
pub(super) const SDK_SCOPES: &str = cmux_app_manifest::capabilities::SCOPES_JSON;

/// The SDK source's paths into the cmux repository, and where the vendored
/// copy finds the same files (`sdk/src/index.ts` -> `sdk/tables/…`, the
/// project's `cmux-app.d.ts`).
const SDK_PATHS: &[(&str, &str)] = &[
    ("../../../cmux-app-host/generated/cmux-app.d.ts", "../../cmux-app.d.ts"),
    ("../../../cmux-app-host/schema/v2/events.json", "../tables/events.json"),
    ("../../../cmux-app-host/generated/scopes.json", "../tables/scopes.json"),
];

/// `sdk/`: the SDK's files with its imports pointed at the copied tables.
pub(super) fn sdk_files() -> Vec<(&'static str, String)> {
    let index =
        SDK_PATHS.iter().fold(SDK_INDEX.to_string(), |text, (from, to)| text.replace(from, to));
    vec![
        ("sdk/package.json", SDK_PACKAGE.to_string()),
        ("sdk/README.md", SDK_README.to_string()),
        ("sdk/src/index.ts", index),
        ("sdk/tables/events.json", SDK_EVENTS.to_string()),
        ("sdk/tables/scopes.json", SDK_SCOPES.to_string()),
    ]
}

/// Whether `name` makes a valid id `local/<name>` (the manifest schema's
/// name part) other than the customize folder's.
pub(super) fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    let first_ok = chars.next().is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    first_ok
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && name != "customize"
}

/// Why `name` cannot be a command extension's `cmux NAME` word, if it can't:
/// the manifest's `cli.name` must start with a letter, be 2 to 24
/// characters and not be a cmux word.
pub(super) fn cli_name_problem(name: &str) -> Option<String> {
    // The manifest schema's `cli.name`: `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`, 2 to 24 long.
    let shape = name.starts_with(|c: char| c.is_ascii_lowercase())
        && (2..=24).contains(&name.len())
        && name.split('-').all(|part| {
            !part.is_empty() && part.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        });
    if !shape {
        return Some(format!(
            "--kind command makes `cmux {name} …`, which needs a name of 2 to 24 lowercase letters, digits and single dashes that starts with a letter"
        ));
    }
    cmux_app_manifest::is_reserved_cli_name(name).then(|| {
        format!(
            "--kind command makes `cmux {name} …`, but {name} is a cmux command; pick another name"
        )
    })
}

/// `my-prs` -> `My prs`.
fn title(name: &str) -> String {
    let words = name.replace('-', " ");
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
        None => String::new(),
    }
}

/// The README lines that differ by kind: what it is, how to use it, extra files.
fn readme_parts(kind: &str) -> (&'static str, &'static str, &'static str) {
    match kind {
        "pane" => (
            "a pane that lists your workspaces.",
            "Open the pane from the command palette by its title.",
            "",
        ),
        "session-info" => (
            "a section in an agent chat's Session Info panel.",
            "It shows in the Session Info panel of every agent chat; its context is that chat's session\n(`cwd`, `branch`, `harness`).",
            "",
        ),
        "newtab" => (
            "a whole New Tab page.",
            "Pick it as your New Tab page: `cmux settings set tabs.newTabApp local/{{NAME}}` (Settings >\nTabs > New Tab App); unset it to get cmux's own page back.",
            "",
        ),
        "command" => (
            "a command.",
            "Run it from the command palette, from a terminal as `cmux {{NAME}} hello [NAME]`, or as\n`cmux apps run local/{{NAME}} hello`. `catalog.json` says where it is offered: its `cli.path`,\n`palette` title and `mcp.expose` (agents see it as a tool).",
            "\n- `catalog.json`: the command (`{{NS}}.hello`): its arguments, result, risk and where it shows.",
        ),
        _ => ("one sidebar section.", "Place the section from the sidebar's edit mode.", ""),
    }
}

/// The id of extension `name`: `PUBLISHER/NAME` when it has a GitHub
/// repository (the owner, lowercased, as the store requires), else
/// `local/NAME`.
pub(super) fn app_id(name: &str, repo: Option<&Repo>) -> String {
    match repo {
        Some(repo) => format!("{}/{name}", repo.publisher()),
        None => format!("local/{name}"),
    }
}

/// The files of a new `kind` extension called `name`, by relative path, published from `repo`: its id is the owner's,
/// the manifest names the repository, and the README's badge and install
/// line point at it (marked placeholders with none).
pub(super) fn files_for(
    name: &str,
    kind: &str,
    repo: Option<&Repo>,
) -> Option<Vec<(&'static str, String)>> {
    let templates = match kind {
        "sidebar" | "section" => SECTION,
        "pane" => PANE,
        "session-info" => SESSION_INFO,
        "newtab" => NEWTAB,
        "command" => COMMAND,
        _ => return None,
    };
    let (what, usage, extra) = readme_parts(kind);
    let title = title(name);
    let id = app_id(name, repo);
    let namespace = cmux_app_manifest::app_namespace(&id);
    let badge = publish::readme_badge(repo);
    let install = publish::readme_install(repo);
    // The manifest's id line, and the repository under it.
    let local_id_line = format!("\"id\": \"local/{name}\",");
    let id_line = match repo {
        Some(repo) => format!("\"id\": \"{id}\",\n  \"repository\": \"{}\",", repo.url()),
        None => local_id_line.clone(),
    };
    let fill = |text: &str| {
        text.replace("{{WHAT}}", what)
            .replace("{{USE}}", usage)
            .replace("{{FILES}}", extra)
            .replace("{{BADGE}}", &badge)
            .replace("{{INSTALL}}", &install)
            .replace("{{ID}}", &id)
            .replace("{{NAME}}", name)
            .replace("{{TITLE}}", &title)
            .replace("{{NS}}", &namespace)
            .replace(&local_id_line, &id_line)
    };
    let mut out: Vec<(&'static str, String)> =
        templates.iter().chain(COMMON).map(|(path, text)| (*path, fill(text))).collect();
    out.push(("cmux-app.d.ts", TYPES.to_string()));
    out.extend(sdk_files());
    Some(out)
}

/// Writes a new extension into `dir`, which must not exist yet (or be
/// empty); returns the files written.
#[cfg(test)]
pub(super) fn scaffold(dir: &Path, name: &str, kind: &str) -> Result<Vec<PathBuf>, String> {
    scaffold_for(dir, name, kind, None)
}

/// `scaffold` for an extension published from `repo`. A folder that holds
/// only `.git` (a clone of a new, empty repository) counts as empty.
pub(super) fn scaffold_for(
    dir: &Path,
    name: &str,
    kind: &str,
    repo: Option<&Repo>,
) -> Result<Vec<PathBuf>, String> {
    if let Some(problem) = repo.and_then(Repo::publisher_problem) {
        return Err(problem);
    }
    let files = files_for(name, kind, repo).ok_or_else(|| {
        format!("--kind {kind} is not one cmux ext new makes; it makes {}", KINDS.join(", "))
    })?;
    if kind == "command"
        && let Some(problem) = cli_name_problem(name)
    {
        return Err(problem);
    }
    let occupied = std::fs::read_dir(dir).is_ok_and(|mut entries| {
        entries.any(|entry| !entry.is_ok_and(|entry| entry.file_name() == ".git"))
    });
    if occupied {
        return Err(format!("{} already exists and is not empty", dir.display()));
    }
    let mut written = Vec::new();
    for (rel, text) in files {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        std::fs::write(&path, text).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        written.push(path);
    }
    Ok(written)
}

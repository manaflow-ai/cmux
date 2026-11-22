//! The code editors Open in Editor knows, and which one opens a folder. The
//! App asks the system only which bundle ids resolve on this Mac; the table,
//! its order and the pick are here. cmux.json `editor.default` names one of
//! [`EDITORS`] by id (schemas/settings/source/browser.json lists the same ids).

use serde::{Deserialize, Serialize};

/// One editor of the table.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Editor {
    /// The id `editor.default` and an action's `app` name it by.
    pub id: &'static str,
    pub name: &'static str,
    /// Its bundle ids, in preference order (the release before a preview).
    pub bundle_ids: &'static [&'static str],
    /// The SF Symbol of its menu row.
    pub symbol: &'static str,
    /// The URL scheme of its Remote-SSH open (`<scheme>://vscode-remote/ssh-remote+HOST/PATH`), when it has one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_scheme: Option<&'static str>,
}

const fn editor(
    id: &'static str,
    name: &'static str,
    bundle_ids: &'static [&'static str],
    symbol: &'static str,
    remote_scheme: Option<&'static str>,
) -> Editor {
    Editor { id, name, bundle_ids, symbol, remote_scheme }
}

const JETBRAINS: &str = "curlybraces";

/// Every editor Open in Editor knows, in the order `auto` tries them.
pub const EDITORS: &[Editor] = &[
    editor(
        "vscode",
        "Visual Studio Code",
        &["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
        "chevron.left.forwardslash.chevron.right",
        Some("vscode"),
    ),
    editor("cursor", "Cursor", &["com.todesktop.230313mzl4w4u92"], "cursorarrow", Some("cursor")),
    editor("zed", "Zed", &["dev.zed.Zed", "dev.zed.Zed-Preview"], "bolt", None),
    editor("xcode", "Xcode", &["com.apple.dt.Xcode"], "hammer", None),
    editor(
        "sublime",
        "Sublime Text",
        &["com.sublimetext.4", "com.sublimetext.3"],
        "text.cursor",
        None,
    ),
    editor(
        "intellij",
        "IntelliJ IDEA",
        &["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
        JETBRAINS,
        None,
    ),
    editor("webstorm", "WebStorm", &["com.jetbrains.WebStorm"], JETBRAINS, None),
    editor(
        "pycharm",
        "PyCharm",
        &["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"],
        JETBRAINS,
        None,
    ),
    editor("goland", "GoLand", &["com.jetbrains.goland"], JETBRAINS, None),
    editor("rustrover", "RustRover", &["com.jetbrains.rustrover"], JETBRAINS, None),
    editor("clion", "CLion", &["com.jetbrains.CLion"], JETBRAINS, None),
    editor("phpstorm", "PhpStorm", &["com.jetbrains.PhpStorm"], JETBRAINS, None),
    editor("rubymine", "RubyMine", &["com.jetbrains.rubymine"], JETBRAINS, None),
    editor("rider", "Rider", &["com.jetbrains.rider"], JETBRAINS, None),
    editor("fleet", "Fleet", &["com.jetbrains.fleet"], JETBRAINS, None),
    editor("nova", "Nova", &["com.panic.Nova"], "sparkles", None),
];

/// The editor `id` names, if the table has it.
pub fn by_id(id: &str) -> Option<&'static Editor> {
    EDITORS.iter().find(|editor| editor.id == id)
}

/// What the App knows: the editor ids installed here and the person's
/// `editor.default` (None for `auto`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PickFacts {
    #[serde(default)]
    pub installed: Vec<String>,
    #[serde(default)]
    pub configured: Option<String>,
}

/// Which editor opens a folder, and every installed one in menu order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pick {
    /// The configured editor when installed, else the first installed in
    /// table order; None when no editor of the table is installed.
    pub default: Option<String>,
    /// The installed editors of the table, the default first, then table order.
    pub ordered: Vec<String>,
}

/// The pick among `facts.installed`. Ids the table does not know are dropped;
/// a configured editor that is not installed is passed over (`auto`'s order).
pub fn pick(facts: &PickFacts) -> Pick {
    let installed: Vec<&str> = EDITORS
        .iter()
        .map(|editor| editor.id)
        .filter(|id| facts.installed.iter().any(|installed| installed == id))
        .collect();
    let default = facts
        .configured
        .as_deref()
        .filter(|configured| installed.contains(configured))
        .or_else(|| installed.first().copied());
    let ordered = default
        .into_iter()
        .chain(installed.iter().copied().filter(|id| Some(*id) != default))
        .map(str::to_owned)
        .collect();
    Pick { default: default.map(str::to_owned), ordered }
}

#[cfg(test)]
#[path = "editors_tests.rs"]
mod tests;

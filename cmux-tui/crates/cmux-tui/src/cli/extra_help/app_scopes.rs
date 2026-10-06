//! Help for the app scopes (cli/app.rs), the app's browser pages and
//! `notify`, which route before the resource grammar's help.

use std::io::Write;

/// Prints the help `args` asks for (`<scope> … --help` or `help <scope>`)
/// when an app scope, a browser page or `notify` owns it. `None` leaves the
/// request to the resource grammar's help.
pub(in crate::cli) fn print(args: &[String]) -> Option<i32> {
    if let Some(code) = process_help(args) {
        return Some(code);
    }
    let text = text(args)?;
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(text.as_bytes());
    let _ = stdout.flush();
    Some(0)
}

/// `help acp|mcp|coderouter|link` runs that command's own `--help`, so the
/// two spellings print the same text.
fn process_help(args: &[String]) -> Option<i32> {
    let [help, scope] = args else { return None };
    if help.as_str() != "help" {
        return None;
    }
    let flag = || vec![scope.clone(), "--help".to_owned()];
    match scope.as_str() {
        "acp" => Some(crate::acp::run(vec!["--help".into()])),
        "link" => Some(crate::link::run(&["--help".to_owned()])),
        "mcp" => super::super::mcp::run_if_requested(&flag()),
        "coderouter" => super::super::coderouter::run_if_requested(&flag()),
        _ => None,
    }
}

fn text(args: &[String]) -> Option<String> {
    let words = args
        .iter()
        .take_while(|arg| arg.as_str() != "--")
        .filter(|arg| !arg.starts_with('-'))
        .map(String::as_str)
        .collect::<Vec<_>>();
    let words = match words.as_slice() {
        ["help", rest @ ..] => rest,
        all => all,
    };
    let messages = &crate::localization::catalog().app_control;
    let usage = match words {
        ["browser", target, ..] if *target == "page" || target.starts_with("tab_") => {
            format!("{}\n", messages.browser_page_usage)
        }
        ["notify", ..] => return Some(super::super::scope_help::NOTIFY_HELP.to_owned()),
        [scope, ..] if super::super::app::APP_SCOPES.contains(scope) => app_usage(scope, messages)?,
        _ => return None,
    };
    let scope = words[0];
    Some(format!("{usage}\n{}", APP_FOOTER.replace("{scope}", scope)))
}

fn app_usage(scope: &str, messages: &crate::localization::AppControlMessages) -> Option<String> {
    let text = match scope {
        "settings" => messages.settings_usage,
        "keybinding" => messages.keybinding_usage,
        "app" => APP_HELP,
        "window" => WINDOW_HELP,
        "action" => {
            return Some(format!(
                "{ACTION_LIST_USAGE}{}\n{}\n",
                messages.action_describe_usage, messages.action_run_usage
            ));
        }
        "events" => EVENTS_HELP,
        "history" => HISTORY_HELP,
        "bookmark" => BOOKMARK_HELP,
        "accounts" => ACCOUNTS_HELP,
        "open" => OPEN_HELP,
        "ghostty" => GHOSTTY_HELP,
        _ => return None,
    };
    Some(format!("{}\n", text.trim_end()))
}

const APP_FOOTER: &str = "\
The cmux app answers this scope: run it inside a cmux terminal, with the cmux
bundled in the app, or with --app-socket <path>. Other words run the app
action with that CLI name: `cmux action list --noun {scope}` lists them.
";

const APP_HELP: &str = "\
usage: cmux app ping | identify | capabilities
       cmux app call <method> [<json-object>]   (debug builds only)
       cmux app <verb...> [--<argument> <value>]...";

const WINDOW_HELP: &str = "\
usage: cmux window list
       cmux window <verb...> [--target <id>]   (an app action)";

const ACTION_LIST_USAGE: &str =
    "usage: cmux action list [--category <category>] [--noun <noun>] [--available]\n";

const EVENTS_HELP: &str = "\
usage: cmux events [--after <seq>] [--name <name>]... [--category <category>]...
       [--no-heartbeats]
Prints one JSON line per app event until interrupted.";

const HISTORY_HELP: &str = "\
usage: cmux history list [--kind <kind>] [--range <range>] [--limit <n>]
       cmux history search <text> [--kind <kind>] [--range <range>] [--limit <n>]";

const BOOKMARK_HELP: &str = "\
usage: cmux bookmark list [--folder <folder>] [--profile <profile>] [--limit <n>]
       cmux bookmark search <text> [--folder <folder>] [--profile <profile>] [--limit <n>]";

const ACCOUNTS_HELP: &str = "\
usage: cmux accounts list
Lists the app's AI provider accounts; secrets are never printed.";

const OPEN_HELP: &str = "\
usage: cmux open <path|url>... [--focus [true|false]] [--no-focus]
URLs open in a browser split, folders in a new workspace, files in the app.";

const GHOSTTY_HELP: &str = "\
usage: cmux ghostty diagnostics
The Ghostty config keys and keybind actions cmux does not apply.";

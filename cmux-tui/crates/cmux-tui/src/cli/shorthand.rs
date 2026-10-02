//! Human-facing spellings lower to the public resource grammar, never raw RPC.
use super::UsageError;

struct Alias {
    names: &'static [&'static str],
    path: &'static [&'static str],
    target_scope: Option<&'static str>,
    options: &'static [(&'static str, &'static str)],
}

const ALIASES: &[Alias] = &[
    Alias {
        names: &["list-sessions", "ls"],
        path: &["session", "list"],
        target_scope: None,
        options: &[],
    },
    Alias {
        names: &["list-windows", "lsw"],
        path: &["screen", "list"],
        target_scope: Some("workspace"),
        options: &[],
    },
    Alias {
        names: &["list-panes", "lsp"],
        path: &["pane", "list"],
        target_scope: Some("screen"),
        options: &[],
    },
    Alias {
        names: &["new-window", "neww"],
        path: &["screen", "create"],
        target_scope: Some("workspace"),
        options: &[("-n", "--name")],
    },
    Alias {
        names: &["split-window", "splitw"],
        path: &["pane", "@", "split"],
        target_scope: Some("pane"),
        options: &[("-h", "--right"), ("-v", "--down"), ("-c", "--cwd")],
    },
    Alias {
        names: &["select-pane", "selectp"],
        path: &["pane", "@", "focus"],
        target_scope: Some("pane"),
        options: &[("-L", "--left"), ("-R", "--right"), ("-U", "--up"), ("-D", "--down")],
    },
    Alias {
        names: &["select-window", "selectw"],
        path: &["screen", "@", "focus"],
        target_scope: Some("screen"),
        options: &[],
    },
    Alias {
        names: &["rename-window", "renamew"],
        path: &["screen", "@", "rename"],
        target_scope: Some("screen"),
        options: &[],
    },
    Alias {
        names: &["capture-pane", "capturep"],
        path: &["terminal", "@", "screen", "read"],
        target_scope: Some("terminal"),
        options: &[("-p", "--print")],
    },
    Alias {
        names: &["send-keys"],
        path: &["terminal", "@", "keys"],
        target_scope: Some("terminal"),
        options: &[("-l", "--literal")],
    },
];

pub(super) fn scope(word: &str) -> &str {
    match word {
        "ws" => "workspace",
        "win" | "window" => "screen",
        "p" => "pane",
        "term" => "terminal",
        "notif" => "notification",
        "srv" => "server",
        _ => word,
    }
}

pub(super) fn short_value_option(word: &str) -> bool {
    matches!(word, "-t" | "-n" | "-c")
}

fn error(value: &str) -> UsageError {
    UsageError::new(
        crate::localization::catalog().local_server.shorthand_invalid.replace("{value}", value),
    )
}

/// Preserve values and forwarded argv while translating only recognized aliases.
pub(super) fn normalize(args: &[String]) -> Result<Vec<String>, UsageError> {
    let Some(first) = args.first() else { return Ok(Vec::new()) };
    let Some(alias) = ALIASES.iter().find(|alias| alias.names.contains(&first.as_str())) else {
        let mut result = args.to_vec();
        result[0] = scope(first).to_string();
        return Ok(result);
    };
    let mut target = None;
    let mut options = Vec::new();
    let mut positionals = Vec::new();
    let mut direction = None;
    let mut literal = false;
    let mut print = false;
    let mut index = 1;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--" {
            positionals.extend_from_slice(&args[index + 1..]);
            break;
        }
        let (raw_flag, inline) =
            arg.split_once('=').map_or((arg.as_str(), None), |(k, v)| (k, Some(v)));
        let flag = alias
            .options
            .iter()
            .find(|(short, _)| *short == raw_flag)
            .map_or(raw_flag, |(_, long)| *long);
        if flag == "--help" || (flag == "-h" && first != "split-window" && first != "splitw") {
            return Ok(vec![alias.path[0].into(), "--help".into()]);
        }
        if flag == "-t" || flag == "--target" {
            if alias.target_scope.is_none() || target.is_some() {
                return Err(error(arg));
            }
            let value = if let Some(value) = inline {
                value.to_string()
            } else {
                index += 1;
                args.get(index).cloned().ok_or_else(|| error(arg))?
            };
            if value.is_empty() || (inline.is_none() && value.starts_with('-')) {
                return Err(error(arg));
            }
            target = Some(value);
        } else if matches!(flag, "--left" | "--right" | "--up" | "--down")
            && matches!(alias.path[2..], ["split"] | ["focus"])
        {
            if inline.is_some() || direction.is_some() {
                return Err(error(arg));
            }
            direction = Some(flag.trim_start_matches("--").to_string());
        } else if flag == "--literal" && alias.names[0] == "send-keys" {
            if inline.is_some() || literal {
                return Err(error(arg));
            }
            literal = true;
        } else if flag == "--print" && alias.names[0] == "capture-pane" {
            if inline.is_some() || print {
                return Err(error(arg));
            }
            print = true;
        } else if flag.starts_with("--") {
            // Canonical long options retain their ordinary validation downstream.
            options.push(if let Some(value) = inline {
                format!("{flag}={value}")
            } else {
                flag.to_string()
            });
            if inline.is_none() && !super::command::is_boolean_flag(flag.trim_start_matches("--")) {
                index += 1;
                options.push(args.get(index).cloned().ok_or_else(|| error(arg))?);
            }
        } else if flag.starts_with('-') {
            return Err(error(arg));
        } else {
            positionals.push(arg.clone());
        }
        index += 1;
    }
    let mut path = Vec::new();
    if !alias.path.contains(&"@") {
        if let Some(target) = target {
            path.extend([alias.target_scope.expect("target validated").into(), target]);
        }
        path.extend(alias.path.iter().map(|s| (*s).to_string()));
    } else if alias.target_scope == Some("terminal")
        && target.as_deref().is_some_and(|s| s.starts_with("pane_"))
    {
        path.extend(["pane".into(), target.expect("pane target"), "tab".into(), "current".into()]);
        path.extend(
            alias.path.iter().map(|s| if *s == "@" { "current".into() } else { (*s).to_string() }),
        );
    } else {
        let target = target.unwrap_or_else(|| "current".into());
        path.extend(
            alias.path.iter().map(|s| if *s == "@" { target.clone() } else { (*s).to_string() }),
        );
    }
    match alias.names[0] {
        "split-window" => options.push(format!("--{}", direction.as_deref().unwrap_or("down"))),
        "select-pane" => {
            if let Some(direction) = direction {
                path.extend(["direction".into(), direction]);
            }
        }
        "rename-window" if positionals.len() == 1 => {
            options.push(format!("--name={}", positionals.remove(0)));
        }
        "send-keys" => {
            if positionals.is_empty() {
                return Err(error(first));
            }
            if literal {
                *path.last_mut().expect("keys action") = "write".into();
                options.push(format!("--text={}", positionals.concat()));
            } else {
                for key in &positionals {
                    path.push(key_chord(key)?);
                }
            }
            positionals.clear();
        }
        _ => {}
    }
    if !positionals.is_empty() {
        return Err(error(&positionals.join(" ")));
    }
    path.extend(options);
    Ok(path)
}

fn key_chord(key: &str) -> Result<String, UsageError> {
    let mut remaining = key;
    let mut modifiers = String::new();
    loop {
        let (prefix, modifier) = if remaining.starts_with("C-") {
            ("C-", "ctrl+")
        } else if remaining.starts_with("M-") {
            ("M-", "alt+")
        } else if remaining.starts_with("S-") {
            ("S-", "shift+")
        } else {
            break;
        };
        remaining = &remaining[prefix.len()..];
        modifiers.push_str(modifier);
    }
    let name = match remaining {
        "BSpace" => "backspace".into(),
        "BTab" => "backtab".into(),
        "DC" => "delete".into(),
        "IC" => "insert".into(),
        "NPage" | "PgDn" => "pagedown".into(),
        "PPage" | "PgUp" => "pageup".into(),
        value if value.chars().count() == 1 => value.to_string(),
        value => value.to_ascii_lowercase(),
    };
    modifiers.push_str(&name);
    if ghostty_vt::key_input_from_chord(&modifiers).is_none() {
        return Err(error(key));
    }
    Ok(modifiers)
}

fn collection_action(scope: &str, value: &str) -> Option<&'static str> {
    match value {
        "ls" if !matches!(
            scope,
            "raw" | "provider" | "projection" | "sidebar" | "pairing" | "server"
        ) =>
        {
            Some("list")
        }
        "new" if matches!(scope, "workspace" | "screen" | "pane" | "tab" | "notification") => {
            Some("create")
        }
        _ => None,
    }
}

fn instance_actions(scope: &str) -> &'static [&'static str] {
    match scope {
        "workspace" => &["show", "rename", "move", "focus", "close", "run", "layout"],
        "screen" => &["show", "rename", "focus", "close", "layout"],
        "pane" => &[
            "show", "rename", "focus", "close", "split", "neighbor", "swap", "zoom", "viewport",
            "run",
        ],
        "tab" => &["show", "rename", "move", "focus", "close"],
        "terminal" => &[
            "show", "write", "keys", "mouse", "focus", "read", "screen", "state", "history",
            "output", "copy", "process", "viewport", "move", "project", "attach", "close",
        ],
        "browser" => &[
            "show", "navigate", "back", "forward", "reload", "activate", "key", "text", "mouse",
            "wheel", "attach", "close",
        ],
        "client" => &["show", "label", "metadata", "sizing", "cell", "detach"],
        "machine" => &["show"],
        "session" => &[
            "show",
            "snapshot",
            "ping",
            "open",
            "events",
            "journal",
            "config",
            "window",
            "terminal",
            "creation",
            "stop",
            "shutdown",
            "reset-state",
        ],
        _ => &[],
    }
}

fn instance_action<'a>(scope: &str, action: &'a str) -> &'a str {
    match action {
        "get" if instance_actions(scope).contains(&"show") => "show",
        "rm" if instance_actions(scope).contains(&"close") => "close",
        "select" if matches!(scope, "workspace" | "screen" | "pane" | "tab") => "focus",
        _ => action,
    }
}

fn child(parent: &str, candidate: &str) -> bool {
    matches!(
        (parent, candidate),
        ("workspace", "screen")
            | ("screen", "pane")
            | ("pane", "tab")
            | ("tab", "terminal" | "browser")
            | ("machine", "session")
    )
}

/// Walk resource positions only. Selectors, key names, scripts, and option values
/// are never globally substituted. Explicit selector paths take precedence.
pub(super) fn normalize_words(words: &mut Vec<String>) {
    let mut at = 0;
    while at < words.len() {
        let resource = scope(&words[at]).to_string();
        words[at] = resource.clone();
        let Some(next) = words.get(at + 1).cloned() else { break };
        if let Some(action) = words.get(at + 2).cloned() {
            let nested = scope(&action);
            if child(&resource, nested) {
                words[at + 2] = nested.to_string();
                at += 2;
                continue;
            }
            let canonical = instance_action(&resource, &action);
            if instance_actions(&resource).contains(&canonical) {
                words[at + 2] = canonical.to_string();
                break;
            }
        }
        if let Some(action) = collection_action(&resource, &next) {
            words[at + 1] = action.into();
            break;
        }
        // Terminal/browser tab creation has a resource word but no selector.
        if matches!(next.as_str(), "list" | "create") {
            break;
        }
        let action = instance_action(&resource, &next);
        if instance_actions(&resource).contains(&action) {
            words[at + 1] = action.to_string();
            words.insert(at + 1, "current".into());
        }
        break;
    }
}

pub(super) fn help(messages: &crate::localization::LocalServerMessages) -> String {
    let mut out = format!("{}\n\n", messages.shorthand_help);
    for alias in ALIASES {
        out.push_str(&format!(
            "  {} => {}\n",
            alias.names.join(" | "),
            alias.path.join(" ").replace('@', "<target>")
        ));
    }
    out.push_str("\n  ws => workspace; win/window => screen; p => pane; term => terminal\n  notif => notification; srv => server\n  ls => list; new => create; get => show; rm => close; select => focus\n");
    out
}

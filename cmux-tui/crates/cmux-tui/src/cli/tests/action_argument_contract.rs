//! The CLI-to-app action argument contract. The app exports every action's
//! arguments (name, kind, required) to plans/cmux-next/action-surfaces.json
//! (`ActionSurfaceExport.wireArgument`, kept current by the app's
//! `ActionSurfaceParityTests.exportIsFresh` and the PR autofix), and these
//! tests check every place the CLI names an app action's arguments by hand
//! against it, so a drifted name fails here, on Linux, before it merges.
//!
//! `cmux cloud start-chat` sent `--prompt-id` (`promptId` on the wire) to an
//! action whose argument was `prompt-id`, and every Cloud chat failed
//! `invalid_params` (#36193).
//!
//! What a call site is: the CLI names an app action by its CLI words
//! (`["cloud", "relay-chat", ...]`, `"share invite"`), by
//! `action_run_params("ID" | "cli name", ..)` or by `"action": "ID"`; until the
//! next `fn`, every `"--flag"` literal is that action's flag, and every
//! `.insert("key", ..)` or `"args": {"key": ..}` key after an
//! `action_run_params` or `"action":` is its argument.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

/// The `action.run` params the CLI sets beside `args` (`cli/app/run.rs`
/// `action_run_params`, `run_action`, `insert_run_key`).
const RUN_PARAMS: &[&str] = &[
    "action",
    "args",
    "arguments",
    "background",
    "cli",
    "focus",
    "interactive",
    "origin",
    "run_key",
    "runKey",
    "target",
    "wait",
    "wait_action",
    "caller",
    "deadline_ms",
    "timeout_ms",
];

/// Flags `run_action` and the global parser take for themselves, never
/// sent as an argument (`cli.rs` global flags; `run_action`'s own).
const CLI_FLAGS: &[&str] = &[
    "wait",
    "no-wait",
    "interactive",
    "focus",
    "target",
    "arg",
    "json",
    "jsonl",
    "quiet",
    "socket",
    "session",
    "timeout",
];

/// Flags a CLI scope takes for itself before the words reach the app: `chat
/// send`'s `--from`/`--as` (the sender label) and `--class` are read by
/// chief/chat_scope.rs, which rewrites the words without them.
const SCOPE_FLAGS: &[(&str, &[&str])] = &[("chat send", &["from", "as", "class"])];

struct Action {
    id: String,
    cli_name: String,
    args: BTreeSet<String>,
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn actions() -> Vec<Action> {
    let path = repo_root().join("plans/cmux-next/action-surfaces.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    let root: Value = serde_json::from_str(&text).expect("action-surfaces.json is JSON");
    let rows = root["actions"].as_array().expect("actions array");
    rows.iter()
        .map(|row| {
            let id = row["id"].as_str().expect("an action id").to_owned();
            let args = row["args"].as_array().unwrap_or_else(|| {
                panic!(
                    "{id} exports no args: action-surfaces.json predates the argument export; \
                     regenerate it (CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter ActionSurfaceParityTests)"
                )
            });
            Action {
                id,
                cli_name: row["cli_name"].as_str().unwrap_or_default().to_owned(),
                args: args.iter().filter_map(|arg| arg["name"].as_str().map(str::to_owned)).collect(),
            }
        })
        .collect()
}

/// The CLI's name for `--flag` (the same rule as `app::argument_name`).
fn wire_name(flag: &str) -> String {
    super::super::app::argument_name(flag)
}

fn is_canonical(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.all(|character| character.is_ascii_alphanumeric())
}

#[test]
fn every_exported_argument_is_named_in_camel_case() {
    let drifted = actions()
        .iter()
        .flat_map(|action| {
            action
                .args
                .iter()
                .filter(|name| !is_canonical(name))
                .map(|name| format!("{} {name}", action.id))
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    assert!(
        drifted.is_empty(),
        "these action arguments are not lowerCamelCase, so no CLI --flag reaches them: {drifted:?}"
    );
}

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Str(String),
    Ident(String),
    Punct(char),
}

/// Rust source as string literals, identifiers and punctuation, with each
/// token's line; comments, char literals and `#[cfg(test)]` items dropped.
fn tokens(source: &str) -> Vec<(Token, usize)> {
    let chars: Vec<char> = source.chars().collect();
    let mut out = Vec::new();
    let mut index = 0;
    let mut line = 1;
    while index < chars.len() {
        let character = chars[index];
        let next = chars.get(index + 1).copied();
        if character == '\n' {
            line += 1;
            index += 1;
        } else if character.is_whitespace() {
            index += 1;
        } else if character == '/' && next == Some('/') {
            while index < chars.len() && chars[index] != '\n' {
                index += 1;
            }
        } else if character == '/' && next == Some('*') {
            index += 2;
            while index + 1 < chars.len() && !(chars[index] == '*' && chars[index + 1] == '/') {
                if chars[index] == '\n' {
                    line += 1;
                }
                index += 1;
            }
            index += 2;
        } else if character == 'r' && (next == Some('"') || next == Some('#')) && {
            let mut probe = index + 1;
            while chars.get(probe) == Some(&'#') {
                probe += 1;
            }
            chars.get(probe) == Some(&'"')
        } {
            let start_line = line;
            let mut hashes = 0;
            index += 1;
            while chars[index] == '#' {
                hashes += 1;
                index += 1;
            }
            index += 1;
            let mut text = String::new();
            loop {
                if index >= chars.len() {
                    break;
                }
                if chars[index] == '"'
                    && (0..hashes).all(|offset| chars.get(index + 1 + offset) == Some(&'#'))
                {
                    index += 1 + hashes;
                    break;
                }
                if chars[index] == '\n' {
                    line += 1;
                }
                text.push(chars[index]);
                index += 1;
            }
            out.push((Token::Str(text), start_line));
        } else if character == '"' || (character == 'b' && next == Some('"')) {
            let start_line = line;
            index += if character == 'b' { 2 } else { 1 };
            let mut text = String::new();
            while index < chars.len() && chars[index] != '"' {
                if chars[index] == '\\' {
                    index += 1;
                }
                if chars.get(index) == Some(&'\n') {
                    line += 1;
                }
                if let Some(&escaped) = chars.get(index) {
                    text.push(escaped);
                }
                index += 1;
            }
            index += 1;
            out.push((Token::Str(text), start_line));
        } else if character == '\'' {
            // A char literal ('a', '\n', '\'') or a lifetime ('a).
            if next == Some('\\') {
                index += 2;
                while index < chars.len() && chars[index] != '\'' {
                    index += 1;
                }
                index += 1;
            } else if chars.get(index + 2) == Some(&'\'') {
                index += 3;
            } else {
                index += 1;
            }
        } else if character.is_alphanumeric() || character == '_' {
            let mut word = String::new();
            while index < chars.len() && (chars[index].is_alphanumeric() || chars[index] == '_') {
                word.push(chars[index]);
                index += 1;
            }
            out.push((Token::Ident(word), line));
        } else {
            out.push((Token::Punct(character), line));
            index += 1;
        }
    }
    drop_test_items(out)
}

/// Drops each `#[cfg(test)]` item (a test module or function): tests send
/// wrong names on purpose.
fn drop_test_items(tokens: Vec<(Token, usize)>) -> Vec<(Token, usize)> {
    let is = |index: usize, token: Token| tokens.get(index).map(|(t, _)| t) == Some(&token);
    let mut out = Vec::new();
    let mut index = 0;
    while index < tokens.len() {
        let cfg_test = is(index, Token::Punct('#'))
            && is(index + 1, Token::Punct('['))
            && is(index + 2, Token::Ident("cfg".into()))
            && is(index + 3, Token::Punct('('))
            && is(index + 4, Token::Ident("test".into()))
            && is(index + 5, Token::Punct(')'));
        if !cfg_test {
            out.push(tokens[index].clone());
            index += 1;
            continue;
        }
        // Skip to the item's body and past its matching brace (or its `;`).
        while index < tokens.len()
            && !matches!(tokens[index].0, Token::Punct('{') | Token::Punct(';'))
        {
            index += 1;
        }
        if is(index, Token::Punct('{')) {
            let mut depth = 0;
            while index < tokens.len() {
                match tokens[index].0 {
                    Token::Punct('{') => depth += 1,
                    Token::Punct('}') => {
                        depth -= 1;
                        if depth == 0 {
                            break;
                        }
                    }
                    _ => {}
                }
                index += 1;
            }
        }
        index += 1;
    }
    out
}

/// The flag a literal names, in any spelling `run_action` takes: `--name`, `--snake_name`,
/// `--camelName` or `--name=value` (only the part before `=`); None for anything else, a
/// `format!` template (`--{name}`) among them.
fn flag_name(text: &str) -> Option<&str> {
    let name = text.strip_prefix("--")?;
    let name = name.split_once('=').map_or(name, |(name, _)| name);
    let ok = name.chars().next().is_some_and(|first| first.is_ascii_lowercase())
        && name.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '-' || character == '_'
        });
    ok.then_some(name)
}

/// One hand-named argument the CLI sends that its action does not take.
#[derive(Debug)]
struct Drift {
    at: String,
    action: String,
    sent: String,
    valid: Vec<String>,
}

fn source_files() -> Vec<PathBuf> {
    let crates = repo_root().join("cmux-tui/crates");
    let mut files = Vec::new();
    let mut stack = vec![crates];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let name =
                path.file_name().and_then(|name| name.to_str()).unwrap_or_default().to_owned();
            if path.is_dir() {
                // Tests send wrong names on purpose; vendored and built trees are not the CLI's.
                if !matches!(
                    name.as_str(),
                    "tests" | "target" | "vendor" | "benches" | "examples" | "node_modules"
                ) {
                    stack.push(path);
                }
            } else if name.ends_with(".rs") && !name.contains("test") {
                files.push(path);
            }
        }
    }
    files.sort();
    files
}

/// The token after `index`'s `,` (and any `.to_owned()` before it): the next literal of a list.
fn skip_conversion_ref(tokens: &[(Token, usize)], index: usize) -> Option<&(Token, usize)> {
    let index = skip_conversion(tokens, index);
    if matches!(tokens.get(index), Some((Token::Punct(','), _))) {
        tokens.get(index + 1)
    } else {
        None
    }
}

/// Past a `.to_owned()`, `.into()` or `.to_string()` at `index`.
fn skip_conversion(tokens: &[(Token, usize)], mut index: usize) -> usize {
    while matches!(tokens.get(index), Some((Token::Punct('.'), _)))
        && matches!(tokens.get(index + 1), Some((Token::Ident(method), _)) if method == "to_owned" || method == "into" || method == "to_string")
    {
        index += 4;
    }
    index
}

/// The longest run of CLI words (consecutive string literals) starting at
/// `index` that names an action, and how many literals it took.
fn cli_name_at(
    tokens: &[(Token, usize)],
    index: usize,
    by_cli: &BTreeMap<String, usize>,
) -> Option<(usize, usize)> {
    // A call's words start its list (`["cloud", "relay-chat", ..]`); words in the middle of one
    // (`["screen", SCREEN, "layout", "undo"]`) are some other command's.
    if index > 0 && !matches!(tokens.get(index - 1), Some((Token::Punct('[' | '('), _))) {
        return None;
    }
    let mut words = Vec::new();
    let mut probe = index;
    while words.len() < 4 {
        let Some((Token::Str(word), _)) = tokens.get(probe) else { break };
        words.push(word.clone());
        probe += 1;
        // `"cloud", "relay-chat"` or `"cloud".to_owned(), "relay-chat".to_owned()`: the literals of one list.
        probe = skip_conversion(tokens, probe);
        if !matches!(tokens.get(probe), Some((Token::Punct(','), _))) {
            break;
        }
        probe += 1;
    }
    for take in (1..=words.len()).rev() {
        let name = words[..take].join(" ");
        // One bare word (`"open"`) is too common to be a call; a CLI name of one literal has a space in it.
        if take == 1 && !name.contains(' ') {
            continue;
        }
        if let Some(&action) = by_cli.get(&name) {
            return Some((action, take));
        }
    }
    None
}

fn drift_in(path: &Path, actions: &[Action], reaches_app: &dyn Fn(&str) -> bool) -> Vec<Drift> {
    let by_cli: BTreeMap<String, usize> = actions
        .iter()
        .enumerate()
        .filter(|(_, action)| !action.cli_name.is_empty() && reaches_app(&action.cli_name))
        .map(|(index, action)| (action.cli_name.clone(), index))
        .collect();
    let by_id: BTreeMap<&str, usize> =
        actions.iter().enumerate().map(|(index, action)| (action.id.as_str(), index)).collect();
    let find = |name: &str| by_id.get(name).copied().or_else(|| by_cli.get(name).copied());
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let tokens = tokens(&text);
    let relative = path.strip_prefix(repo_root()).unwrap_or(path).display().to_string();
    let mut drift = Vec::new();
    // The action the words since the last `fn` name, and whether its keys are checked too.
    let mut current: Option<(usize, bool)> = None;
    let report = |line: usize, action: usize, sent: String, drift: &mut Vec<Drift>| {
        let action = &actions[action];
        if !action.args.contains(&sent) {
            drift.push(Drift {
                at: format!("{relative}:{line}"),
                action: action.id.clone(),
                sent,
                valid: action.args.iter().cloned().collect(),
            });
        }
    };
    let mut index = 0;
    while index < tokens.len() {
        let (token, line) = &tokens[index];
        match token {
            // A new function or match arm is another call.
            Token::Ident(word) if word == "fn" => current = None,
            Token::Punct('=') if matches!(tokens.get(index + 1), Some((Token::Punct('>'), _))) => {
                current = None;
            }
            Token::Ident(word) if word == "action_run_params" => {
                if let (Some((Token::Punct('('), _)), Some((Token::Str(name), _))) =
                    (tokens.get(index + 1), tokens.get(index + 2))
                {
                    current = find(name).map(|action| (action, true));
                }
            }
            Token::Ident(word) if word == "insert" => {
                if let (
                    Some((action, true)),
                    Some((Token::Punct('('), _)),
                    Some((Token::Str(key), line)),
                ) = (current, tokens.get(index + 1), tokens.get(index + 2))
                    && !RUN_PARAMS.contains(&key.as_str())
                {
                    report(*line, action, key.clone(), &mut drift);
                }
            }
            Token::Str(key) if key == "action" => {
                if let (Some((Token::Punct(':'), _)), Some((Token::Str(name), _))) =
                    (tokens.get(index + 1), tokens.get(index + 2))
                    && let Some(action) = find(name)
                {
                    current = Some((action, true));
                }
            }
            Token::Str(key) if key == "args" => {
                // `"args": {"key": ..}` or `"args": json!({"key": ..})`: the object's own keys.
                let mut probe = skip_conversion(&tokens, index + 1);
                if matches!(tokens.get(probe), Some((Token::Punct(':' | ','), _))) {
                    probe += 1;
                    if matches!(tokens.get(probe), Some((Token::Ident(word), _)) if word == "json")
                    {
                        probe += 3;
                    }
                    if let (Some((action, true)), Some((Token::Punct('{'), _))) =
                        (current, tokens.get(probe))
                    {
                        let mut depth = 0;
                        while probe < tokens.len() {
                            match &tokens[probe].0 {
                                Token::Punct('{' | '[' | '(') => depth += 1,
                                Token::Punct('}' | ']' | ')') => {
                                    depth -= 1;
                                    if depth == 0 {
                                        break;
                                    }
                                }
                                Token::Str(key)
                                    if depth == 1
                                        && matches!(
                                            tokens.get(probe + 1),
                                            Some((Token::Punct(':'), _))
                                        ) =>
                                {
                                    report(tokens[probe].1, action, key.clone(), &mut drift);
                                }
                                _ => {}
                            }
                            probe += 1;
                        }
                    }
                }
            }
            // `"--arg", "key=value"`: the key is sent as written.
            Token::Str(text) if text == "--arg" => {
                if let (Some((action, _)), Some((Token::Str(pair), line))) =
                    (current, skip_conversion_ref(&tokens, index + 1))
                    && let Some((key, _)) = pair.split_once('=')
                    && !key.contains('{')
                {
                    report(*line, action, key.to_owned(), &mut drift);
                }
            }
            Token::Str(text) if flag_name(text).is_some() => {
                if let (Some((action, _)), Some(flag)) = (current, flag_name(text)) {
                    let scope_flag = SCOPE_FLAGS.iter().any(|(name, flags)| {
                        *name == actions[action].cli_name && flags.contains(&flag)
                    });
                    if !CLI_FLAGS.contains(&flag) && !scope_flag {
                        report(*line, action, wire_name(flag), &mut drift);
                    }
                }
            }
            Token::Str(_) => {
                if let Some((action, taken)) = cli_name_at(&tokens, index, &by_cli) {
                    current = Some((action, false));
                    index += taken;
                    continue;
                }
            }
            _ => {}
        }
        index += 1;
    }
    drift
}

/// Whether CLI words reach the app action of that CLI name as its own
/// arguments: the CLI's own grammars (the mux grammar, the agents grammar)
/// run first and map their flags themselves (`run_app_action_fallback`), so
/// words one of them takes are not this contract's.
fn reaches_app(cli_name: &str) -> bool {
    let words = cli_name.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    if matches!(super::super::app::parse(&words), Ok(Some(_))) {
        return true;
    }
    super::super::parse(&words, super::super::Surface::Cmux).is_err()
        && super::super::agents::command(&words).is_err()
}

/// Every hand-named argument a CLI call site sends is one its action takes,
/// under its canonical name.
#[test]
fn every_cli_call_site_sends_only_arguments_its_action_takes() {
    let actions = actions();
    let mut drift = Vec::new();
    for file in source_files() {
        drift.extend(drift_in(&file, &actions, &reaches_app));
    }
    let lines = drift
        .iter()
        .map(|drift| {
            format!(
                "{}: {} has no argument '{}' (it takes {:?})",
                drift.at, drift.action, drift.sent, drift.valid
            )
        })
        .collect::<Vec<_>>();
    assert!(
        lines.is_empty(),
        "CLI call sites name app action arguments the app does not take (plans/cmux-next/action-surfaces.json):\n{}",
        lines.join("\n")
    );
}

/// The scanner sees the call that broke `cmux cloud start-chat`, in each of
/// the shapes the CLI writes a call in.
#[test]
fn the_scanner_finds_a_drifted_argument_in_every_call_shape() {
    let actions = vec![Action {
        id: "cloudRelayChat".into(),
        cli_name: "cloud relay-chat".into(),
        args: ["agent", "prompt", "cwd", "promptId"].into_iter().map(str::to_owned).collect(),
    }];
    let dir = std::env::temp_dir().join(format!("cmux-contract-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("call.rs");
    std::fs::write(
        &file,
        r#"
        fn words_call(runner: &mut dyn Runner) {
            let mut args = words(&["cloud", "relay-chat", "--target"]);
            args.extend(["--agent".to_owned(), agent]);
            args.extend(["--prompt-ident".to_owned(), id]); // drift 1
            args.push("--json".to_owned());
            args.push("--prompt_ident=x".to_owned()); // drift 4
            args.extend(["--arg".to_owned(), "prompt-id=x".to_owned()]); // drift 5
            args.extend(["--prompt_id".to_owned(), "--cwd=/x".to_owned(), format!("--{name}={value}")]);
        }
        fn params_call() {
            let mut params = action_run_params("cloudRelayChat", ActionName::Any, "script");
            arguments.insert("prompt_id".into(), json!(id)); // drift 2
            params.insert("args".into(), json!({ "prompt": p, "promptID": id })); // drift 3
        }
        fn unrelated() {
            let flags = ["--prompt-ident"];
        }
        #[cfg(test)]
        mod tests {
            fn wrong_on_purpose() { let _ = ["cloud", "relay-chat", "--nope"]; }
        }
        "#,
    )
    .unwrap();
    let found = drift_in(&file, &actions, &|_| true)
        .into_iter()
        .map(|drift| drift.sent)
        .collect::<Vec<_>>();
    std::fs::remove_dir_all(&dir).ok();
    assert_eq!(found, ["promptIdent", "promptIdent", "prompt-id", "prompt_id", "promptID"]);
}

/// `promptId` as the CLI's flag: `--prompt-id`.
fn kebab(name: &str) -> String {
    let mut flag = String::with_capacity(name.len() + 4);
    for character in name.chars() {
        if character.is_ascii_uppercase() {
            flag.push('-');
            flag.push(character.to_ascii_lowercase());
        } else {
            flag.push(character);
        }
    }
    flag
}

/// The `action.run` params the CLI's own encoder (`app::run_action`, `app::parse`) builds from `words`,
/// without `origin` (a terminal's `cli`, a script's `script`).
fn encoded(words: &[String]) -> Value {
    let words = words.iter().filter(|word| *word != "--json").cloned().collect::<Vec<_>>();
    let command = super::super::app::parse(&words)
        .ok()
        .flatten()
        .filter(|command| {
            matches!(command, super::super::app::AppCommand::Call { method: "action.run", .. })
        })
        .or_else(|| {
            // The app fallback: the leading words are the CLI name, the rest its flags.
            let split = words.iter().take_while(|word| !word.starts_with('-')).count();
            super::super::app::run_action(
                &words[..split].join(" "),
                &words[split..],
                super::super::app::ActionName::Cli,
            )
            .ok()
        });
    let Some(super::super::app::AppCommand::Call { method: "action.run", mut params, .. }) =
        command
    else {
        panic!("the CLI builds no action.run for {words:?}")
    };
    params.as_object_mut().expect("params object").remove("origin");
    params
}

/// The requests the CLI's encoder builds, which the app's `ArgumentActionContractTests` validate against
/// its catalog: `cmux cloud start-chat`'s relay request as `cloud_start_chat` builds it, and, for each
/// action the CLI offers, its CLI name with every argument given as its `--flag`.
fn cli_requests() -> Value {
    let path = repo_root().join("plans/cmux-next/action-surfaces.json");
    let root: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).expect("action-surfaces.json"))
            .unwrap();
    let mut requests = Vec::new();
    let relay = super::super::cloud_start_chat::tests::contract_relay_words();
    requests.push(
        serde_json::json!({"source": "cmux cloud start-chat (relay)", "params": encoded(&relay)}),
    );
    for action in root["actions"].as_array().expect("actions") {
        let Some(cli_name) = action["cli_name"].as_str().filter(|_| action["cli"] == "offered")
        else {
            continue;
        };
        let args = action["args"].as_array().cloned().unwrap_or_default();
        if args.is_empty() {
            continue;
        }
        let mut words = cli_name.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
        // `cmux` takes these words as its own grammar first, never as this action's flags.
        if !reaches_app(cli_name) {
            continue;
        }
        for arg in &args {
            let name = arg["name"].as_str().expect("an argument name");
            let value = match arg["kind"].as_str() {
                Some("bool") => None,
                Some("int") => Some(arg["min"].as_i64().unwrap_or(1).to_string()),
                Some("enum") => arg["values"][0].as_str().map(str::to_owned),
                Some("target") => {
                    Some(format!("{}:contract-1", arg["target_kind"].as_str().unwrap_or("tab")))
                }
                _ => Some("/tmp/contract".to_owned()),
            };
            let flag = kebab(name);
            // A name `run_action` takes for itself (`--target`, `--focus`) goes as `--arg name=value`.
            if CLI_FLAGS.contains(&flag.as_str()) {
                words.extend([
                    "--arg".to_owned(),
                    format!("{name}={}", value.as_deref().unwrap_or("true")),
                ]);
                continue;
            }
            words.push(format!("--{flag}"));
            words.extend(value);
        }
        requests.push(serde_json::json!({"source": format!("cmux {}", words.join(" ")), "params": encoded(&words)}));
    }
    serde_json::json!({
        "about": "action.run requests as the cmux CLI's own encoder builds them (cmux-tui cli/tests/action_argument_contract.rs \
                  writes this; CMUX_UPDATE_CLI_ACTION_REQUESTS=1 cargo test -p cmux-tui --lib action_argument_contract \
                  rewrites it). The app's ArgumentActionContractTests validate each against its catalog.",
        "requests": requests,
    })
}

/// The checked-in requests are the ones the CLI builds now; CMUX_UPDATE_CLI_ACTION_REQUESTS=1 rewrites them.
#[test]
fn the_cli_request_fixture_is_what_the_cli_encodes() {
    let path = repo_root().join("cmux-tui/spec/fixtures/cli-action-requests.json");
    let want = serde_json::to_string_pretty(&cli_requests()).unwrap() + "\n";
    if std::env::var("CMUX_UPDATE_CLI_ACTION_REQUESTS").as_deref() == Ok("1") {
        std::fs::write(&path, &want).unwrap();
        return;
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        have == want,
        "{} is stale: CMUX_UPDATE_CLI_ACTION_REQUESTS=1 cargo test -p cmux-tui --lib action_argument_contract",
        path.display()
    );
}

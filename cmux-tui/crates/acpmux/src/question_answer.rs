//! A person's answer to an agent question (`toolCall._meta.acpmux.question`,
//! hub/questions.rs), encoded in the asking harness's shape. Shared by
//! `acpmux answer` and the TUI answer flow, so both send what the hub's
//! `check_answers` accepts: Claude Code and the Chief by exact prompt text
//! with one string (`"label1, label2"` or the Other text), Codex by item id
//! with `{answers: [labels..., other]}`.

use serde_json::{Map, Value, json};

/// The normalized question of a permission request, when it carries one.
pub fn question(request: &Value) -> Option<&Value> {
    request.pointer("/toolCall/_meta/acpmux/question").filter(|q| q["items"].is_array())
}

/// The question's items.
pub fn items(question: &Value) -> &[Value] {
    question["items"].as_array().map(Vec::as_slice).unwrap_or(&[])
}

/// What a person chose for one item: option indexes in the item's order,
/// and the Other text.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Choice {
    pub options: Vec<usize>,
    pub other: Option<String>,
}

fn str_of<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}

fn options(item: &Value) -> &[Value] {
    item["options"].as_array().map(Vec::as_slice).unwrap_or(&[])
}

/// One line that names an item: its header, else its prompt.
pub fn item_name(item: &Value) -> String {
    let header = str_of(item, "header");
    if header.is_empty() { str_of(item, "prompt").trim().to_owned() } else { header.to_owned() }
}

/// Checks a choice against its item: something is chosen, every option
/// exists, Other text only where the item allows it, and a single select
/// holds exactly one choice.
pub fn check_choice(item: &Value, choice: &Choice) -> Result<(), String> {
    let name = item_name(item);
    let count = choice.options.len() + usize::from(choice.other.is_some());
    if count == 0 {
        return Err(format!("{name:?} needs an answer"));
    }
    if choice.options.iter().any(|&i| i >= options(item).len()) {
        return Err(format!("{name:?} has no such option"));
    }
    if choice.other.is_some() && !item["allowsOther"].as_bool().unwrap_or(false) {
        return Err(format!("{name:?} takes only its options: {}", option_list(item)));
    }
    if count > 1 && !item["multiSelect"].as_bool().unwrap_or(false) {
        return Err(format!("{name:?} takes one choice, got {count}"));
    }
    Ok(())
}

fn option_list(item: &Value) -> String {
    options(item).iter().map(|o| str_of(o, "label")).collect::<Vec<_>>().join(", ")
}

/// The option `text` names: by id or label, exact first, then ignoring case.
fn find_option(item: &Value, text: &str) -> Option<usize> {
    let opts = options(item);
    let exact = opts.iter().position(|o| str_of(o, "id") == text || str_of(o, "label") == text);
    exact.or_else(|| {
        opts.iter().position(|o| {
            str_of(o, "id").eq_ignore_ascii_case(text)
                || str_of(o, "label").eq_ignore_ascii_case(text)
        })
    })
}

/// Parses `value` for `item`: the whole value or comma-separated parts, each
/// an option label or id; what is not an option becomes the Other text
/// (rejoined with ", ") when the item allows Other. An item with no options
/// takes the whole value as its text, never split.
pub fn parse_choice(item: &Value, value: &str) -> Result<Choice, String> {
    let value = value.trim();
    let mut choice = Choice::default();
    if options(item).is_empty() {
        choice.other = Some(value).filter(|v| !v.is_empty()).map(str::to_owned);
    } else if let Some(i) = find_option(item, value) {
        choice.options.push(i);
    } else {
        let mut other = vec![];
        for part in value.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            match find_option(item, part) {
                Some(i) if !choice.options.contains(&i) => choice.options.push(i),
                Some(_) => {}
                None => other.push(part),
            }
        }
        choice.options.sort_unstable();
        if !other.is_empty() {
            if !item["allowsOther"].as_bool().unwrap_or(false) {
                return Err(format!(
                    "{:?} is not an option of {:?}; choose from: {}",
                    other.join(", "),
                    item_name(item),
                    option_list(item)
                ));
            }
            choice.other = Some(other.join(", "));
        }
    }
    check_choice(item, &choice)?;
    Ok(choice)
}

/// The item `key` names: its id, exact prompt or header, then the same
/// ignoring case and surrounding spaces when exactly one item matches.
pub fn find_item(question: &Value, key: &str) -> Result<usize, String> {
    let items = items(question);
    fn fields(item: &Value) -> [&str; 3] {
        [str_of(item, "id"), str_of(item, "prompt"), str_of(item, "header")]
    }
    if let Some(i) = items.iter().position(|item| fields(item).contains(&key)) {
        return Ok(i);
    }
    let key = key.trim();
    let loose: Vec<usize> = (0..items.len())
        .filter(|&i| {
            fields(&items[i]).iter().any(|f| !f.is_empty() && f.trim().eq_ignore_ascii_case(key))
        })
        .collect();
    match loose.as_slice() {
        [i] => Ok(*i),
        [] => Err(format!(
            "no question matches {key:?}; the questions are: {}",
            items
                .iter()
                .map(|item| format!("{} ({:?})", str_of(item, "id"), str_of(item, "prompt")))
                .collect::<Vec<_>>()
                .join(", ")
        )),
        _ => Err(format!("{key:?} matches several questions; use the question id")),
    }
}

/// The harness-shaped `answers` for one choice per item, in item order.
pub fn encode(question: &Value, choices: &[Choice]) -> Value {
    let codex = question["harness"] == "codex";
    let mut answers = Map::new();
    for (item, choice) in items(question).iter().zip(choices) {
        let mut picked: Vec<String> = choice
            .options
            .iter()
            .filter_map(|&i| options(item).get(i))
            .map(|o| str_of(o, "label").to_owned())
            .collect();
        picked.extend(choice.other.clone());
        if codex {
            answers.insert(str_of(item, "id").to_owned(), json!({"answers": picked}));
        } else {
            answers.insert(str_of(item, "prompt").to_owned(), json!(picked.join(", ")));
        }
    }
    Value::Object(answers)
}

/// Parses `acpmux answer --answer KEY=VALUE` arguments into the harness-shaped
/// `answers`. Every item must be answered exactly once. A key may itself hold
/// '=' (a prompt like "a=b?"): the first split whose key names an item wins.
pub fn parse_answers(question: &Value, args: &[String]) -> Result<Value, String> {
    let items = items(question);
    let mut choices: Vec<Option<Choice>> = vec![None; items.len()];
    for arg in args {
        let splits: Vec<usize> = arg.match_indices('=').map(|(i, _)| i).collect();
        if splits.is_empty() {
            return Err(format!("--answer {arg:?} needs the form \"<question or id>=<choice>\""));
        }
        // A value error outranks a key error: the key named a question.
        let (mut key_error, mut value_error, mut found) = (None, None, None);
        for &at in &splits {
            match find_item(question, &arg[..at]) {
                Ok(index) => match parse_choice(&items[index], &arg[at + 1..]) {
                    Ok(choice) => {
                        found = Some((index, choice));
                        break;
                    }
                    Err(e) => {
                        value_error.get_or_insert(e);
                    }
                },
                Err(e) => {
                    key_error.get_or_insert(e);
                }
            }
        }
        let Some((index, choice)) = found else {
            return Err(value_error.or(key_error).unwrap_or_default());
        };
        if choices[index].is_some() {
            return Err(format!("{:?} is answered twice", item_name(&items[index])));
        }
        choices[index] = Some(choice);
    }
    let missing: Vec<String> = items
        .iter()
        .zip(&choices)
        .filter(|(_, c)| c.is_none())
        .map(|(item, _)| format!("{} ({:?})", str_of(item, "id"), str_of(item, "prompt")))
        .collect();
    if !missing.is_empty() {
        return Err(format!("answer every question; missing: {}", missing.join(", ")));
    }
    Ok(encode(question, &choices.into_iter().flatten().collect::<Vec<_>>()))
}

/// The questions with numbered options and the exact command that answers
/// them, for `acpmux answer <session>` with no --answer.
pub fn usage(question: &Value, session: &str) -> String {
    let items = items(question);
    let agent = question["agent"].as_str().unwrap_or("The agent");
    let mut out = format!(
        "{agent} asks {} question{}:\n",
        items.len(),
        if items.len() == 1 { "" } else { "s" }
    );
    for item in items {
        let header = str_of(item, "header");
        let header = if header.is_empty() { String::new() } else { format!("[{header}] ") };
        out.push_str(&format!("\n{}  {header}{}\n", str_of(item, "id"), str_of(item, "prompt")));
        for (i, o) in options(item).iter().enumerate() {
            let detail = str_of(o, "detail");
            let detail = if detail.is_empty() { String::new() } else { format!("  ({detail})") };
            out.push_str(&format!("    {}. {}{detail}\n", i + 1, str_of(o, "label")));
        }
        let multi = item["multiSelect"].as_bool().unwrap_or(false);
        let other = item["allowsOther"].as_bool().unwrap_or(false);
        let note = match (multi, other) {
            (true, true) => "one or more, comma-separated, or your own text",
            (true, false) => "one or more, comma-separated",
            (false, true) => "one choice, or your own text",
            (false, false) => "one choice",
        };
        out.push_str(&format!("    ({note})\n"));
    }
    let flags: Vec<String> =
        items.iter().map(|item| format!("--answer \"{}=<choice>\"", str_of(item, "id"))).collect();
    out.push_str(&format!("\nanswer: acpmux answer {session} {}\n", flags.join(" ")));
    out.push_str(&format!("decline: acpmux deny {session}\n"));
    out
}

/// What `acpmux pending` and a streaming turn print as the way to answer a
/// pending request. The CLI is never the person (`hub/person.rs`): the
/// daemon refuses it an allow and a question's answer, so those are named
/// in the app, and deny and cancel, which it may run, as commands.
pub fn pending_hint(request: &Value, session: &str) -> String {
    let deny = format!("acpmux session deny {session} | acpmux session cancel {session}");
    if question(request).is_some() {
        return format!("answer it in the cmux app (the chat's question card) | {deny}");
    }
    format!("allow it in the cmux app (the chat's permission card) | {deny}")
}

/// The note `acpmux new` and `send` print before a session works: its
/// policy asks before some tools run, and only the cmux app can allow
/// those (the CLI may deny or cancel). None when its policy never asks
/// (approve-all) or denies by itself (deny-all), or is not known.
pub fn app_allow_note(info: &Value, session: &str) -> Option<String> {
    use crate::config::PermissionPolicy;
    // A session's own policy, else the daemon default it runs under.
    let policy = info.get("policy").and_then(Value::as_str);
    let policy = policy.or_else(|| info.pointer("/enforcement/policy").and_then(Value::as_str));
    let policy: PermissionPolicy = policy?.parse().ok()?;
    if matches!(policy, PermissionPolicy::ApproveAll | PermissionPolicy::DenyAll) {
        return None;
    }
    Some(format!(
        "note: {session} asks before some tools run (policy {policy}); only the cmux app can allow that (the chat's permission card). From here, `acpmux session deny {session}` or `acpmux session cancel {session}`."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A free-text item (no options, own text allowed: an elicitation's
    /// string field) takes the whole value as typed, commas and spacing
    /// included; it is never split into parts and rejoined.
    #[test]
    fn a_free_text_answer_is_kept_whole() {
        let question = json!({"harness": "claude", "items": [
            {"id": "q1", "prompt": "Name?", "options": [], "allowsOther": true}]});
        for typed in ["a,  b", "x, x", "a,,b", "1,000"] {
            let answers = parse_answers(&question, &[format!("q1={typed}")]).expect(typed);
            assert_eq!(answers, json!({"Name?": typed}), "{typed:?}");
        }
    }

    /// An item with options still reads comma-separated labels, and unknown
    /// parts become its Other text.
    #[test]
    fn an_item_with_options_still_splits_on_commas() {
        let question = json!({"harness": "claude", "items": [
            {"id": "q1", "prompt": "Pick?", "multiSelect": true, "allowsOther": true,
             "options": [{"label": "Red"}, {"label": "Blue"}]}]});
        let answers = parse_answers(&question, &["q1=blue, red, teal".into()]).unwrap();
        assert_eq!(answers, json!({"Pick?": "Red, Blue, teal"}));
    }

    /// The CLI is never the person (`hub/person.rs`): the daemon refuses its
    /// allow and its answer. The way to answer a pending ask it prints (the
    /// send reply, `acpmux pending`) names the app for those, and only the
    /// commands the CLI may run (ergo-walk, 2026-10-25).
    #[test]
    fn the_pending_hint_offers_only_what_the_cli_may_run() {
        let permission = json!({"toolCall": {"title": "Read README.md"}, "options": [
            {"optionId": "accept", "kind": "allow_once"},
            {"optionId": "cancel", "kind": "reject_once"}]});
        let hint = pending_hint(&permission, "my-linux/api-work");
        assert!(!hint.contains("session allow"), "{hint}");
        assert!(hint.contains("allow it in the cmux app (the chat's permission card)"), "{hint}");
        assert!(hint.contains("acpmux session deny my-linux/api-work"), "{hint}");
        assert!(hint.contains("acpmux session cancel my-linux/api-work"), "{hint}");

        let question = json!({"toolCall": {"_meta": {"acpmux": {"question": {"items": [
            {"id": "q1", "prompt": "Pick?", "options": [{"label": "Red"}]}]}}}},
            "options": [{"optionId": "allow", "kind": "allow_once"}]});
        let hint = pending_hint(&question, "s");
        assert!(!hint.contains("session answer"), "{hint}");
        assert!(hint.contains("answer it in the cmux app (the chat's question card)"), "{hint}");
        assert!(hint.contains("acpmux session deny s"), "{hint}");
        assert!(hint.contains("acpmux session cancel s"), "{hint}");
    }

    /// `new` and `send` say before the work starts that an allow needs the
    /// app, only for a policy that asks.
    #[test]
    fn the_app_allow_note_is_only_for_a_policy_that_asks() {
        for policy in ["ask", "approve-reads", "approve-edits"] {
            let note = app_allow_note(&json!({"policy": policy}), "api-work").expect(policy);
            assert!(note.contains("only the cmux app can allow"), "{note}");
            assert!(note.contains("`acpmux session deny api-work`"), "{note}");
            assert!(!note.contains("session allow"), "{note}");
        }
        // A session on the daemon default has no policy of its own: the
        // default it runs under counts (`enforcement.policy`).
        let default = json!({"policy": null, "enforcement": {"policy": "ask"}});
        assert!(app_allow_note(&default, "api-work").is_some());
        let own = json!({"policy": "approve-all", "enforcement": {"policy": "approve-all"}});
        assert_eq!(app_allow_note(&own, "api-work"), None);
        for info in [json!({"policy": "approve-all"}), json!({"policy": "deny-all"}), json!({})] {
            assert_eq!(app_allow_note(&info, "api-work"), None, "{info}");
        }
    }
}

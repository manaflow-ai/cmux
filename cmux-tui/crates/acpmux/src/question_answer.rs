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
/// (rejoined with ", ") when the item allows Other.
pub fn parse_choice(item: &Value, value: &str) -> Result<Choice, String> {
    let value = value.trim();
    let mut choice = Choice::default();
    if let Some(i) = find_option(item, value) {
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
/// pending request: the `answer` command for a question (an allow would be
/// refused), else allow with the offered option ids, and deny for both.
pub fn pending_hint(request: &Value, session: &str) -> String {
    if let Some(first) = question(request).and_then(|q| items(q).first()) {
        return format!(
            "acpmux session answer {session} --answer \"{}=<choice>\" | acpmux session deny {session}",
            item_name(first)
        );
    }
    let ids: Vec<&str> = request["options"]
        .as_array()
        .map(|a| a.iter().filter_map(|o| o["optionId"].as_str()).collect())
        .unwrap_or_default();
    format!("acpmux session allow {session} [{}] | acpmux session deny {session}", ids.join("|"))
}

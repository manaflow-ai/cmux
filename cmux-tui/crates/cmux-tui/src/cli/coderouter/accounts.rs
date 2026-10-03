//! Account selection and account text for `cmux coderouter`. Accounts are
//! named by their opaque `acct_…` handle; an email is never a selector and
//! never printed (plans/cmux-next/coderouter.md).

use serde_json::{Value, json};

use super::messages::messages;

/// A selector that names no account, or several.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SelectorError {
    pub(crate) message: String,
    /// `acct_…  kind  label` for each account a label matched.
    pub(crate) candidates: Vec<String>,
}

impl SelectorError {
    pub(crate) fn error_value(&self) -> Value {
        json!({
            "code": "usage.invalid",
            "message": self.message,
            "details": {"candidates": self.candidates},
            "retryable": false,
        })
    }
}

/// True when a selector holds an email, written plainly or encoded. Accounts
/// are never selected by email: the app no longer returns them.
pub(crate) fn looks_like_email(selector: &str) -> bool {
    let lower = selector.to_lowercase();
    ['@', '\u{FF20}', '\u{FE6B}'].iter().any(|at| lower.contains(*at))
        || lower.contains("%40")
        || lower.contains("%2540")
}

/// The server `id` of the account a selector names. Match order: the
/// `account` handle (`acct_…`, exact), the server `id`, the masked
/// `identifier`, then a `label` that exactly one account has.
pub(crate) fn account_id(selector: &str, accounts: &Value) -> Result<String, SelectorError> {
    let catalog = &crate::localization::catalog().coderouter;
    let error = |message: String| SelectorError { message, candidates: Vec::new() };
    if looks_like_email(selector) {
        return Err(error(messages().account_email_selector.to_owned()));
    }
    let accounts = accounts.as_array().map(Vec::as_slice).unwrap_or_default();
    let field =
        |account: &Value, key: &str| account.get(key).and_then(Value::as_str).map(str::to_owned);
    let id_of = |account: &Value| field(account, "id");
    let tiers: [(&str, bool); 4] =
        [("account", true), ("id", false), ("identifier", false), ("label", false)];
    for (key, exact) in tiers {
        let needle = if exact { selector.to_owned() } else { selector.to_lowercase() };
        let matches = accounts
            .iter()
            .filter(|account| {
                field(account, key).is_some_and(|value| {
                    if exact { value == needle } else { value.to_lowercase() == needle }
                })
            })
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [] => continue,
            [account] => {
                return id_of(account).ok_or_else(|| {
                    error(catalog.account_not_found.replace("{account}", selector))
                });
            }
            many => {
                return Err(SelectorError {
                    message: catalog
                        .account_ambiguous
                        .replace("{account}", selector)
                        .replace("{count}", &many.len().to_string()),
                    candidates: many.iter().map(|account| account_line(account, false)).collect(),
                });
            }
        }
    }
    Err(error(catalog.account_not_found.replace("{account}", selector)))
}

/// One account as text: `acct_…  kind  identifier  (label)  state`, or
/// `acct_…  kind  label` for an ambiguity candidate. Never `server_account`.
pub(crate) fn account_line(account: &Value, full: bool) -> String {
    let text = |key: &str| account.get(key).and_then(Value::as_str).unwrap_or("-").to_owned();
    let handle = text("account");
    let kind = text("kind");
    let label = text("label");
    if full {
        format!("{handle}  {kind}  {}  ({label})  {}", text("identifier"), text("state"))
    } else {
        format!("{handle}  {kind}  {label}")
    }
}

/// The text form of a Claude account list, one account per line.
pub(crate) fn account_lines(accounts: Option<&Value>) -> Value {
    let lines: Vec<String> = accounts
        .and_then(Value::as_array)
        .map(|accounts| accounts.iter().map(|account| account_line(account, true)).collect())
        .unwrap_or_default();
    if lines.is_empty() {
        return json!(messages().no_accounts);
    }
    json!(lines.join("\n"))
}

/// Replace each email in an error text with `<email>`: a request path or a
/// selector in a server message may hold one.
pub(crate) fn redact_emails(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut word = String::new();
    let flush = |word: &mut String, output: &mut String| {
        if looks_like_email(word) {
            output.push_str("<email>");
        } else {
            output.push_str(word);
        }
        word.clear();
    };
    for c in text.chars() {
        if c.is_whitespace() || "/?&=\"'<>()[],;:".contains(c) {
            flush(&mut word, &mut output);
            output.push(c);
        } else {
            word.push(c);
        }
    }
    flush(&mut word, &mut output);
    output
}

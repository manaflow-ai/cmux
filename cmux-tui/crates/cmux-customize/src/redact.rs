//! Credentials stay where they are: a diff shows `[redacted]` in their
//! place and a profile leaves them out.
//!
//! The settings file is the one place a person keeps cmux's secrets (a
//! token in an action's command, a page URL with a password in it), and a
//! generation is a whole copy of it. So nothing reads a generation back out
//! as text except through here.
//!
//! Three things count as a credential, the same three the settings MCP
//! tools refuse to return: the value of a member named like one
//! (`token`, `password`, `apiKey`, ...), a token by its well-known prefix
//! or a private key block, and the user and password in a URL. A value a
//! setting's own row marks as the person's alone goes too when the reader
//! is an agent.

use cmux_config::schema::Kind;
use cmux_config::{Schema, jsonc};
use serde_json::{Value, json};

/// What stands where a credential was.
pub const MARK: &str = "[redacted]";

/// Who reads the text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reader {
    /// The person, at their own terminal: credentials are hidden.
    Person,
    /// An agent over MCP: the settings only the person may change are
    /// hidden too, as the settings tools hide them.
    Agent,
}

/// A member name whose value is a credential.
pub fn credential_key(key: &str) -> bool {
    const NAMES: &[&str] = &[
        "password",
        "passwd",
        "passphrase",
        "token",
        "apikey",
        "authorization",
        "secret",
        "privatekey",
        "credential",
        "credentials",
    ];
    let plain: String =
        key.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_lowercase()).collect();
    NAMES.iter().any(|name| plain.ends_with(name))
}

/// A URL that carries a user, a password, a query or a fragment: any of
/// them can hold a bearer token under any name. `bare` reads a text with
/// no scheme as a URL too (a URL setting takes `example.com/page`).
pub fn sensitive_url(text: &str, bare: bool) -> bool {
    let text = text.trim();
    let after = match text.split_once("://") {
        Some((scheme, after))
            if !scheme.is_empty()
                && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c)) =>
        {
            after
        }
        _ if bare && !text.is_empty() && !text.contains(char::is_whitespace) => text,
        _ => return false,
    };
    let (authority, rest) = match after.find(['/', '?', '#']) {
        Some(end) => after.split_at_checked(end).unwrap_or((after, "")),
        None => (after, ""),
    };
    authority.contains('@') || rest.contains('?') || rest.contains('#')
}

/// A settings value that must not leave: a URL as above, or anything with a
/// member named like a credential.
pub fn sensitive_value(value: &Value, url_setting: bool) -> bool {
    match value {
        Value::String(text) => sensitive_url(text, url_setting) || !tokens(text).is_empty(),
        Value::Array(values) => values.iter().any(|value| sensitive_value(value, false)),
        Value::Object(members) => {
            members.iter().any(|(key, value)| credential_key(key) || sensitive_value(value, false))
        }
        _ => false,
    }
}

/// Tokens by their well-known prefix in one line: `(start, end, what)`.
/// Deliberately narrow, because a profile save stops on one.
pub fn tokens(line: &str) -> Vec<(usize, usize, &'static str)> {
    const PREFIXES: &[(&str, usize, &str)] = &[
        ("sk-", 24, "an API key"),
        ("ghp_", 30, "a GitHub token"),
        ("gho_", 30, "a GitHub token"),
        ("ghs_", 30, "a GitHub token"),
        ("github_pat_", 30, "a GitHub token"),
        ("xoxb-", 20, "a chat token"),
        ("xoxp-", 20, "a chat token"),
        ("AKIA", 16, "a cloud access key"),
    ];
    let mut found: Vec<(usize, usize, &'static str)> = Vec::new();
    for (prefix, least, what) in PREFIXES {
        for (start, _) in line.match_indices(prefix) {
            let before = line.get(..start).unwrap_or_default();
            if before.chars().next_back().is_some_and(|c| c.is_ascii_alphanumeric()) {
                continue;
            }
            let body = line.get(start + prefix.len()..).unwrap_or_default();
            let run: usize = body
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                .map(char::len_utf8)
                .sum();
            let end = start + prefix.len() + run;
            let inside = found.iter().any(|(from, to, _)| start >= *from && start < *to);
            if run >= *least && !inside {
                found.push((start, end, what));
            }
        }
    }
    found.sort_by_key(|(start, ..)| *start);
    found
}

/// The first credential in a text meant for sharing: `(line, what)`, the
/// line 1-based.
pub fn find_secret(text: &str) -> Option<(u32, &'static str)> {
    let mut carry = Carry::default();
    for (index, line) in text.lines().enumerate() {
        let number = index as u32 + 1;
        let named = !named_values(line, &mut carry).is_empty();
        if line.contains("-----BEGIN ") && line.contains("PRIVATE KEY") {
            return Some((number, "a private key"));
        }
        if let Some((_, _, what)) = tokens(line).first() {
            return Some((number, what));
        }
        if !userinfo(line).is_empty() {
            return Some((number, "a user and password in a URL"));
        }
        if named {
            return Some((number, "a value named like a password or token"));
        }
    }
    None
}

/// The `user:password` of each URL in a line, as byte ranges.
fn userinfo(line: &str) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    for (at, _) in line.match_indices("://") {
        let start = at + 3;
        let rest = line.get(start..).unwrap_or_default();
        let run: usize = rest
            .chars()
            .take_while(|c| !c.is_whitespace() && !"/?#\"'`<>()[]{}\\,;".contains(*c))
            .map(char::len_utf8)
            .sum();
        let authority = rest.get(..run).unwrap_or_default();
        if let Some(sign) = authority.rfind('@')
            && sign > 0
        {
            found.push((start, start + sign));
        }
    }
    found
}

/// JavaScript's three quotes.
const QUOTES: [char; 3] = ['"', '\'', '`'];

/// The name a value is given to, read backwards from where the value
/// starts: `"apiKey":`, `'apiKey' :`, `apiKey:`, `config.apiKey =`. `None`
/// when what stands before is not a name and a `:` or `=`.
fn name_before(before: &str) -> Option<&str> {
    let before = before.trim_end();
    let named = before.strip_suffix(':').or_else(|| before.strip_suffix('='))?.trim_end();
    if let Some(quote) = named.chars().next_back().filter(|c| QUOTES.contains(c)) {
        // A quoted name: back to the quote that opens it.
        let inner = named.get(..named.len() - 1)?;
        return inner.get(inner.rfind(quote)? + 1..);
    }
    let name = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '$';
    let start = named.rfind(|c: char| !name(c)).map_or(0, |at| at + 1);
    named.get(start..).filter(|word| !word.is_empty())
}

/// Where the string whose text starts at byte `start` ends, and whether
/// this line closes it. One it does not close reaches the end of the line.
fn string_end(line: &str, start: usize, quote: char) -> (usize, bool) {
    let mut escaped = false;
    for (at, c) in line.get(start..).unwrap_or_default().char_indices() {
        match c {
            _ if escaped => escaped = false,
            '\\' => escaped = true,
            c if c == quote => return (start + at, true),
            _ => {}
        }
    }
    (line.len(), false)
}

/// What a credential leaves for the line after it.
#[derive(Default)]
struct Carry {
    /// The last thing read was a credential's name and its `:` or `=`: a
    /// formatter may put `"apiKey":` (or a script's `apiKey:`, `token =`)
    /// on one line and the string on the next. Blank and comment lines keep
    /// waiting.
    awaited: bool,
    /// A credential's template literal is still open: every line is its
    /// value until the backtick that closes it.
    open: bool,
}

/// The text of each string whose name is a credential's, as byte ranges
/// inside the quotes. JSON's `"token": "…"`, and what a script writes:
/// `{apiKey: 'x'}`, `{ 'api-key': "x" }`, `const password = \`x\``, with
/// the name and the value on one line or two, and a template literal over
/// as many lines as it runs.
///
/// Every quote is tried as the start of a value, by what stands before it,
/// so no other quote on the line (the apostrophe in a comment's "don't")
/// can hide one. That may mask a little prose; it never shows a value.
fn named_values(line: &str, carry: &mut Carry) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    // One string's text from `start`: its range, and where reading goes on.
    // `None` when a template literal runs past the line.
    let mut take = |start: usize, quote: char, carry: &mut Carry| {
        let (end, closed) = string_end(line, start, quote);
        if end > start {
            found.push((start, end));
        }
        carry.open = !closed && quote == '`';
        (!carry.open).then_some(end + 1)
    };
    let mut from = 0;
    let trimmed = line.trim();
    if carry.open {
        match take(0, '`', carry) {
            Some(after) => from = after,
            None => return found,
        }
    } else if carry.awaited && !trimmed.is_empty() && !trimmed.starts_with("//") {
        carry.awaited = false;
        if let Some(quote) = trimmed.chars().next().filter(|c| QUOTES.contains(c)) {
            let start = line.len() - line.trim_start().len() + quote.len_utf8();
            match take(start, quote, carry) {
                Some(after) => from = after,
                None => return found,
            }
        }
    }
    for (at, c) in line.char_indices() {
        if at < from || !QUOTES.contains(&c) {
            continue;
        }
        if !name_before(line.get(..at).unwrap_or_default()).is_some_and(credential_key) {
            continue;
        }
        match take(at + c.len_utf8(), c, carry) {
            Some(after) => from = after,
            None => return found,
        }
    }
    // A name and its `:` or `=` at the end of this line, with no value yet.
    if trimmed.ends_with([':', '=']) {
        carry.awaited = name_before(line).is_some_and(credential_key);
    }
    found
}

/// One line with each range replaced by the mark.
fn mask(line: &str, mut ranges: Vec<(usize, usize)>) -> String {
    ranges.sort_unstable();
    let mut out = String::with_capacity(line.len());
    let mut at = 0;
    for (start, end) in ranges {
        if start < at {
            continue;
        }
        out.push_str(line.get(at..start).unwrap_or_default());
        out.push_str(MARK);
        at = end;
    }
    out.push_str(line.get(at..).unwrap_or_default());
    out
}

/// Any text with its credentials replaced by the mark. Line by line, so a
/// diff of two redacted texts still lines up with the files.
pub fn text(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_key = false;
    let mut carry = Carry::default();
    for line in input.split_inclusive('\n') {
        let (body, ending) = match line.strip_suffix('\n') {
            Some(body) => (body, "\n"),
            None => (line, ""),
        };
        let begins = body.contains("-----BEGIN ") && body.contains("PRIVATE KEY");
        let ends = body.contains("-----END ") && body.contains("PRIVATE KEY");
        if begins || in_key {
            in_key = !ends;
            out.push_str(MARK);
            out.push_str(ending);
            continue;
        }
        let mut ranges = named_values(body, &mut carry);
        ranges.extend(userinfo(body));
        ranges.extend(tokens(body).into_iter().map(|(start, end, _)| (start, end)));
        if ranges.is_empty() {
            out.push_str(body);
        } else {
            out.push_str(&mask(body, ranges));
        }
        out.push_str(ending);
    }
    out
}

/// The settings file's text for `reader`: each setting whose value is a
/// credential (and, for an agent, each setting only the person may change)
/// reads as the mark, in place, so the file keeps its lines; then the rest
/// goes through [`text`], which covers what no setting's row describes.
pub fn settings(input: &str, reader: Reader) -> String {
    let mut out = input.to_owned();
    if let Ok(file) = jsonc::parse(input) {
        for row in &Schema::embedded().rows {
            let Some(value) = cmux_config::value::value_at(&file, &row.path) else { continue };
            let private = reader == Reader::Agent && !row.agent_settable;
            if (private || sensitive_value(value, matches!(row.kind, Kind::Url)))
                && let Ok(masked) = jsonc::set(&out, &row.path, &json!(MARK))
            {
                out = masked;
            }
        }
    }
    text(&out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_value_named_like_a_credential_reads_as_the_mark() {
        let before = "{\n  \"apiKey\": \"abc123\", \"name\": \"mine\",\n  \"auth\": { \"refresh_token\" : \"r-1\" }\n}\n";
        let after = text(before);
        assert_eq!(
            after,
            "{\n  \"apiKey\": \"[redacted]\", \"name\": \"mine\",\n  \"auth\": { \"refresh_token\" : \"[redacted]\" }\n}\n"
        );
        // A value that merely follows a credential-named string is not one.
        assert_eq!(text("[\"token\", \"night\"]"), "[\"token\", \"night\"]");
        assert_eq!(text("\"maxTokens\": \"12\""), "\"maxTokens\": \"12\"");
    }

    #[test]
    fn a_credential_on_the_line_after_its_name_reads_as_the_mark() {
        let file = "{\n  \"apiKey\":\n    // mine\n\n    \"private-value\",\n  \"name\":\n    \"mine\",\n  \"token\" :\n    [\"kept\"]\n}\n";
        let after = text(file);
        assert!(!after.contains("private-value"), "{after}");
        assert!(after.contains("    \"[redacted]\",\n"), "{after}");
        assert!(after.contains("\"mine\"") && after.contains("\"kept\""), "{after}");
        assert_eq!(after.lines().count(), file.lines().count());
        assert_eq!(find_secret(file), Some((5, "a value named like a password or token")));
        assert_eq!(find_secret("{\n  \"name\":\n    \"mine\"\n}\n"), None);
    }

    #[test]
    fn a_credential_in_a_script_reads_as_the_mark_however_it_is_quoted() {
        for (line, masked) in [
            ("const config = {apiKey: 'private-value'};", "const config = {apiKey: '[redacted]'};"),
            (
                "  { 'api-key': \"private-value\", name: 'mine' }",
                "  { 'api-key': \"[redacted]\", name: 'mine' }",
            ),
            ("let password = `private-value`;", "let password = `[redacted]`;"),
            ("config.authToken = 'private-value'", "config.authToken = '[redacted]'"),
            (
                "headers: { Authorization: \"Bearer private-value\" }",
                "headers: { Authorization: \"[redacted]\" }",
            ),
            (
                "const tokenizer = 'kept'; let title = \"kept: too\";",
                "const tokenizer = 'kept'; let title = \"kept: too\";",
            ),
            (
                "// don't share: { apiKey: 'private-value' }",
                "// don't share: { apiKey: '[redacted]' }",
            ),
        ] {
            assert_eq!(text(line), masked);
            assert_eq!(find_secret(line).is_some(), line != masked, "{line}");
        }
        let split = "const config = {\n  apiKey:\n    'private-value',\n  secret =\n    `private-value`\n};\n";
        assert!(!text(split).contains("private-value"), "{}", text(split));
        assert_eq!(find_secret(split), Some((3, "a value named like a password or token")));
    }

    #[test]
    fn a_credential_in_a_template_literal_is_hidden_on_every_line_it_runs() {
        for script in [
            "const token = `\nprivate-value\n`;\nconst title = 'kept';\n",
            "const config = {\n  apiKey:\n    `\n    private-value\n    more-private-value`,\n};\nconst title = 'kept';\n",
            "let secret = `private-value\n  ${more}private-value\n`; const title = 'kept';\n",
        ] {
            let shown = text(script);
            assert!(!shown.contains("private-value"), "{shown}");
            assert!(shown.contains("const title = 'kept';"), "{shown}");
            assert_eq!(shown.lines().count(), script.lines().count(), "{shown}");
            assert!(find_secret(script).is_some(), "{script}");
        }
        assert_eq!(
            find_secret("const token = `\nprivate-value\n`;\n"),
            Some((2, "a value named like a password or token"))
        );
    }

    #[test]
    fn a_url_keeps_its_host_and_loses_its_user_and_password() {
        assert_eq!(
            text("open https://alice:credential@example.com/page now"),
            "open https://[redacted]@example.com/page now"
        );
        assert_eq!(text("mail me@example.com"), "mail me@example.com");
        assert!(sensitive_url("https://alice:credential@example.com", true));
        assert!(sensitive_url("example.com/page?key=1", true));
        assert!(!sensitive_url("example.com/page?key=1", false));
        assert!(sensitive_url("https://example.com/#access=1", false));
        assert!(!sensitive_url("https://example.com/page", true));
        assert!(!sensitive_url("a night theme", true));
    }

    #[test]
    fn a_token_and_a_private_key_block_read_as_the_mark() {
        let token = format!("ghp_{}", "a1B2".repeat(9));
        assert_eq!(
            text(&format!("gh auth --with {token} now\n")),
            "gh auth --with [redacted] now\n"
        );
        assert_eq!(
            text(
                "a\n-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----\nb\n"
            ),
            "a\n[redacted]\n[redacted]\n[redacted]\n[redacted]\nb\n"
        );
        assert_eq!(find_secret(&format!("one\ntwo {token}\n")), Some((2, "a GitHub token")));
        assert_eq!(find_secret("the task-12345 and sk-short\n"), None);
        assert_eq!(
            find_secret("x\nfetch('https://u:p@host/x')\n"),
            Some((2, "a user and password in a URL"))
        );
    }

    #[test]
    fn a_setting_with_a_credential_reads_as_the_mark_and_keeps_its_line() {
        let file = "{\n  // mine\n  \"browser\": { \"newTabPage\": \"https://alice:credential@example.com\" },\n  \"appearance\": { \"density\": \"compact\" },\n  \"updates\": { \"channel\": \"nightly\" }\n}\n";
        let person = settings(file, Reader::Person);
        assert!(!person.contains("credential"), "{person}");
        assert!(person.contains("\"newTabPage\": \"[redacted]\""), "{person}");
        assert!(person.contains("\"channel\": \"nightly\""), "{person}");
        assert!(person.contains("\"density\": \"compact\""), "{person}");
        assert_eq!(person.lines().count(), file.lines().count());
        // An agent does not read what only the person may change.
        let agent = settings(file, Reader::Agent);
        assert!(agent.contains("\"channel\": \"[redacted]\""), "{agent}");
        assert!(agent.contains("\"density\": \"compact\""), "{agent}");
    }

    #[test]
    fn a_token_is_found_by_its_prefix_and_ordinary_text_is_not() {
        assert_eq!(
            find_secret("a\nkey = \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\"\n"),
            Some((2, "a GitHub token"))
        );
        assert_eq!(find_secret("-----BEGIN OPENSSH PRIVATE KEY-----"), Some((1, "a private key")));
        assert_eq!(find_secret("task-sk-ip and risk-free and AKIA"), None);
        assert_eq!(find_secret("color: #abcdef; /* sk-short */"), None);
    }
}

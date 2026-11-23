//! Deterministic Markdown-to-speech and transcript noise filters.
//! This is deliberately provider independent: the agent remains the brain.

/// Text that speech recognition commonly invents for silence or a cough.
pub fn is_noise(input: &str) -> bool {
    let folded = input.trim().to_lowercase();
    let folded = folded.trim_matches(|c: char| !c.is_alphanumeric() && !c.is_whitespace());
    if !folded.chars().any(char::is_alphabetic) {
        return true;
    }
    matches!(
        folded.replace('.', "").as_str(),
        "thank you"
            | "thanks"
            | "thanks for watching"
            | "thank you for watching"
            | "bye"
            | "you"
            | "uh"
            | "um"
            | "hmm"
            | "mm"
            | "ah"
            | "oh"
            | "okay bye"
            | "subtitles by the amaraorg community"
    )
}

/// Strip Markdown that is poor audio while preserving prose and link labels.
pub fn speakable(markdown: &str, max_characters: usize, max_inline_code: usize) -> Option<String> {
    let mut kept = Vec::new();
    let mut fence: Option<String> = None;
    let mut diff_run: Vec<String> = Vec::new();
    let flush = |kept: &mut Vec<String>, diff: &mut Vec<String>| {
        if diff.len() == 1 {
            kept.push(diff[0].clone());
        }
        diff.clear();
    };
    for raw in markdown.lines() {
        let line = raw.trim();
        if let Some(open) = &fence {
            if line.starts_with(open) {
                fence = None;
            }
            continue;
        }
        if line.starts_with("```") || line.starts_with("~~~") {
            flush(&mut kept, &mut diff_run);
            fence = Some(line[..3].to_string());
            continue;
        }
        if !line.is_empty() && line.chars().all(|c| "-*_= ".contains(c)) {
            flush(&mut kept, &mut diff_run);
            continue;
        }
        if is_diff_line(line) {
            diff_run.push(line.to_string());
            continue;
        }
        flush(&mut kept, &mut diff_run);
        if line.is_empty() || line.starts_with('|') || line.starts_with('<') {
            kept.push(String::new());
            continue;
        }
        if (raw.starts_with('\t') || raw.starts_with("    ")) && !is_list_item(line) {
            continue;
        }
        kept.push(line.to_string());
    }
    flush(&mut kept, &mut diff_run);

    let mut blocks = Vec::new();
    let mut current = String::new();
    for line in kept {
        let boundary = line.is_empty()
            || line.starts_with('#')
            || line.starts_with('>')
            || is_list_item(&line);
        if boundary && !current.is_empty() {
            blocks.push(std::mem::take(&mut current));
        }
        if line.is_empty() {
            continue;
        }
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(&line);
    }
    if !current.is_empty() {
        blocks.push(current);
    }
    let mut out = blocks
        .into_iter()
        .filter_map(|line| {
            let line = spoken_line(&line, max_inline_code);
            if line.is_empty() {
                None
            } else {
                let last = line.chars().last().unwrap();
                Some(if ".!?:;,…".contains(last) { line } else { format!("{line}.") })
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    out = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if !out.chars().any(char::is_alphabetic) {
        return None;
    }
    let count = out.chars().count();
    if count > max_characters {
        let mut prefix: String = out.chars().take(max_characters).collect();
        if let Some(pos) = prefix.rfind(|c: char| ".!?".contains(c)) {
            if prefix[..pos].chars().count() > max_characters / 3 {
                prefix.truncate(pos + 1);
                return Some(prefix);
            }
        }
        prefix.push('…');
        return Some(prefix);
    }
    Some(out)
}

fn spoken_line(line: &str, max_inline_code: usize) -> String {
    let mut s = line.trim().to_string();
    loop {
        let before = s.clone();
        for p in ["# ", "## ", "### ", "#### ", "##### ", "###### ", "> "] {
            if s.starts_with(p) {
                s = s[p.len()..].to_string();
            }
        }
        if let Some(rest) = strip_list(&s) {
            s = rest;
        }
        if let Some(a) = s.find("![") {
            if let Some(b) = s[a..].find("](").map(|i| i + a) {
                if let Some(end) = s[b..].find(')').map(|i| i + b) {
                    s.replace_range(a..=end, "");
                }
            }
        }
        // Link labels survive while destinations disappear.
        while let Some(a) = s.find('[') {
            let Some(close) = s[a + 1..].find(']').map(|i| i + a + 1) else { break };
            if s[close + 1..].starts_with('(') {
                if let Some(end) = s[close + 2..].find(')').map(|i| i + close + 2) {
                    let label = s[a + 1..close].to_string();
                    s.replace_range(a..=end, &label);
                    continue;
                }
            }
            break;
        }
        s = replace_code(&s, max_inline_code);
        for marker in ["**", "*", "~~"] {
            s = s.replace(marker, "");
        }
        s = remove_underscore_emphasis(&s);
        for prefix in ["http://", "https://"] {
            while let Some(a) = s.find(prefix) {
                let end = s[a..].find(char::is_whitespace).map(|i| a + i).unwrap_or(s.len());
                s.replace_range(a..end, "a link");
            }
        }
        if s == before {
            break;
        }
    }
    s.trim().to_string()
}

fn strip_list(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    if bytes.len() >= 2
        && (bytes[0] == b'-' || bytes[0] == b'*' || bytes[0] == b'+')
        && bytes[1].is_ascii_whitespace()
    {
        let rest = s[2..].trim_start();
        return Some(
            if rest.starts_with("[x] ") || rest.starts_with("[X] ") || rest.starts_with("[ ] ") {
                rest[4..].to_string()
            } else {
                rest.to_string()
            },
        );
    }
    let dot = s.find('.')?;
    if dot > 0 && s[..dot].chars().all(|c| c.is_ascii_digit()) {
        let rest = s[dot + 1..].trim_start();
        if rest.len() != s[dot + 1..].len() {
            return Some(rest.to_string());
        }
    }
    None
}
fn replace_code(s: &str, max: usize) -> String {
    let mut out = String::new();
    let mut code: Option<String> = None;
    for c in s.chars() {
        if c == '`' {
            if let Some(v) = code.take() {
                if v.chars().count() <= max {
                    out.push_str(&v);
                }
            } else {
                code = Some(String::new());
            }
        } else if let Some(v) = code.as_mut() {
            v.push(c);
        } else {
            out.push(c);
        }
    }
    if let Some(v) = code {
        out.push_str(&v);
    }
    out
}
fn remove_underscore_emphasis(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '_' && (i == 0 || !chars[i - 1].is_alphanumeric()) {
            if let Some(end) = (i + 1..chars.len()).find(|&j| {
                chars[j] == '_' && (j + 1 == chars.len() || !chars[j + 1].is_alphanumeric())
            }) {
                out.extend(&chars[i + 1..end]);
                i = end + 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}
fn is_diff_line(s: &str) -> bool {
    s.starts_with("@@")
        || s.starts_with("diff --git")
        || s.starts_with("+++ ")
        || s.starts_with("--- ")
        || (s.starts_with('+') || s.starts_with('-'))
            && !s.starts_with("+ ")
            && !s.starts_with("- ")
            && s.len() > 1
}
fn is_list_item(s: &str) -> bool {
    strip_list(s).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn noise_and_prose() {
        assert!(is_noise("  Thanks!!! "));
        assert!(is_noise("…"));
        assert!(!is_noise("Please open it"));
    }
    #[test]
    fn markdown_filter() {
        let s = speakable(
            "# Done\n\nSee [the docs](https://x) and `cargo test`.\n```\nsecret\n```",
            1200,
            40,
        )
        .unwrap();
        assert!(s.contains("Done"));
        assert!(s.contains("the docs"));
        assert!(!s.contains("secret"));
    }
    #[test]
    fn long_code_dropped() {
        let s =
            speakable("Use `abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz` now", 1200, 10)
                .unwrap();
        assert!(!s.contains("abcdefghijklmnopqrstuvwxyz"));
    }
}

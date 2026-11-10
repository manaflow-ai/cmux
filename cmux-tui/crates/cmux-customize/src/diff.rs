//! A small line diff, so `cmux customize diff` and the GUI show what a
//! draft changed without a dependency or a `git` on PATH.

/// Past this many lines on either side the diff says so instead of
/// computing (a customization file is small; a pasted bundle is not).
const MAX_LINES: usize = 4000;
const CONTEXT: usize = 3;

/// A unified diff of two texts, without the `---`/`+++` header. `None` when
/// they are equal.
pub fn unified(old: &str, new: &str) -> Option<String> {
    if old == new {
        return None;
    }
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    if a.len() > MAX_LINES || b.len() > MAX_LINES {
        return Some(format!(
            "@@ {} lines became {} lines (too long to show) @@\n",
            a.len(),
            b.len()
        ));
    }
    let ops = edit_script(&a, &b);
    let mut out = String::new();
    let mut at = 0;
    while at < ops.len() {
        // The next changed op, then a hunk that runs until CONTEXT*2 equal
        // lines separate it from the following change.
        let Some(first) =
            ops[at..].iter().position(|op| !matches!(op, Op::Same(..))).map(|i| at + i)
        else {
            break;
        };
        let start = first.saturating_sub(CONTEXT);
        let mut end = first;
        let mut last_change = first;
        while end < ops.len() {
            if !matches!(ops[end], Op::Same(..)) {
                last_change = end;
            } else if end - last_change > CONTEXT * 2 {
                break;
            }
            end += 1;
        }
        let end = (last_change + CONTEXT + 1).min(ops.len());
        let (mut old_start, mut new_start) = (0, 0);
        for op in &ops[..start] {
            match op {
                Op::Same(..) => {
                    old_start += 1;
                    new_start += 1;
                }
                Op::Removed(_) => old_start += 1,
                Op::Added(_) => new_start += 1,
            }
        }
        let old_count = ops[start..end].iter().filter(|op| !matches!(op, Op::Added(_))).count();
        let new_count = ops[start..end].iter().filter(|op| !matches!(op, Op::Removed(_))).count();
        out.push_str(&format!(
            "@@ -{},{old_count} +{},{new_count} @@\n",
            old_start + usize::from(old_count > 0),
            new_start + usize::from(new_count > 0),
        ));
        for op in &ops[start..end] {
            let (sign, line) = match op {
                Op::Same(line) => (' ', line),
                Op::Removed(line) => ('-', line),
                Op::Added(line) => ('+', line),
            };
            out.push(sign);
            out.push_str(line);
            out.push('\n');
        }
        at = end;
    }
    Some(out)
}

enum Op<'a> {
    Same(&'a str),
    Removed(&'a str),
    Added(&'a str),
}

/// Longest common subsequence over the lines between the common prefix and
/// suffix (most edits touch a few lines, so the table is small).
fn edit_script<'a>(a: &[&'a str], b: &[&'a str]) -> Vec<Op<'a>> {
    let prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let suffix =
        a[prefix..].iter().rev().zip(b[prefix..].iter().rev()).take_while(|(x, y)| x == y).count();
    let (mid_a, mid_b) = (&a[prefix..a.len() - suffix], &b[prefix..b.len() - suffix]);
    let mut ops: Vec<Op<'a>> = a[..prefix].iter().map(|line| Op::Same(line)).collect();
    let (n, m) = (mid_a.len(), mid_b.len());
    // lcs[i][j]: the LCS length of mid_a[i..] and mid_b[j..].
    let mut lcs = vec![0u32; (n + 1) * (m + 1)];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i * (m + 1) + j] = if mid_a[i] == mid_b[j] {
                lcs[(i + 1) * (m + 1) + j + 1] + 1
            } else {
                lcs[(i + 1) * (m + 1) + j].max(lcs[i * (m + 1) + j + 1])
            };
        }
    }
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if mid_a[i] == mid_b[j] {
            ops.push(Op::Same(mid_a[i]));
            i += 1;
            j += 1;
        } else if lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1] {
            ops.push(Op::Removed(mid_a[i]));
            i += 1;
        } else {
            ops.push(Op::Added(mid_b[j]));
            j += 1;
        }
    }
    ops.extend(mid_a[i..].iter().map(|line| Op::Removed(line)));
    ops.extend(mid_b[j..].iter().map(|line| Op::Added(line)));
    ops.extend(a[a.len() - suffix..].iter().map(|line| Op::Same(line)));
    ops
}

#[cfg(test)]
mod tests {
    use super::unified;

    #[test]
    fn equal_texts_have_no_diff() {
        assert_eq!(unified("a\nb\n", "a\nb\n"), None);
    }

    #[test]
    fn one_changed_line_shows_with_its_context() {
        let old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
        let new = "1\n2\n3\n4\nfive\n6\n7\n8\n9\n";
        assert_eq!(
            unified(old, new).unwrap(),
            "@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+five\n 6\n 7\n 8\n"
        );
    }

    #[test]
    fn a_new_file_is_all_additions() {
        assert_eq!(unified("", "a\nb\n").unwrap(), "@@ -0,0 +1,2 @@\n+a\n+b\n");
    }

    #[test]
    fn two_far_changes_are_two_hunks() {
        let old: String = (1..=30).map(|n| format!("{n}\n")).collect();
        let new = old.replace("\n3\n", "\nthree\n").replace("\n27\n", "\ntwenty-seven\n");
        let diff = unified(&old, &new).unwrap();
        assert_eq!(diff.matches("@@ -").count(), 2, "{diff}");
        assert!(diff.contains("-27\n+twenty-seven\n"));
    }
}

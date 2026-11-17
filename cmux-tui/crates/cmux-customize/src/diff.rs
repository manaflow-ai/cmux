//! A small line diff, so `cmux customize diff` and the GUI show what a
//! draft changed without a dependency or a `git` on PATH.

/// Past this many lines on either side the diff says so instead of
/// computing (a customization file is small; a pasted bundle is not).
const MAX_LINES: usize = 4000;
const CONTEXT: usize = 3;

#[derive(Clone, Copy)]
enum Op<'a> {
    Same(&'a str),
    Removed(&'a str),
    Added(&'a str),
}

impl Op<'_> {
    fn changed(&self) -> bool {
        !matches!(self, Op::Same(_))
    }
}

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
    // Each op with the old and new line numbers it starts at (1-based).
    let mut numbered = Vec::with_capacity(ops.len());
    let (mut old_line, mut new_line) = (1usize, 1usize);
    for op in &ops {
        numbered.push((*op, old_line, new_line));
        match op {
            Op::Same(_) => {
                old_line += 1;
                new_line += 1;
            }
            Op::Removed(_) => old_line += 1,
            Op::Added(_) => new_line += 1,
        }
    }
    // A hunk is a run of ops in which no two changes are more than
    // CONTEXT * 2 equal lines apart, with CONTEXT lines around it.
    let changes: Vec<usize> =
        ops.iter().enumerate().filter(|(_, op)| op.changed()).map(|(index, _)| index).collect();
    let mut out = String::new();
    let mut group: Option<(usize, usize)> = None;
    let flush = |first: usize, last: usize, out: &mut String| {
        let start = first.saturating_sub(CONTEXT);
        let end = (last + CONTEXT + 1).min(numbered.len());
        let hunk = numbered.get(start..end).unwrap_or_default();
        let old_count = hunk.iter().filter(|(op, ..)| !matches!(op, Op::Added(_))).count();
        let new_count = hunk.iter().filter(|(op, ..)| !matches!(op, Op::Removed(_))).count();
        let (old_start, new_start) = hunk.first().map_or((1, 1), |(_, old, new)| (*old, *new));
        // An empty side starts at the line before, as `diff -u` writes it.
        let at =
            |start: usize, count: usize| if count == 0 { start.saturating_sub(1) } else { start };
        out.push_str(&format!(
            "@@ -{},{old_count} +{},{new_count} @@\n",
            at(old_start, old_count),
            at(new_start, new_count)
        ));
        for (op, ..) in hunk {
            let (sign, line) = match op {
                Op::Same(line) => (' ', line),
                Op::Removed(line) => ('-', line),
                Op::Added(line) => ('+', line),
            };
            out.push(sign);
            out.push_str(line);
            out.push('\n');
        }
    };
    for index in changes {
        group = match group {
            Some((first, last)) if index - last <= CONTEXT * 2 + 1 => Some((first, index)),
            Some((first, last)) => {
                flush(first, last, &mut out);
                Some((index, index))
            }
            None => Some((index, index)),
        };
    }
    if let Some((first, last)) = group {
        flush(first, last, &mut out);
    }
    Some(out)
}

/// Longest common subsequence over the lines between the common prefix and
/// suffix (most edits touch a few lines, so the table is small).
fn edit_script<'a>(a: &[&'a str], b: &[&'a str]) -> Vec<Op<'a>> {
    let prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let suffix = a
        .iter()
        .skip(prefix)
        .rev()
        .zip(b.iter().skip(prefix).rev())
        .take_while(|(x, y)| x == y)
        .count();
    let mid_a: Vec<&'a str> =
        a.iter().skip(prefix).take(a.len() - prefix - suffix).copied().collect();
    let mid_b: Vec<&'a str> =
        b.iter().skip(prefix).take(b.len() - prefix - suffix).copied().collect();
    let (n, m) = (mid_a.len(), mid_b.len());
    // lcs[i * (m + 1) + j]: the LCS length of mid_a[i..] and mid_b[j..].
    let mut lcs = vec![0u32; (n + 1) * (m + 1)];
    let cell = |lcs: &[u32], i: usize, j: usize| lcs.get(i * (m + 1) + j).copied().unwrap_or(0);
    for (i, left) in mid_a.iter().enumerate().rev() {
        for (j, right) in mid_b.iter().enumerate().rev() {
            let value = if left == right {
                cell(&lcs, i + 1, j + 1) + 1
            } else {
                cell(&lcs, i + 1, j).max(cell(&lcs, i, j + 1))
            };
            if let Some(slot) = lcs.get_mut(i * (m + 1) + j) {
                *slot = value;
            }
        }
    }
    let mut ops: Vec<Op<'a>> = a.iter().take(prefix).copied().map(Op::Same).collect();
    let (mut i, mut j) = (0, 0);
    loop {
        match (mid_a.get(i).copied(), mid_b.get(j).copied()) {
            (Some(left), Some(right)) if left == right => {
                ops.push(Op::Same(left));
                i += 1;
                j += 1;
            }
            (Some(left), Some(_)) if cell(&lcs, i + 1, j) >= cell(&lcs, i, j + 1) => {
                ops.push(Op::Removed(left));
                i += 1;
            }
            (_, Some(right)) => {
                ops.push(Op::Added(right));
                j += 1;
            }
            (Some(left), None) => {
                ops.push(Op::Removed(left));
                i += 1;
            }
            (None, None) => break,
        }
    }
    ops.extend(a.iter().skip(a.len() - suffix).copied().map(Op::Same));
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
    fn a_removed_tail_keeps_its_context() {
        assert_eq!(unified("a\nb\nc\n", "a\n").unwrap(), "@@ -1,3 +1,1 @@\n a\n-b\n-c\n");
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

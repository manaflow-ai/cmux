//! `cmux customize library standup`: every library entry as one line a
//! person reads out at standup. Leo, 2026-11-23: "improve the customization
//! checklist of stuff. because that allows additional yolo mode "merges" but
//! moreso things that you can just click toggle on and off checklist have a
//! list of prs or repos whatever that i can just present with standup".
//!
//! A line says what the entry is (a PR, a branch, a commit, a folder, a
//! fork, a setup repo, a recipe), whether it is on in this build, what
//! wins over it, and the last refresh's word on it (in your build, a newer
//! head, no longer applies), with its link. It only reads: the words come
//! from the listing and the setups' receipts, so it needs no network and
//! the Settings checklist, the CLI and an agent all print the same lines.

use serde::Serialize;

use super::text::one_line;
use super::{CodeKind, Listed, Listing};
use crate::setup::{Receipt, SetupSource};

/// One entry at standup.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StandupLine {
    /// The library entry (`pr-43496`, `setup-manaflow-ai-ember-look`).
    pub name: String,
    /// `pr`, `branch`, `sha`, `dir`, `fork`, `setup` or `recipe`.
    pub kind: &'static str,
    pub on: bool,
    /// What it is: `#43496 Cat icon`, `manaflow-ai/ember-look`, a recipe's
    /// name and the words that asked for it.
    pub title: String,
    /// One line of state: `on`, `off`, `on for a try, 4 min left`, what
    /// wins over it, then the last refresh's note.
    pub status: String,
    /// The PR, branch, commit or repo on the web; none for a folder or a
    /// recipe.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
}

/// The whole report: code first (the yolo merges), then repos, then recipes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Standup {
    pub lines: Vec<StandupLine>,
    pub on: usize,
    /// The report as Markdown: what the card copies and the CLI prints.
    pub text: String,
}

/// The standup report of `listing`; `setups` names each setup entry's repo.
pub fn standup(listing: &Listing, setups: &[Receipt], now_ms: u64) -> Standup {
    let mut lines: Vec<(u8, StandupLine)> = listing
        .entries
        .iter()
        .map(|entry| {
            let setup =
                setups.iter().find(|receipt| crate::setup::profile_name(&receipt.id) == entry.name);
            line(entry, listing, setup, now_ms)
        })
        .collect();
    // Stable: within a group the stack's order, top first.
    lines.sort_by_key(|(rank, _)| *rank);
    let lines: Vec<StandupLine> = lines.into_iter().map(|(_, line)| line).collect();
    let on = lines.iter().filter(|line| line.on).count();
    let text = text(&lines, on);
    Standup { lines, on, text }
}

fn line(
    entry: &Listed,
    listing: &Listing,
    setup: Option<&Receipt>,
    now_ms: u64,
) -> (u8, StandupLine) {
    let mut status = vec![if !entry.on {
        "off".to_owned()
    } else if let Some(until) = entry.until_ms {
        let minutes = until.saturating_sub(now_ms).div_ceil(60_000);
        format!("on for a try, {minutes} min left")
    } else {
        "on".to_owned()
    }];
    if entry.on
        && let Some(conflict) =
            listing.conflicts.iter().find(|c| c.losers.iter().any(|n| n == &entry.name))
    {
        status.push(format!("{} wins over it", conflict.winner));
    }
    let (rank, kind, title, link) = if let Some(code) = &entry.code {
        if !code.note.is_empty() {
            status.push(one_line(&code.note));
        }
        if let Some(first) = code.needs_build.first() {
            status.push(one_line(first));
        }
        let titled = |what: String| {
            if code.title.is_empty() { what } else { format!("{what}: {}", one_line(&code.title)) }
        };
        let web = |path: String| Some(format!("https://github.com/{}/{path}", code.repo));
        match code.kind {
            CodeKind::Pr => {
                let title = if code.title.is_empty() {
                    format!("#{}", code.pr)
                } else {
                    format!("#{} {}", code.pr, one_line(&code.title))
                };
                (0, "pr", title, web(format!("pull/{}", code.pr)))
            }
            CodeKind::Branch => (
                1,
                "branch",
                titled(format!("branch {}", code.source)),
                web(format!("tree/{}", code.source)),
            ),
            CodeKind::Sha => {
                let short: String = code.source.chars().take(7).collect();
                (
                    1,
                    "sha",
                    titled(format!("commit {short}")),
                    web(format!("commit/{}", code.source)),
                )
            }
            CodeKind::Fork => {
                let link = code
                    .source
                    .split_once('@')
                    .map(|(repo, git_ref)| format!("https://github.com/{repo}/tree/{git_ref}"));
                (1, "fork", titled(format!("fork {}", code.source)), link)
            }
            CodeKind::Dir => (2, "dir", titled(format!("folder {}", code.source)), None),
        }
    } else if let Some(receipt) = setup {
        let link = match &receipt.source {
            SetupSource::Repo { reference } => {
                Some(format!("https://{}/{}/{}", reference.host, reference.owner, reference.repo))
            }
            SetupSource::Folder { .. } => None,
        };
        let what = match &receipt.source {
            SetupSource::Repo { reference } => format!("{}/{}", reference.owner, reference.repo),
            SetupSource::Folder { path } => path.display().to_string(),
        };
        let title = if receipt.name.is_empty() || receipt.name == what {
            what
        } else {
            format!("{} ({what})", one_line(&receipt.name))
        };
        (3, "setup", title, link)
    } else {
        let words = entry.words.first().map(String::as_str).unwrap_or(entry.description.as_str());
        let title = if words.trim().is_empty() {
            entry.name.clone()
        } else {
            let short: String = one_line(words).chars().take(80).collect();
            format!("{}: {short}", entry.name)
        };
        (4, "recipe", title, None)
    };
    (
        rank,
        StandupLine {
            name: entry.name.clone(),
            kind,
            on: entry.on,
            title,
            status: status.join(" · "),
            link,
        },
    )
}

fn text(lines: &[StandupLine], on: usize) -> String {
    if lines.is_empty() {
        return "Customizations: none yet (`cmux customize use pr:N` puts an unmerged PR in your build)\n"
            .to_owned();
    }
    let mut out = format!("Customizations: {on} on of {}\n", lines.len());
    let groups: [(&str, &[&str]); 3] = [
        ("Unmerged code in my build", &["pr", "branch", "sha", "fork", "dir"]),
        ("Repos", &["setup"]),
        ("Recipes", &["recipe"]),
    ];
    for (heading, kinds) in groups {
        let mut group = lines.iter().filter(|line| kinds.contains(&line.kind)).peekable();
        if group.peek().is_none() {
            continue;
        }
        out.push_str(&format!("\n{heading}\n"));
        for line in group {
            let mark = if line.on { "x" } else { " " };
            out.push_str(&format!("- [{mark}] {}: {}", line.title, line.status));
            if let Some(link) = &line.link {
                out.push_str(&format!(" {link}"));
            }
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
#[path = "standup_tests.rs"]
mod tests;

//! `cmux docs guide [SLUG | --full]`: the cmux NEXT guide (how cmux fits together, agents,
//! machines, the vault, ...), read with no network and no session.
//!
//! The pages are written in web/data/next-docs/pages.ts and generated into docs/cmux-next/guide
//! by `bun web/scripts/export-next-docs.ts` (web/tests/next-docs.test.ts fails when they are
//! stale). This build embeds them, so the guide an agent reads matches the CLI that prints it.

use std::io::{self, Write};
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use super::super::{OutputMode, UsageError};

const PAGES_JSON: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../docs/cmux-next/guide/pages.json"));
const FULL: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../docs/cmux-next/guide/llms-full.txt"
));

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(in crate::cli) struct Page {
    pub(in crate::cli) slug: String,
    pub(in crate::cli) title: String,
    description: String,
    #[serde(skip_serializing)]
    markdown: String,
}

#[derive(Deserialize)]
struct Pages {
    pages: Vec<Page>,
}

/// What `cmux docs guide` was asked for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Request {
    List,
    Page(String),
    Full,
}

pub(in crate::cli) fn pages() -> &'static [Page] {
    static PAGES: OnceLock<Vec<Page>> = OnceLock::new();
    PAGES.get_or_init(|| {
        serde_json::from_str::<Pages>(PAGES_JSON).map(|pages| pages.pages).unwrap_or_default()
    })
}

/// The words after `docs guide`.
pub(in crate::cli) fn parse(args: &[String]) -> Result<Request, UsageError> {
    match args {
        [] => Ok(Request::List),
        [flag] if flag == "--full" => Ok(Request::Full),
        [slug] if !slug.starts_with('-') => Ok(Request::Page(slug.clone())),
        _ => Err(UsageError::new("usage: cmux docs guide [SLUG | --full]")),
    }
}

/// Pages whose text has every word of the query of three letters or more, title matches
/// first: at most three, for `cmux docs search` and the MCP `cmux_docs` tool.
pub(in crate::cli) fn matching(query: &str) -> Vec<&'static Page> {
    let terms = query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|term| term.len() >= 3)
        .map(str::to_lowercase)
        .collect::<Vec<_>>();
    if terms.is_empty() {
        return Vec::new();
    }
    let mut found = pages()
        .iter()
        .filter(|page| {
            let text = page.markdown.to_lowercase();
            terms.iter().all(|term| text.contains(term.as_str()))
        })
        .map(|page| {
            let head = format!("{} {}", page.title, page.description).to_lowercase();
            (terms.iter().filter(|term| head.contains(term.as_str())).count(), page)
        })
        .collect::<Vec<_>>();
    found.sort_by(|(left, _), (right, _)| right.cmp(left));
    found.into_iter().take(3).map(|(_, page)| page).collect()
}

pub(in crate::cli) fn run(request: &Request, output: OutputMode) -> i32 {
    let mut stdout = io::stdout().lock();
    let code = match request {
        Request::List => {
            match output {
                OutputMode::Quiet => {}
                OutputMode::Json | OutputMode::JsonLines => {
                    let _ = serde_json::to_writer(
                        &mut stdout,
                        &serde_json::json!({ "pages": pages() }),
                    );
                    let _ = stdout.write_all(b"\n");
                }
                OutputMode::Human => {
                    let _ = writeln!(
                        stdout,
                        "cmux NEXT guide: `cmux docs guide SLUG` prints a page, `--full` every page.\n"
                    );
                    for page in pages() {
                        let _ = writeln!(
                            stdout,
                            "  {:<20} {}\n  {:<20} {}",
                            page.slug, page.title, "", page.description
                        );
                    }
                }
            }
            0
        }
        Request::Full => {
            if output != OutputMode::Quiet {
                let _ = stdout.write_all(FULL.as_bytes());
            }
            0
        }
        Request::Page(slug) => match pages().iter().find(|page| &page.slug == slug) {
            Some(page) => {
                match output {
                    OutputMode::Quiet => {}
                    OutputMode::Json | OutputMode::JsonLines => {
                        let value = serde_json::json!({
                            "slug": page.slug, "title": page.title,
                            "description": page.description, "markdown": page.markdown,
                        });
                        let _ = serde_json::to_writer(&mut stdout, &value);
                        let _ = stdout.write_all(b"\n");
                    }
                    OutputMode::Human => {
                        let _ = stdout.write_all(page.markdown.as_bytes());
                    }
                }
                0
            }
            None => {
                let slugs = pages().iter().map(|page| page.slug.as_str()).collect::<Vec<_>>();
                let _ = writeln!(
                    io::stderr(),
                    "cmux docs guide: no page {slug}; the pages are: {}",
                    slugs.join(", ")
                );
                1
            }
        },
    };
    let _ = stdout.flush();
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_guide_has_the_architecture_page_and_its_links() {
        assert!(pages().len() >= 20, "pages.json did not parse");
        let architecture = pages().iter().find(|page| page.slug == "architecture").unwrap();
        assert!(architecture.markdown.starts_with("# How cmux NEXT fits together\n"));
        assert!(architecture.markdown.contains("](acpmux.md)"));
        assert!(FULL.contains("# Secrets and the vault"));
    }

    #[test]
    fn guide_parses_list_page_and_full() {
        let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        assert_eq!(parse(&[]).unwrap(), Request::List);
        assert_eq!(parse(&words(&["--full"])).unwrap(), Request::Full);
        assert_eq!(parse(&words(&["vault"])).unwrap(), Request::Page("vault".to_owned()));
        assert!(parse(&words(&["--bogus"])).is_err());
        assert!(parse(&words(&["vault", "machines"])).is_err());
    }

    /// An agent that asks in its own words finds the page that answers it.
    #[test]
    fn a_question_finds_its_page() {
        let slugs =
            |query| matching(query).iter().map(|page| page.slug.as_str()).collect::<Vec<_>>();
        assert!(slugs("vault placeholder host").contains(&"vault"));
        assert_eq!(slugs("fits together").first(), Some(&"architecture"));
        assert!(slugs("a b").is_empty());
    }
}

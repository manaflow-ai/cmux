//! `cmux customize library`: everything you applied, kept as entries you
//! turn on and off and stack in order; shared as one file or one link.
//! The model is `cmux_customize::library`; this is its grammar and words.

use std::io::{Read, Write};

use base64::Engine;
use cmux_customize::library::{Changed, Collection, Listing, Position};
use cmux_customize::{Customize, Error};
use serde_json::{Value, json};

use super::Failure;
use super::render::Answer;

/// A link that carries a whole collection: `cmux-collection:` and the
/// collection's JSON, deflated, in URL-safe base64.
pub(super) const LINK_PREFIX: &str = "cmux-collection:";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Request {
    List,
    On {
        name: String,
    },
    Off {
        name: String,
    },
    Order {
        name: String,
        position: Position,
    },
    Remove {
        name: String,
    },
    Export {
        file: Option<String>,
        link: bool,
        only_on: bool,
        name: Option<String>,
    },
    Import {
        source: String,
        on: bool,
    },
    /// Every pull request entry against what is published and this build.
    Refresh,
}

const USAGE: &str = "customize library takes list, refresh, on NAME, off NAME, order NAME top|bottom|N, remove NAME, export [FILE] [--link] [--on] [--name NAME], import FILE|LINK|- [--on]";

/// Parses the words after `library`.
pub(super) fn parse(words: &[String]) -> Result<Request, String> {
    let name = |rest: &[String], verb: &str| match rest {
        [name] if !name.starts_with('-') => Ok(name.clone()),
        _ => Err(format!("customize library {verb} needs one entry NAME")),
    };
    let Some((verb, rest)) = words.split_first() else { return Ok(Request::List) };
    match verb.as_str() {
        "list" | "ls" if rest.is_empty() => Ok(Request::List),
        "refresh" if rest.is_empty() => Ok(Request::Refresh),
        "on" | "enable" => Ok(Request::On { name: name(rest, "on")? }),
        "off" | "disable" => Ok(Request::Off { name: name(rest, "off")? }),
        "remove" | "rm" => Ok(Request::Remove { name: name(rest, "remove")? }),
        "order" | "move" => {
            match rest {
                [entry, position] if !entry.starts_with('-') => {
                    let position = match position.as_str() {
                    "top" => Position::Top,
                    "bottom" => Position::Bottom,
                    n => Position::At(n.parse::<usize>().ok().filter(|n| *n >= 1).ok_or_else(
                        || format!("{n:?} is not a position: top, bottom or a number from 1 (the top)"),
                    )?),
                };
                    Ok(Request::Order { name: entry.clone(), position })
                }
                _ => Err("customize library order needs NAME and top, bottom or N (1 is the top)"
                    .to_owned()),
            }
        }
        "export" => {
            let (mut file, mut link, mut only_on, mut name) = (None, false, false, None);
            let mut iter = rest.iter();
            while let Some(word) = iter.next() {
                match word.as_str() {
                    "--link" => link = true,
                    "--on" => only_on = true,
                    "--name" => {
                        name = Some(iter.next().cloned().ok_or("--name needs a value")?);
                    }
                    flag if flag.starts_with('-') => {
                        return Err(format!("customize library export does not take {flag:?}"));
                    }
                    _ if file.is_none() => file = Some(word.clone()),
                    _ => return Err("customize library export takes one FILE".to_owned()),
                }
            }
            Ok(Request::Export { file, link, only_on, name })
        }
        "import" => {
            let on = rest.iter().any(|word| word == "--on");
            let sources: Vec<&String> = rest.iter().filter(|word| *word != "--on").collect();
            match sources.as_slice() {
                [source] if *source == "-" || !source.starts_with('-') => {
                    Ok(Request::Import { source: (*source).clone(), on })
                }
                _ => Err("customize library import needs one FILE, LINK or - (stdin)".to_owned()),
            }
        }
        _ => Err(USAGE.to_owned()),
    }
}

/// One library verb.
pub(super) fn execute(
    customize: &Customize,
    request: Request,
    origin: &str,
    now_ms: u64,
) -> Result<Answer, Failure> {
    Ok(match request {
        Request::List => {
            let listing = customize.library()?;
            let human = list_lines(&listing);
            Answer::Library { json: json!({ "library": listing }), human }
        }
        Request::Refresh => super::pr::refresh(customize, origin, now_ms)?,
        Request::On { name } => changed(customize.library_set_on(&name, true, origin, now_ms)?),
        Request::Off { name } => changed(customize.library_set_on(&name, false, origin, now_ms)?),
        Request::Order { name, position } => {
            changed(customize.library_order(&name, position, origin, now_ms)?)
        }
        Request::Remove { name } => changed(customize.library_remove(&name, origin, now_ms)?),
        Request::Export { file, link, only_on, name } => {
            let collection =
                customize.library_export(name.as_deref().unwrap_or("my cmux"), "", only_on)?;
            export(&collection, file.as_deref(), link)?
        }
        Request::Import { source, on } => {
            let text = read_source(&source)?;
            let collection = Customize::parse_collection(&text)?;
            let imported = customize.library_import(&collection, on, origin, now_ms)?;
            let mut human = String::new();
            if !imported.added.is_empty() {
                human.push_str(&format!(
                    "added {} to your library{}: {}\n",
                    cmux_customize::count(imported.added.len(), "entry"),
                    if on { "" } else { ", off" },
                    imported.added.join(", ")
                ));
            }
            if !imported.already.is_empty() {
                human.push_str(&format!(
                    "already in your library: {}\n",
                    imported.already.join(", ")
                ));
            }
            for (from, to) in &imported.renamed {
                human.push_str(&format!("{from} is {to} here: the library had another {from}\n"));
            }
            if imported.added.is_empty() && imported.already.is_empty() {
                human.push_str("the collection had no entries\n");
            }
            human.push_str(&change_lines(&imported.change));
            if !on && !imported.added.is_empty() {
                human.push_str("  cmux customize library on NAME   turn one on\n");
            }
            Answer::Library { json: json!(imported), human }
        }
    })
}

fn changed(change: Changed) -> Answer {
    let mut human = change_lines(&change);
    human.push_str(&list_lines(&change.library));
    Answer::Library { json: json!(change), human }
}

fn change_lines(change: &Changed) -> String {
    let mut out = String::new();
    if let Some(n) = change.by_hand {
        out.push_str(&format!("your unapplied edits were kept first, as generation {n}\n"));
    }
    match &change.generation {
        Some(generation) => out.push_str(&format!(
            "applied as generation {} ({}); `cmux customize rollback` undoes it\n",
            generation.n,
            change.changed.join(", ")
        )),
        // A code layer moves web-dev.json, which no generation holds.
        None if change.changed.iter().any(|key| key == cmux_customize::library::WEB_KEY) => {
            out.push_str("web pages now load from the layer the library says; open pages reload\n");
        }
        None => out.push_str("nothing live changed\n"),
    }
    out
}

fn list_lines(listing: &Listing) -> String {
    let mut out = String::new();
    if listing.entries.is_empty() {
        out.push_str("Your library is empty. Everything you apply (an ask, a profile or recipe you use, a try-on you keep) is saved here by itself.\n");
        out.push_str("  cmux customize library import FILE|LINK   add someone's collection\n");
        return out;
    }
    out.push_str("Your library, top first (where two entries that are on set the same thing, the higher one wins):\n");
    let width = listing.entries.iter().map(|entry| entry.name.len()).max().unwrap_or(4);
    for entry in &listing.entries {
        let mut what: Vec<String> =
            entry.settings.iter().chain(entry.files.iter()).cloned().collect();
        if let Some(code) = &entry.code {
            what.push(if code.has_web() {
                format!(
                    "web layer of #{} at {}",
                    code.pr,
                    code.head.get(..12).unwrap_or(&code.head)
                )
            } else {
                format!("#{}: nothing a running cmux can take", code.pr)
            });
            what.extend(code.needs_build.iter().map(|line| format!("needs a build: {line}")));
            if !code.note.is_empty() {
                what.push(code.note.clone());
            }
        }
        let words = entry.words.first().map(|w| format!("  \"{w}\"")).unwrap_or_default();
        out.push_str(&format!(
            "{:>3} {} {:width$}  {}{}\n      {}\n",
            entry.position,
            if entry.on { "on " } else { "off" },
            entry.name,
            entry.source,
            words,
            what.join(", ")
        ));
    }
    if !listing.conflicts.is_empty() {
        out.push_str("Set by more than one entry that is on:\n");
        for conflict in &listing.conflicts {
            out.push_str(&format!(
                "  {}: {} wins over {}\n",
                conflict.key,
                conflict.winner,
                conflict.losers.join(", ")
            ));
        }
    }
    out.push_str("  cmux customize library on|off NAME        turn one on or off\n");
    out.push_str("  cmux customize library order NAME top|N   move it (higher wins)\n");
    out.push_str(
        "  cmux customize library export FILE        share them as one file (--link: as a link)\n",
    );
    out
}

fn export(collection: &Collection, file: Option<&str>, link: bool) -> Result<Answer, Failure> {
    let mut text = serde_json::to_string_pretty(collection).map_err(io_failure)?;
    text.push('\n');
    let count = cmux_customize::count(collection.entries.len(), "entry");
    if link {
        let link = to_link(&text).map_err(io_failure)?;
        let human = format!("{link}\n");
        return Ok(Answer::Library {
            json: json!({ "link": link, "entries": collection.entries.len() }),
            human,
        });
    }
    match file {
        Some(path) if path != "-" => {
            cmux_config::fsio::write_atomic(std::path::Path::new(path), text.as_bytes())
                .map_err(io_failure)?;
            Ok(Answer::Library {
                json: json!({ "file": path, "entries": collection.entries.len() }),
                human: format!(
                    "wrote {count} to {path}; `cmux customize library import {path}` adds them anywhere\n"
                ),
            })
        }
        _ => Ok(Answer::Library {
            json: serde_json::to_value(collection).unwrap_or(Value::Null),
            human: text,
        }),
    }
}

/// The text of a collection from a file, a link or stdin.
fn read_source(source: &str) -> Result<String, Failure> {
    let limit = cmux_customize::library::MAX_COLLECTION_BYTES as u64;
    if let Some(payload) = source.strip_prefix(LINK_PREFIX) {
        return from_link(payload).map_err(|why| Failure::from(Error::Library(why)));
    }
    let mut text = String::new();
    let read = if source == "-" {
        std::io::stdin().take(limit + 1).read_to_string(&mut text)
    } else {
        std::fs::File::open(source).and_then(|file| file.take(limit + 1).read_to_string(&mut text))
    };
    read.map_err(|error| Failure::from(Error::Library(format!("{source}: {error}"))))?;
    Ok(text)
}

pub(super) fn to_link(text: &str) -> std::io::Result<String> {
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(text.as_bytes())?;
    let bytes = encoder.finish()?;
    Ok(format!("{LINK_PREFIX}{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)))
}

pub(super) fn from_link(payload: &str) -> Result<String, String> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim())
        .map_err(|_| "not a cmux collection link (its text is cut or changed)".to_owned())?;
    let limit = cmux_customize::library::MAX_COLLECTION_BYTES as u64;
    let mut text = String::new();
    flate2::read::DeflateDecoder::new(bytes.as_slice())
        .take(limit + 1)
        .read_to_string(&mut text)
        .map_err(|_| "not a cmux collection link (its text is cut or changed)".to_owned())?;
    Ok(text)
}

fn io_failure(error: impl std::fmt::Display) -> Failure {
    Failure::from(Error::Io(std::io::Error::other(error.to_string())))
}

#[cfg(test)]
#[path = "library_tests.rs"]
mod tests;

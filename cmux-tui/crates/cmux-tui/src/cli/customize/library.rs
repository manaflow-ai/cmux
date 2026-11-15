//! `cmux customize library`: everything you applied, kept as entries you
//! turn on and off and stack in order; shared as one file or one link.
//! The model is `cmux_customize::library`; this is its grammar and words.

use std::io::{Read, Write};

use base64::Engine;
use cmux_customize::library::{Changed, Collection, Listing, Position, Recovered};
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
        /// One line kept as a code entry's note.
        reason: Option<String>,
    },
    /// Every code entry off, `reason` the note of each one that was
    /// on: what the app runs when a layer's pages fail to load.
    OffCode {
        reason: Option<String>,
    },
    /// Every entry off, back to what was there before any layer (`off --all`,
    /// `reset`).
    OffAll,
    /// The entries that are on, in the one line a bug report carries.
    Status,
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
    /// Every code entry against what is published (a folder: built again)
    /// and this build.
    Refresh,
}

const USAGE: &str = "customize library takes list, status, refresh, on NAME, off NAME [--reason TEXT], off --code [--reason TEXT], off --all, reset, order NAME top|bottom|N, remove NAME, export [FILE] [--link] [--on] [--name NAME], import FILE|LINK|- [--on]";

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
        "status" if rest.is_empty() => Ok(Request::Status),
        "reset" if rest.is_empty() => Ok(Request::OffAll),
        "on" | "enable" => Ok(Request::On { name: name(rest, "on")? }),
        "off" | "disable" => parse_off(rest),
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

/// `off NAME [--reason TEXT]`, `off --code [--reason TEXT]`, `off --all`.
fn parse_off(rest: &[String]) -> Result<Request, String> {
    const OFF_USAGE: &str =
        "customize library off takes NAME [--reason TEXT], --code [--reason TEXT] or --all";
    let (mut name, mut all, mut code, mut reason) = (None, false, false, None);
    let mut iter = rest.iter();
    while let Some(word) = iter.next() {
        match word.as_str() {
            "--all" => all = true,
            "--code" => code = true,
            "--reason" => {
                reason = Some(iter.next().cloned().ok_or("--reason needs one line of text")?);
            }
            flag if flag.starts_with("--reason=") => {
                reason = flag.strip_prefix("--reason=").map(str::to_owned);
            }
            flag if flag.starts_with('-') => {
                return Err(format!("customize library off does not take {flag:?}; {OFF_USAGE}"));
            }
            _ if name.is_none() => name = Some(word.clone()),
            _ => return Err(OFF_USAGE.to_owned()),
        }
    }
    match (name, all, code) {
        (Some(name), false, false) => Ok(Request::Off { name, reason }),
        (None, false, true) => Ok(Request::OffCode { reason }),
        (None, true, false) if reason.is_none() => Ok(Request::OffAll),
        _ => Err(OFF_USAGE.to_owned()),
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
            let mut human = list_lines(&listing);
            // An overlay put there by hand is no entry, but it is what the
            // app shows (or refuses): say so beside "empty".
            if let Some(words) = customize
                .overlay(super::app_web_abi(None))
                .filter(|overlay| !overlay.library)
                .and_then(|overlay| overlay.words(now_ms))
            {
                human.push_str(&format!(
                    "Not in the library: {words} (`cmux customize library status`)\n"
                ));
            }
            Answer::Library { json: json!({ "library": listing }), human }
        }
        Request::Refresh => super::pr::refresh(customize, origin, now_ms)?,
        Request::On { name } => changed(customize.library_set_on(&name, true, origin, now_ms)?),
        Request::Off { name, reason: Some(reason) }
            if customize
                .library()?
                .entries
                .iter()
                .any(|entry| entry.name == name && entry.code.is_some()) =>
        {
            changed(customize.library_settle_code(&name, &reason, Some(false), origin, now_ms)?)
        }
        Request::Off { name, .. } => {
            changed(customize.library_set_on(&name, false, origin, now_ms)?)
        }
        Request::OffCode { reason } => {
            recovered(customize.library_off_code(reason.as_deref(), origin, now_ms)?)
        }
        Request::OffAll => recovered(customize.library_off_all(origin, now_ms)?),
        Request::Status => {
            let layers = customize.layers_at(super::app_web_abi(None), now_ms);
            let mut human = format!("{}\n", layers.line);
            for layer in &layers.on {
                human.push_str(&format!("  {} ({})", layer.name, layer.kind));
                if let (Some(source), Some(head)) = (&layer.source, &layer.head) {
                    human.push_str(&format!(
                        " {source} @{head}{}",
                        if layer.web { ", serving web" } else { "" }
                    ));
                }
                if !layer.note.is_empty() {
                    human.push_str(&format!(": {}", layer.note));
                }
                human.push('\n');
            }
            if let Some(overlay) = &layers.overlay {
                human.push_str(&format!("  web-dev.json overlay: {overlay}\n"));
            }
            if let Some(web_dev) = layers.web_dev.as_ref().filter(|web_dev| !web_dev.library) {
                human.push_str(
                    "  it is not a library entry: put there by hand (web-overlay.sh install)\n",
                );
                if web_dev.refused {
                    human.push_str("  the app refuses it and shows its own pages instead\n");
                }
                human.push_str(
                    "  scripts/cmux-next/web-overlay.sh off   back to the app's own pages\n",
                );
            }
            if layers.problem.is_some() || layers.stray_overlay || !layers.on.is_empty() {
                human.push_str("  cmux customize library off --code   every code layer off\n");
                human.push_str(
                    "  cmux customize library reset        everything back to before any layer\n",
                );
            }
            Answer::Library { json: json!({ "layers": layers }), human }
        }
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

fn recovered(recovered: Recovered) -> Answer {
    let mut human = String::new();
    if recovered.turned_off.is_empty() {
        human.push_str("nothing was on to turn off\n");
    } else {
        human.push_str(&format!("turned off: {}\n", recovered.turned_off.join(", ")));
    }
    for note in &recovered.notes {
        human.push_str(&format!("  {note}\n"));
    }
    match &recovered.overlay {
        Some(overlay) => human.push_str(&format!("web-dev.json overlay: {overlay}\n")),
        None => human.push_str("web-dev.json has no overlay: cmux serves its own pages\n"),
    }
    if let Some(change) = &recovered.change {
        human.push_str(&change_lines(change));
    }
    let complete = recovered.complete;
    Answer::Recovery { json: json!(recovered), human, complete }
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
                    "web layer of {} at {}",
                    code.source_label(),
                    code.head.get(..12).unwrap_or(&code.head)
                )
            } else {
                format!("{}: nothing a running cmux can take", code.source_label())
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
        "  cmux customize library reset              all off: back to before any of them\n",
    );
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
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn library_words_parse() {
        assert_eq!(parse(&[]).unwrap(), Request::List);
        assert_eq!(parse(&words("ls")).unwrap(), Request::List);
        assert_eq!(parse(&words("on roomy")).unwrap(), Request::On { name: "roomy".into() });
        assert_eq!(
            parse(&words("off roomy")).unwrap(),
            Request::Off { name: "roomy".into(), reason: None }
        );
        assert_eq!(
            parse(&words("order roomy 2")).unwrap(),
            Request::Order { name: "roomy".into(), position: Position::At(2) }
        );
        assert_eq!(
            parse(&words("order roomy top")).unwrap(),
            Request::Order { name: "roomy".into(), position: Position::Top }
        );
        assert_eq!(
            parse(&words("export set.json --link --on --name mine")).unwrap(),
            Request::Export {
                file: Some("set.json".into()),
                link: true,
                only_on: true,
                name: Some("mine".into())
            }
        );
        assert_eq!(
            parse(&words("import - --on")).unwrap(),
            Request::Import { source: "-".into(), on: true }
        );
        for bad in ["on", "on -x", "order roomy 0", "order roomy", "import", "frob", "export a b"] {
            assert!(parse(&words(bad)).is_err(), "{bad}");
        }
    }

    /// The recovery words, exactly as the app calls them when a layer's
    /// pages fail to load: `off --code --reason "<one line>"`.
    #[test]
    fn recovery_words_parse() {
        let reason = |text: &str| Some(text.to_owned());
        let app_call: Vec<String> =
            ["off", "--code", "--reason", "pages did not load: timeout after 10 s"]
                .iter()
                .map(|word| (*word).to_owned())
                .collect();
        assert_eq!(
            parse(&app_call).unwrap(),
            Request::OffCode { reason: reason("pages did not load: timeout after 10 s") }
        );
        assert_eq!(parse(&words("off --code")).unwrap(), Request::OffCode { reason: None });
        assert_eq!(
            parse(&words("off --reason=gone --code")).unwrap(),
            Request::OffCode { reason: reason("gone") }
        );
        assert_eq!(
            parse(&words("off pr-43496 --reason broke")).unwrap(),
            Request::Off { name: "pr-43496".into(), reason: reason("broke") }
        );
        assert_eq!(parse(&words("off --all")).unwrap(), Request::OffAll);
        assert_eq!(parse(&words("reset")).unwrap(), Request::OffAll);
        assert_eq!(parse(&words("status")).unwrap(), Request::Status);
        for bad in [
            "off",
            "off --all --code",
            "off --all --reason x",
            "off a b",
            "off a --all",
            "off --code --reason",
            "off --frob",
            "reset now",
        ] {
            assert!(parse(&words(bad)).is_err(), "{bad}");
        }
    }

    /// `off --code` and `reset` work with no app and a library that does not
    /// read, and say through the exit code that the base was lost.
    #[test]
    fn recovery_runs_with_a_broken_library_and_exits_1_when_not_complete() {
        use cmux_customize::Roots;
        let dir = tempfile::tempdir().unwrap();
        let customize = Customize::open(Roots::under(dir.path()));
        let answer = execute(&customize, Request::OffCode { reason: None }, "cli", 1).unwrap();
        assert_eq!(answer.exit(), 0, "nothing on is a clean recovery");
        assert!(answer.json()["complete"].as_bool().unwrap());

        std::fs::create_dir_all(dir.path().join("state")).unwrap();
        std::fs::write(dir.path().join("state/library.json"), "{ cut short").unwrap();
        let answer = execute(&customize, Request::OffAll, "cli", 2).unwrap();
        assert_eq!(answer.exit(), 1);
        let human = answer.human(2);
        assert!(human.contains("library.json.unreadable-2"), "{human}");
        assert!(human.contains("cmux serves its own pages"), "{human}");
        let status = execute(&customize, Request::Status, "cli", 3).unwrap();
        assert_eq!(status.json()["layers"]["line"], "customize: 0 on");
    }

    #[test]
    fn a_link_carries_the_collection_and_a_damaged_one_is_refused() {
        let text = "{\"cmuxCollection\":1,\"entries\":[]}\n";
        let link = to_link(text).unwrap();
        assert!(link.starts_with(LINK_PREFIX));
        assert_eq!(from_link(link.strip_prefix(LINK_PREFIX).unwrap()).unwrap(), text);
        assert!(from_link("not base64 at all!").is_err());
        assert!(from_link("AAAA").is_err());
    }
}

//! `cmux customize library`: everything you applied, kept as entries you
//! turn on and off and stack in order; shared as one file or one link.
//! The model is `cmux_customize::library`; this is its grammar and words.

use std::collections::BTreeSet;
use std::io::{Read, Write};

use base64::Engine;
use cmux_customize::library::expire::{self, Expired, Expiring, Expiry};
use cmux_customize::library::{Changed, Collection, Listing, NoLongerApplies, Position, Recovered};
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
    /// Every layer past its bound off: a PR merged or closed, a code layer
    /// on longer than 24 hours, a hand-installed overlay as old (the app
    /// runs it at launch).
    Expire,
}

const USAGE: &str = "customize library takes list, status, refresh, expire, on NAME, off NAME [--reason TEXT], off --code [--reason TEXT], off --all, reset, order NAME top|bottom|N, remove NAME, export [FILE] [--link] [--on] [--name NAME], import FILE|LINK|- [--on]";

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
        "expire" if rest.is_empty() => Ok(Request::Expire),
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
    // Every read first turns off what is past its bound, so a person or an
    // agent never reads a layer as on that should have expired.
    let expiring = match request {
        Request::List | Request::Status => Some(expire_by_age(customize, origin, now_ms)),
        _ => None,
    };
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
            human.push_str(&expired_lines(&customize.expired(now_ms), expiring.as_ref()));
            Answer::Library { json: json!({ "library": listing }), human }
        }
        Request::Refresh => {
            with_no_longer_applies(customize, super::pr::refresh(customize, origin, now_ms)?)
        }
        Request::Expire => super::expire::run(customize, origin, now_ms)?,
        Request::On { name } if name == expire::WEB_DEV_OVERLAY => {
            let path = customize.renew_overlay(now_ms)?;
            Answer::Library {
                json: json!({ "renewed": expire::WEB_DEV_OVERLAY, "overlay": path }),
                human: format!(
                    "the web-dev.json overlay is on again ({path}) for another {} hours; open pages reload onto it\n",
                    expire::MAX_AGE_MS / 3_600_000
                ),
            }
        }
        Request::On { name } => {
            let before = views_scopes(customize);
            let mut answer = changed(customize.library_set_on(&name, true, origin, now_ms)?);
            waiting(&mut answer, &before, &views_scopes(customize));
            answer
        }
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
            human.push_str(&expired_lines(&layers.expired, expiring.as_ref()));
            with_no_longer_applies(
                customize,
                Answer::Library { json: json!({ "layers": layers }), human },
            )
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
            let before = views_scopes(customize);
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
            let mut answer = Answer::Library { json: json!(imported), human };
            waiting(&mut answer, &before, &views_scopes(customize));
            answer
        }
    })
}

/// `answer` with one line for each entry that is on with keys this app no
/// longer reads as written (`no_longer_apply` in its JSON); unchanged when
/// everything applies. Only says: nothing is turned off or rewritten.
fn with_no_longer_applies(customize: &Customize, answer: Answer) -> Answer {
    let stale = customize.library_no_longer_applies();
    no_longer_applies_into(answer, &stale)
}

fn no_longer_applies_into(answer: Answer, stale: &[NoLongerApplies]) -> Answer {
    match answer {
        Answer::Library { mut json, mut human } if !stale.is_empty() => {
            for entry in stale {
                human.push_str(&entry.line());
                human.push('\n');
            }
            if let Some(object) = json.as_object_mut() {
                object.insert("no_longer_apply".to_owned(), json!(stale));
            }
            Answer::Library { json, human }
        }
        other => other,
    }
}

/// The scopes the customize folder's views app asks for (`scopes` in its
/// manifest, picked as the app's catalog picks it: `cmux-app.json`, else
/// `cmux-app.v2.json`); empty when there is none.
fn views_scopes(customize: &Customize) -> BTreeSet<String> {
    let dir = &customize.roots().customize_dir;
    ["cmux-app.json", "cmux-app.v2.json"]
        .iter()
        .map(|name| dir.join(name))
        .find(|path| path.is_file())
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|manifest| {
            manifest.get("scopes")?.as_object().map(|o| o.keys().cloned().collect())
        })
        .unwrap_or_default()
}

/// The scopes past reading that the views now ask for and did not before. cmux
/// grants the views' read scopes by itself; these wait for the person, who
/// allows each one on a card.
fn widened(before: &BTreeSet<String>, after: &BTreeSet<String>) -> Vec<String> {
    after.difference(before).filter(|scope| !scope.ends_with(":read")).cloned().collect()
}

/// Says which new scopes wait for the person's approval, and where they give it.
fn waiting(answer: &mut Answer, before: &BTreeSet<String>, after: &BTreeSet<String>) {
    let scopes = widened(before, after);
    if scopes.is_empty() {
        return;
    }
    if let Answer::Library { json, human } = answer {
        if let Some(object) = json.as_object_mut() {
            object.insert("waiting_scopes".into(), json!(scopes));
        }
        human.push_str(&format!(
            "your views now ask for {}: cmux does not grant {} until you allow {} (App Store, Installed, local/customize; a card asks you first)\n",
            scopes.join(", "),
            if scopes.len() == 1 { "it" } else { "them" },
            if scopes.len() == 1 { "it" } else { "each one" },
        ));
    }
}

/// The age-only expiry every read runs first (no network: `library expire`
/// also asks GitHub which PRs merged or closed).
fn expire_by_age(customize: &Customize, origin: &str, now_ms: u64) -> Expiring {
    let expiry = Expiry { now_ms, app_abi: super::app_web_abi(None), ..Expiry::default() };
    customize.expire_stale(&expiry, origin)
}

/// What expired, each with its way back, and what could not be turned off.
pub(super) fn expired_lines(expired: &[Expired], now: Option<&Expiring>) -> String {
    let mut out = String::new();
    for expired in expired {
        out.push_str(&format!(
            "  expired: {} ({}); back: {}\n",
            expired.name, expired.why, expired.back
        ));
    }
    for problem in now.map(|now| now.problems.as_slice()).unwrap_or_default() {
        out.push_str(&format!("  not expired: {problem}\n"));
    }
    out
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
            let web = cmux_customize::library::WEB_KEY;
            let serving = change.library.entries.iter().find(|entry| {
                entry.on
                    && entry.code.as_ref().is_some_and(|code| code.has_web())
                    && !entry.overridden.iter().any(|key| key == web)
            });
            out.push_str(&match serving {
                Some(entry) => {
                    format!("web pages now load from {}; open pages reload\n", entry.name)
                }
                None => "no code layer is on: web pages are as they were before any; open pages reload\n"
                    .to_owned(),
            });
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
                let base = match code.base.get(..12) {
                    Some(base) => format!(" on {base}"),
                    None => String::new(),
                };
                format!(
                    "web layer of {} at {}{base}",
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
        if let Some(until) = entry.until_ms {
            let left = until.saturating_sub(super::now_ms());
            what.push(format!("trying it on: off by itself in {}", expire::minutes(left)));
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
#[path = "library_tests.rs"]
mod tests;

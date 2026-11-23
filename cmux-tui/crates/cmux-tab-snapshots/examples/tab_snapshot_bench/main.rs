//! A deterministic simulation of the `tabs` service over a modeled link, in
//! virtual time. Bytes come from the real encoder, producer, session and
//! mirror; times come from a link model (round trip, bandwidth, 16 KiB link
//! writes with a 9-byte header each), not from a radio. The model does not
//! compress.
//!
//! cargo run -p cmux-tab-snapshots --example tab_snapshot_bench -- \
//!     [--tabs N] [--favicons-distinct D] [--terminal-every K] \
//!     [--thumbs DIR] [--favicons DIR]
//!
//! Prints one JSON line per scenario and link, plus the assumptions, the
//! per-tab byte cost by part and the baseline ratios.

mod link;
mod workload;

use cmux_tab_snapshots::wire::encode_blob;
use cmux_tab_snapshots::{
    BlobHash, Kind, Manifest, Message, Mirror, Producer, Row, Session, Viewport,
};
use link::{
    Drop, FIRST_SCREENFUL, LINK_HEADER_PER_WRITE, LINK_PAYLOAD_PER_WRITE, LINKS, Link, Outcome,
    Pipe, simulate, simulate_until,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::error::Error;
use std::path::Path;
use workload::*;

type Res<T> = Result<T, Box<dyn Error>>;

fn viewport() -> Vec<u8> {
    Message::Viewport(Viewport {
        card_pixel_width: ASSUMED_THUMB_W,
        card_aspect: 0.75,
        display_scale: 3.0,
        screen_pixel_w: 1179,
        screen_pixel_h: 2556,
    })
    .encode()
}

fn link_up(mirror: &Mirror) -> Vec<Vec<u8>> {
    let mut frames = mirror.link_up_frames();
    frames.push(viewport());
    frames
}

fn card_blob_sizes(producer: &Producer, row: &Row) -> Vec<(BlobHash, usize)> {
    [row.favicon_hash, row.thumb_hash, row.screen_hash]
        .into_iter()
        .flatten()
        .filter_map(|h| producer.store().get(&h).map(|b| (h, b.bytes.len())))
        .collect()
}

/// Blob bytes the phone did not receive for `rows`: sharing within them
/// (dedupe) and blobs it already held from an earlier launch (cache).
/// Blobs in `earlier` (held before this scenario's change) are not counted.
fn savings(
    producer: &Producer,
    rows: &[&Row],
    sent: usize,
    earlier: &HashSet<BlobHash>,
) -> (usize, usize) {
    let mut refs = 0;
    let mut distinct = BTreeMap::new();
    for row in rows {
        for (h, len) in card_blob_sizes(producer, row) {
            if earlier.contains(&h) {
                continue;
            }
            refs += len;
            distinct.insert(h, len);
        }
    }
    let distinct: usize = distinct.values().sum();
    (refs - distinct, distinct.saturating_sub(sent))
}

fn ms(t: Option<f64>) -> Value {
    t.map_or(Value::Null, |us| json!((us / 10.0).round() / 100.0))
}

fn report(scenario: &str, link: &Link, out: &Outcome, saved: (usize, usize)) -> Value {
    json!({
        "scenario": scenario,
        "link": link.name,
        "bytesDown": out.down.bytes,
        "bytesUp": out.up.bytes,
        "framesDown": out.down.frames,
        "framesUp": out.up.frames,
        "linkWritesDown": out.down.writes,
        "blobBytesDown": out.blob_bytes,
        "resentBlobBytes": out.resent_blob_bytes,
        "manifestMs": ms(out.marks.rows),
        "firstCardMs": ms(out.marks.first_card),
        "firstScreenMs": ms(out.marks.first_screen),
        "allWantedMs": ms(out.marks.all),
        "dedupeSavedBytes": saved.0,
        "cacheSavedBytes": saved.1,
    })
}

/// No manifest, no dedupe, no cache: on every open each card's row and
/// every image it shows are sent in full, card after card.
fn baseline(link: &Link, producer: &Producer) -> Value {
    let mut up = Pipe::new(link.up_bps, link.rtt_ms);
    let mut down = Pipe::new(link.down_bps, link.rtt_ms);
    let (_, hello_at) = up.send(0.0, viewport().len());
    let mut card_done = Vec::new();
    let mut titles_at = hello_at;
    let mut blob_bytes = 0;
    for row in producer.rows() {
        let row_frame =
            Message::Manifest(Manifest { epoch: String::new(), rev: 0, rows: vec![row.clone()] })
                .encode();
        let (_, mut at) = down.send(hello_at, row_frame.len());
        titles_at = at;
        for (h, len) in card_blob_sizes(producer, row) {
            let frame = producer.store().get(&h).map(|b| encode_blob(h, b.mime, &b.bytes));
            blob_bytes += len;
            at = down.send(hello_at, frame.map_or(len, |f| f.len())).1;
        }
        card_done.push(at);
    }
    let first_screen = card_done
        .iter()
        .take(FIRST_SCREENFUL)
        .copied()
        .fold(None, |m: Option<f64>, t| Some(m.map_or(t, |m| m.max(t))));
    json!({
        "scenario": "e_baseline_send_everything",
        "link": link.name,
        "bytesDown": down.bytes,
        "bytesUp": up.bytes,
        "framesDown": down.frames,
        "framesUp": up.frames,
        "linkWritesDown": down.writes,
        "blobBytesDown": blob_bytes,
        "resentBlobBytes": 0,
        "manifestMs": ms(Some(titles_at)),
        "firstCardMs": ms(card_done.first().copied()),
        "firstScreenMs": ms(first_screen),
        "allWantedMs": ms(card_done.last().copied()),
        "dedupeSavedBytes": 0,
        "cacheSavedBytes": 0,
    })
}

fn per_tab_costs(w: &Workload, producer: &Producer) -> Value {
    let mut browser_rows = Vec::new();
    let mut terminal_rows = Vec::new();
    for row in producer.rows() {
        let len = serde_json::to_vec(row).map_or(0, |v| v.len());
        match row.kind {
            Kind::Terminal => terminal_rows.push(len),
            _ => browser_rows.push(len),
        }
    }
    let avg = |v: &[usize]| if v.is_empty() { 0 } else { v.iter().sum::<usize>() / v.len() };
    let part = |f: fn(&Row) -> Option<BlobHash>| {
        let sizes: Vec<usize> = producer
            .rows()
            .iter()
            .filter_map(f)
            .filter_map(|h| producer.store().get(&h).map(|b| b.bytes.len()))
            .collect();
        avg(&sizes)
    };
    json!({
        "kind": "per_tab_bytes",
        "manifestRowJsonBrowser": avg(&browser_rows),
        "manifestRowJsonTerminal": avg(&terminal_rows),
        "favicon": part(|r| r.favicon_hash),
        "faviconAssumed": w.favicons.is_none(),
        "thumbnail": part(|r| r.thumb_hash),
        "thumbnailAssumed": w.thumbs.is_none(),
        "terminalScreenText": part(|r| r.screen_hash),
        "terminalScreenTextGenerated": true,
        "blobFrameHeader": cmux_tab_snapshots::wire::BLOB_HEADER_LEN,
    })
}

fn args() -> Res<Workload> {
    let mut w = Workload {
        tabs: 12,
        favicons_distinct: 5,
        terminal_every: 3,
        thumbs: None,
        favicons: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--tabs" => w.tabs = value()?.parse()?,
            "--favicons-distinct" => w.favicons_distinct = value()?.parse()?,
            "--terminal-every" => w.terminal_every = value()?.parse()?,
            "--thumbs" => w.thumbs = Some(read_dir_files(Path::new(&value()?))?),
            "--favicons" => w.favicons = Some(read_dir_files(Path::new(&value()?))?),
            other => return Err(format!("unknown flag {other}").into()),
        }
    }
    Ok(w)
}

#[derive(Clone, Copy)]
enum SessionMode {
    /// [`Session::without_push`]: blobs move only after the phone's `want`.
    Want,
    /// [`Session::new`], the default: blobs move right after the manifest.
    Push,
}

impl SessionMode {
    fn name(self) -> &'static str {
        match self {
            Self::Want => "want",
            Self::Push => "push",
        }
    }

    fn session(self) -> Session {
        match self {
            Self::Want => Session::without_push(),
            Self::Push => Session::new(),
        }
    }
}

/// Scenarios a to d and f on one link; prints each and returns bytes down.
fn scenarios(w: &Workload, link: &Link, mode: SessionMode) -> Res<[usize; 5]> {
    let line = |name: &str, out: &Outcome, saved| {
        let mut v = report(name, link, out, saved);
        v["session"] = json!(mode.name());
        print(&v);
        out.down.bytes
    };
    let none = HashSet::new();

    // a. Cold open, empty phone cache.
    let producer = w.producer();
    let all_rows: Vec<&Row> = producer.rows().iter().collect();
    let mut phone = Mirror::new();
    let up = link_up(&phone);
    let cold = simulate(link, &producer, &mut mode.session(), &mut phone, up)?;
    let a = line("a_cold_open", &cold, savings(&producer, &all_rows, cold.blob_bytes, &none));

    // b. Warm open: the phone relaunches with its blob cache and sends `have`.
    let mut warm_phone = Mirror::new();
    warm_phone.import_held(phone.export_held());
    let up = link_up(&warm_phone);
    let warm = simulate(link, &producer, &mut mode.session(), &mut warm_phone, up)?;
    let b = line("b_warm_open", &warm, savings(&producer, &all_rows, warm.blob_bytes, &none));

    // c. The first card's thumbnail changes while connected.
    let mut producer_c = w.producer();
    let mut phone_c = Mirror::new();
    let mut session_c = mode.session();
    let up = link_up(&phone_c);
    simulate(link, &producer_c, &mut session_c, &mut phone_c, up)?;
    let before: HashSet<BlobHash> = phone_c.export_held().into_iter().collect();
    producer_c.observe(w.observe(0, 1));
    let one = simulate(link, &producer_c, &mut session_c, &mut phone_c, Vec::new())?;
    let rows_c: Vec<&Row> = producer_c.rows().iter().take(1).collect();
    let c =
        line("c_one_thumb_changed", &one, savings(&producer_c, &rows_c, one.blob_bytes, &before));

    // d. The link drops, three tabs change, the phone resumes by rev.
    let changed = [1, 4, 7];
    let mut producer_d = w.producer();
    let mut phone_d = Mirror::new();
    let up = link_up(&phone_d);
    simulate(link, &producer_d, &mut mode.session(), &mut phone_d, up)?;
    let before: HashSet<BlobHash> = phone_d.export_held().into_iter().collect();
    for &i in changed.iter().filter(|&&i| i < w.tabs) {
        producer_d.observe(w.observe(i, 1));
    }
    let up = link_up(&phone_d);
    let resumed = simulate(link, &producer_d, &mut mode.session(), &mut phone_d, up)?;
    let rows_d: Vec<&Row> = changed.iter().filter_map(|&i| producer_d.rows().get(i)).collect();
    let d = line(
        "d_reconnect_resume",
        &resumed,
        savings(&producer_d, &rows_d, resumed.blob_bytes, &before),
    );

    // f. Cold open on a link that drops once the first 6 cards are filled;
    // the phone reconnects with `have` and `resume` and fills the rest.
    let producer_f = w.producer();
    let mut phone_f = Mirror::new();
    let up = link_up(&phone_f);
    let mut session_f = mode.session();
    let dropped = simulate_until(
        link,
        &producer_f,
        &mut session_f,
        &mut phone_f,
        up,
        Drop::AfterFirstScreen,
    )?;
    let held: HashSet<BlobHash> = phone_f.export_held().into_iter().collect();
    let mut first = report("f_drop_after_first_screen", link, &dropped, (0, 0));
    first["session"] = json!(mode.name());
    first["leg"] = json!("before_drop");
    first["blobsHeldAtDrop"] = json!(held.len());
    print(&first);
    let up = link_up(&phone_f);
    let again = simulate(link, &producer_f, &mut mode.session(), &mut phone_f, up)?;
    let mut second = report(
        "f_drop_after_first_screen",
        link,
        &again,
        savings(&producer_f, &all_rows_of(&producer_f), again.blob_bytes, &none),
    );
    second["session"] = json!(mode.name());
    second["leg"] = json!("reconnect_have_resume");
    second["allCardsFilled"] = json!(phone_f.missing().is_empty());
    print(&second);
    let f = dropped.down.bytes + again.down.bytes;
    Ok([a, b, c, d, f])
}

fn all_rows_of(producer: &Producer) -> Vec<&Row> {
    producer.rows().iter().collect()
}

fn print(v: &Value) {
    println!("{v}");
}

fn main() -> Res<()> {
    let w = args()?;
    let terminals = (0..w.tabs).filter(|&i| w.is_terminal(i)).count();
    print(&json!({
        "kind": "assumptions",
        "tabs": w.tabs,
        "browserTabs": w.tabs - terminals,
        "terminalTabs": terminals,
        "distinctFavicons": w.favicons_distinct.min(w.tabs - terminals),
        "links": LINKS.iter().map(|l| json!({
            "link": l.name, "rttMs": l.rtt_ms, "downBitPerS": l.down_bps, "upBitPerS": l.up_bps,
            "payloadPerWrite": LINK_PAYLOAD_PER_WRITE, "headerPerWrite": LINK_HEADER_PER_WRITE,
            "assumed": true,
        })).collect::<Vec<_>>(),
        "thumbBytes": if w.thumbs.is_some() { json!("real files") } else { json!(ASSUMED_THUMB_BYTES) },
        "thumbSizeAssumed": w.thumbs.is_none(),
        "faviconBytes": if w.favicons.is_some() { json!("real files") } else { json!(ASSUMED_FAVICON_BYTES) },
        "faviconSizeAssumed": w.favicons.is_none(),
        "screen": format!("{SCREEN_COLS}x{SCREEN_ROWS} generated text"),
        "compression": false,
        "times": "computed from the link model, not measured on a radio",
    }));
    print(&per_tab_costs(&w, &w.producer()));
    for link in &LINKS {
        let base = baseline(link, &w.producer());
        let base_bytes = base["bytesDown"].as_f64().unwrap_or(0.0);
        let ratio = |b: usize| {
            if b == 0 {
                Value::Null
            } else {
                json!((base_bytes / b as f64 * 100.0).round() / 100.0)
            }
        };
        for mode in [SessionMode::Want, SessionMode::Push] {
            let [cold, warm, one, resumed, dropped] = scenarios(&w, link, mode)?;
            print(&json!({
                "kind": "baseline_ratio",
                "link": link.name,
                "session": mode.name(),
                "baselineBytesDown": base_bytes,
                "baselineOverColdOpen": ratio(cold),
                "baselineOverWarmOpen": ratio(warm),
                "baselineOverOneThumbChanged": ratio(one),
                "baselineOverReconnectResume": ratio(resumed),
                "baselineOverDropAndReconnect": ratio(dropped),
            }));
        }
        print(&base);
    }
    Ok(())
}

//! `session-pack`: pack a session's log, read ranges of it back, move it between stores.

use cmux_session_pack::{
    Manifest, Pack, Params, RangeId, Result, Store, digest, hex, pack, ship, unhex,
};
use std::collections::HashSet;
use std::io::Write as _;
use std::path::PathBuf;

const USAGE: &str = "session-pack: a session's event log as content-addressed zstd segments

  session-pack pack NAME FILE...        pack the log (FILEs back to back); again later: only what was appended
               [--full] [--segment-bytes N] [--blob-min N] [--level N]
  session-pack stat NAME                sizes, segments, turns
  session-pack outline NAME             one line a turn: its range name, start (ms), records, what was asked
  session-pack range NAME@FIRST-LAST    those lines (both included): what a compaction summary points at
               [--digest]               as text for an agent: prompts, replies, tool calls, the start of each result
  session-pack tail NAME --turns N      the last N turns (--lines N: the last N lines)
  session-pack turns NAME               each turn's range name
  session-pack seq NAME SEQ             the acpmux record with that seq (one tool result)
  session-pack blob NAME N              blob N
  session-pack cat NAME                 the whole log, byte for byte
  session-pack verify NAME              read everything back against its hashes
  session-pack have [NAME]              chunk ids this store holds (of NAME only, when given)
  session-pack bundle NAME [--have FILE] -o OUT   NAME's manifest and the chunks not listed in FILE
  session-pack unbundle FILE            take a bundle in

The store is --store DIR or $CMUX_SESSION_PACK_STORE.";

struct Args {
    pos: Vec<String>,
    opts: Vec<(String, Option<String>)>,
}

impl Args {
    fn parse() -> Self {
        let flags = ["--full", "--digest", "--help", "-h"];
        let (mut pos, mut opts) = (Vec::new(), Vec::new());
        let mut it = std::env::args().skip(1);
        while let Some(a) = it.next() {
            if flags.contains(&a.as_str()) {
                opts.push((a, None));
            } else if a.starts_with('-') && a.len() > 1 {
                let v = it.next();
                opts.push((a, v));
            } else {
                pos.push(a);
            }
        }
        Self { pos, opts }
    }
    fn flag(&self, name: &str) -> bool {
        self.opts.iter().any(|(k, _)| k == name)
    }
    fn opt(&self, name: &str) -> Option<&str> {
        self.opts.iter().find(|(k, _)| k == name).and_then(|(_, v)| v.as_deref())
    }
    fn num<T: std::str::FromStr>(&self, name: &str) -> Result<Option<T>> {
        self.opt(name)
            .map(|v| v.parse().map_err(|_| format!("{name} {v}: not a number").into()))
            .transpose()
    }
    fn at(&self, i: usize) -> Result<&str> {
        self.pos.get(i).map(String::as_str).ok_or_else(|| USAGE.into())
    }
}

fn write_lines(pack: &Pack, range: std::ops::Range<u64>) -> Result<()> {
    let mut out = std::io::stdout().lock();
    pack.write_range(range, &mut out)?;
    Ok(out.flush()?)
}

fn run() -> Result<()> {
    let args = Args::parse();
    if args.pos.is_empty() || args.flag("--help") || args.flag("-h") {
        println!("{USAGE}");
        return Ok(());
    }
    let root = args
        .opt("--store")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("CMUX_SESSION_PACK_STORE").map(PathBuf::from))
        .ok_or("no store: pass --store DIR or set CMUX_SESSION_PACK_STORE")?;
    let store = Store::new(root);
    match args.at(0)? {
        "pack" => {
            let mut params = Params::default();
            if let Some(n) = args.num("--segment-bytes")? {
                params.segment_bytes = n;
            }
            if let Some(n) = args.num("--blob-min")? {
                params.blob_min = n;
            }
            if let Some(n) = args.num("--level")? {
                params.level = n;
            }
            let files: Vec<PathBuf> = args.pos[2..].iter().map(PathBuf::from).collect();
            if files.is_empty() {
                return Err(USAGE.into());
            }
            let (m, s) = pack(&store, args.at(1)?, &files, &params, args.flag("--full"))?;
            println!(
                "{{\"name\":\"{}\",\"lines\":{},\"rawBytes\":{},\"storedBytes\":{},\"manifestBytes\":{},\"segments\":{},\"keptSegments\":{},\"encodedBytes\":{},\"newChunks\":{},\"newBytes\":{},\"ratio\":{:.2}}}",
                m.name,
                m.lines,
                s.raw_bytes,
                s.stored_bytes,
                s.manifest_bytes,
                m.segments.len(),
                s.kept_segments,
                s.encoded_bytes,
                s.new_chunks,
                s.new_bytes,
                s.raw_bytes as f64 / (s.stored_bytes + s.manifest_bytes).max(1) as f64
            );
        }
        "stat" => {
            let p = Pack::open(&store, args.at(1)?)?;
            let m = &p.manifest;
            let manifest_bytes = m.to_json()?.len() as u64;
            println!(
                "{}: {} lines, {} turns, {} bytes in {} segments, stored {} + manifest {} ({:.2}x)",
                m.name,
                m.lines,
                m.marks().count(),
                m.raw_bytes,
                m.segments.len(),
                m.stored_bytes(),
                manifest_bytes,
                m.raw_bytes as f64 / (m.stored_bytes() + manifest_bytes).max(1) as f64
            );
        }
        "outline" => {
            print!("{}", digest::outline(&Pack::open(&store, args.at(1)?)?)?);
        }
        "range" if args.flag("--digest") => {
            let r = RangeId::parse(args.at(1)?)?;
            print!(
                "{}",
                digest::digest(&Pack::open(&store, &r.name)?, &r, digest::Limits::default())?
            );
        }
        "range" => {
            let r = RangeId::parse(args.at(1)?)?;
            write_lines(&Pack::open(&store, &r.name)?, r.first..r.last.saturating_add(1))?;
        }
        "tail" => {
            let p = Pack::open(&store, args.at(1)?)?;
            let from = match args.num::<u64>("--lines")? {
                Some(n) => p.manifest.lines.saturating_sub(n),
                None => p.manifest.tail_turns(args.num("--turns")?.unwrap_or(50)),
            };
            write_lines(&p, from..p.manifest.lines)?;
        }
        "turns" => {
            let m = Pack::open(&store, args.at(1)?)?.manifest;
            let starts: Vec<u64> = m.marks().collect();
            for (i, first) in starts.iter().enumerate() {
                let last = starts.get(i + 1).copied().unwrap_or(m.lines) - 1;
                println!("{}", RangeId { name: m.name.clone(), first: *first, last });
            }
        }
        "seq" => {
            let seq = args.at(2)?.parse().map_err(|_| "SEQ is a number")?;
            let (_, line) = Pack::open(&store, args.at(1)?)?
                .by_seq(seq)?
                .ok_or_else(|| format!("no record with seq {seq}"))?;
            let mut out = std::io::stdout().lock();
            out.write_all(&line)?;
            out.write_all(b"\n")?;
        }
        "blob" => {
            let n = args.at(2)?.parse().map_err(|_| "N is a number")?;
            std::io::stdout().lock().write_all(&Pack::open(&store, args.at(1)?)?.blob(n)?)?;
        }
        "cat" => Pack::open(&store, args.at(1)?)?.cat(&mut std::io::stdout().lock())?,
        "verify" => {
            let p = Pack::open(&store, args.at(1)?)?;
            p.verify()?;
            println!("ok: {} lines, {} bytes read back", p.manifest.lines, p.manifest.raw_bytes);
        }
        "have" => {
            let ids = match args.pos.get(1) {
                Some(name) => Manifest::load(&store, name)?
                    .map(|m| m.chunk_ids())
                    .transpose()?
                    .unwrap_or_default(),
                None => store.ids()?,
            };
            let mut out = std::io::stdout().lock();
            for id in ids {
                writeln!(out, "{}", hex(&id))?;
            }
        }
        "bundle" => {
            let mut have = HashSet::new();
            if let Some(f) = args.opt("--have") {
                for l in std::fs::read_to_string(f).map_err(|e| format!("{f}: {e}"))?.lines() {
                    have.insert(unhex(l.trim())?);
                }
            }
            let out = args.opt("-o").ok_or("bundle needs -o OUT")?;
            let mut f = std::io::BufWriter::new(
                std::fs::File::create(out).map_err(|e| format!("{out}: {e}"))?,
            );
            let s = ship::bundle(&store, args.at(1)?, &have, &mut f)?;
            f.flush()?;
            println!(
                "{{\"chunks\":{},\"bytes\":{},\"sessionChunks\":{},\"sessionBytes\":{}}}",
                s.chunks, s.bytes, s.session_chunks, s.session_bytes
            );
        }
        "unbundle" => {
            let path = args.at(1)?;
            let mut f = std::io::BufReader::new(
                std::fs::File::open(path).map_err(|e| format!("{path}: {e}"))?,
            );
            let m = ship::unbundle(&store, &mut f)?;
            println!("ok: {} at {} lines", m.name, m.lines);
        }
        _ => return Err(USAGE.into()),
    }
    Ok(())
}

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("session-pack: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}

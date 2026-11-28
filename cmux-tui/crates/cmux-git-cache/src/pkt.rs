//! pkt-line parsing of an upload-pack request: the want lines of a fetch (protocol v0 and v2).

#[derive(Debug, PartialEq, Eq)]
pub enum Pkt<'a> {
    Data(&'a [u8]),
    Flush,
    Delim,
    End,
}

/// Every pkt-line of `buf`; `None` when it is not a whole pkt-line stream.
pub fn parse(mut buf: &[u8]) -> Option<Vec<Pkt<'_>>> {
    let mut out = Vec::new();
    while !buf.is_empty() {
        let head = buf.get(..4)?;
        if !head.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        let len = usize::from_str_radix(std::str::from_utf8(head).ok()?, 16).ok()?;
        match len {
            0 => out.push(Pkt::Flush),
            1 => out.push(Pkt::Delim),
            2 => out.push(Pkt::End),
            3 => return None,
            n => out.push(Pkt::Data(buf.get(4..n)?)),
        }
        buf = buf.get(len.max(4)..)?;
    }
    Some(out)
}

/// What an upload-pack request asks for.
#[derive(Debug, PartialEq, Eq)]
pub enum Request {
    /// A fetch that names these objects; the cache may answer it.
    Fetch { wants: Vec<String> },
    /// Anything else (`ls-refs`, `want-ref`, a body this parser does not know): upstream.
    Upstream,
}

fn line(data: &[u8]) -> &[u8] {
    data.strip_suffix(b"\n").unwrap_or(data)
}

fn oid(rest: &[u8]) -> Option<String> {
    let end = rest.iter().position(|b| *b == b' ' || *b == 0).unwrap_or(rest.len());
    let id = rest.get(..end)?;
    ((id.len() == 40 || id.len() == 64) && id.iter().all(u8::is_ascii_hexdigit))
        .then(|| String::from_utf8_lossy(id).to_ascii_lowercase())
}

/// Classifies a (decompressed) `git-upload-pack` request body.
pub fn classify(body: &[u8], v2: bool) -> Request {
    let Some(pkts) = parse(body) else { return Request::Upstream };
    let mut wants = Vec::new();
    let mut data = pkts.iter().filter_map(|p| match p {
        Pkt::Data(d) => Some(line(d)),
        _ => None,
    });
    if v2 && data.next() != Some(b"command=fetch".as_slice()) {
        return Request::Upstream;
    }
    for l in data {
        if l.starts_with(b"want-ref ") {
            return Request::Upstream;
        }
        if let Some(rest) = l.strip_prefix(b"want ") {
            match oid(rest) {
                Some(id) => wants.push(id),
                None => return Request::Upstream,
            }
        }
    }
    if wants.is_empty() { Request::Upstream } else { Request::Fetch { wants } }
}

/// Whether upload-pack's answer to this fetch ends in a sideband-multiplexed pack: the request
/// says `done` (so a pack follows, not a negotiation round), and it is protocol v2 (whose
/// `packfile` section is always multiplexed) or a v0 request whose first want asks for
/// `side-band` or `side-band-64k`. Only then may a progress line go before the final flush.
pub fn sideband_pack(body: &[u8], v2: bool) -> bool {
    let Some(pkts) = parse(body) else { return false };
    let lines: Vec<&[u8]> = pkts
        .iter()
        .filter_map(|p| match p {
            Pkt::Data(d) => Some(line(d)),
            _ => None,
        })
        .collect();
    let done = lines.contains(&b"done".as_slice());
    let sideband = v2
        || lines.iter().find(|l| l.starts_with(b"want ")).is_some_and(|l| {
            l.split(|b| *b == b' ' || *b == 0)
                .any(|cap| cap == b"side-band" || cap == b"side-band-64k")
        });
    done && sideband
}

/// Whether this fetch is a whole clone whose answer the mirror may keep: a pack follows on the
/// sideband (`sideband_pack`), and nothing makes it less than the full closure of its wants (no
/// `have`, `shallow`, `deepen*` or `filter` line). Only such a pack, written into the mirror,
/// leaves it holding everything a later clone of the same wants needs.
pub fn whole_clone(body: &[u8], v2: bool) -> bool {
    let Some(pkts) = parse(body) else { return false };
    let partial = pkts.iter().any(|p| match p {
        Pkt::Data(d) => {
            let l = line(d);
            l.starts_with(b"have ")
                || l.starts_with(b"shallow ")
                || l.starts_with(b"deepen")
                || l.starts_with(b"filter")
        }
        _ => false,
    });
    !partial && sideband_pack(body, v2)
}

/// Pulls the pack out of an upload-pack answer as it streams by: the pkt-lines before the
/// pack (v0 `NAK`/`ACK`, v2 `acknowledgments`/`shallow-info` and the `packfile` header) are
/// skipped, then band 1 is the pack, band 2 progress and band 3 an error.
#[derive(Default)]
pub struct PackDemux {
    v2: bool,
    pending: Vec<u8>,
    in_pack: bool,
    /// A flush came after pack bytes: the pack is whole on the wire.
    ended: bool,
    pack_bytes: u64,
}

impl PackDemux {
    pub fn new(v2: bool) -> Self {
        Self { v2, ..Self::default() }
    }

    /// The pack bytes in `chunk` (with what an earlier chunk left unfinished), or why this
    /// answer is not a pack the mirror can keep.
    pub fn feed(&mut self, chunk: &[u8]) -> Result<Vec<u8>, String> {
        self.pending.extend_from_slice(chunk);
        let mut out = Vec::new();
        let mut at = 0;
        while let Some(head) = self.pending.get(at..at + 4) {
            let len = std::str::from_utf8(head)
                .ok()
                .filter(|h| h.bytes().all(|b| b.is_ascii_hexdigit()))
                .and_then(|h| usize::from_str_radix(h, 16).ok())
                .ok_or("not a pkt-line stream")?;
            if len < 4 {
                if len == 3 {
                    return Err("bad pkt-line length".to_owned());
                }
                if self.in_pack && len == 0 {
                    self.ended = true;
                }
                at += 4;
                continue;
            }
            let Some(data) = self.pending.get(at + 4..at + len) else { break };
            if !self.in_pack {
                if self.v2 {
                    self.in_pack = line(data) == b"packfile";
                    at += len;
                    continue;
                }
                // v0: the acknowledgments are text; the first band byte starts the pack.
                self.in_pack = matches!(data.first(), Some(1..=3));
            }
            if self.in_pack {
                match data.split_first() {
                    Some((1, pack)) => {
                        self.pack_bytes += pack.len() as u64;
                        out.extend_from_slice(pack);
                    }
                    Some((2, _)) => {}
                    Some((3, msg)) => {
                        return Err(format!(
                            "upstream error: {}",
                            String::from_utf8_lossy(msg).trim()
                        ));
                    }
                    _ => return Err("unknown sideband".to_owned()),
                }
            }
            at += len;
        }
        self.pending.drain(..at);
        Ok(out)
    }

    /// Whether the pack ended with its closing flush and no bytes trail it.
    pub fn whole(&self) -> bool {
        self.ended && self.pending.is_empty() && self.pack_bytes > 0
    }

    pub fn pack_bytes(&self) -> u64 {
        self.pack_bytes
    }
}

/// A sideband progress pkt-line (band 2): git prints it as `remote: <msg>`.
pub fn progress(msg: &str) -> Vec<u8> {
    let mut out = format!("{:04x}", msg.len() + 5).into_bytes();
    out.push(2);
    out.extend_from_slice(msg.as_bytes());
    out
}

/// One pkt-line (tests and the fake upstream).
pub fn encode(data: &str) -> String {
    format!("{:04x}{data}", data.len() + 4)
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "0123456789abcdef0123456789abcdef01234567";
    const B: &str = "89abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn truncated_pkt_lines_are_rejected() {
        let packet = encode("want 0123456789abcdef0123456789abcdef01234567\n");
        for end in 1..packet.len() {
            assert!(parse(packet.as_bytes().get(..end).unwrap()).is_none(), "cut at {end}");
        }
        assert!(parse(packet.as_bytes()).is_some());
        for invalid in [b"0003".as_slice(), b"ffffx", b"xxxx"] {
            assert!(parse(invalid).is_none());
        }
        assert_eq!(parse(b"000000010002"), Some(vec![Pkt::Flush, Pkt::Delim, Pkt::End]));
    }

    #[test]
    fn v2_fetch_wants() {
        let body = format!(
            "{}{}0001{}{}{}0000",
            encode("command=fetch\n"),
            encode("agent=git/2.45\n"),
            encode("thin-pack\n"),
            encode(&format!("want {A}\n")),
            encode(&format!("want {B}\n"))
        );
        assert_eq!(
            classify(body.as_bytes(), true),
            Request::Fetch { wants: vec![A.to_owned(), B.to_owned()] }
        );
    }

    #[test]
    fn v2_ls_refs_and_want_ref_go_upstream() {
        let ls = format!("{}0001{}0000", encode("command=ls-refs\n"), encode("peel\n"));
        assert_eq!(classify(ls.as_bytes(), true), Request::Upstream);
        let wr = format!(
            "{}0001{}{}0000",
            encode("command=fetch\n"),
            encode(&format!("want {A}\n")),
            encode("want-ref refs/heads/main\n")
        );
        assert_eq!(classify(wr.as_bytes(), true), Request::Upstream);
    }

    #[test]
    fn v0_wants_with_capabilities() {
        let body = format!(
            "{}{}0000{}",
            encode(&format!("want {A} multi_ack_detailed side-band-64k agent=git/2.45\n")),
            encode(&format!("want {B}\n")),
            encode("done\n")
        );
        assert_eq!(
            classify(body.as_bytes(), false),
            Request::Fetch { wants: vec![A.to_owned(), B.to_owned()] }
        );
    }

    #[test]
    fn garbage_goes_upstream() {
        assert_eq!(classify(b"zzzz", false), Request::Upstream);
        assert_eq!(classify(b"0009want", false), Request::Upstream);
        assert_eq!(classify(b"", false), Request::Upstream);
        let bad = format!("{}0000", encode("want nothex\n"));
        assert_eq!(classify(bad.as_bytes(), false), Request::Upstream);
    }

    #[test]
    fn sideband_pack_only_when_a_multiplexed_pack_follows() {
        let v2 = format!(
            "{}0001{}{}0000",
            encode("command=fetch\n"),
            encode(&format!("want {A}\n")),
            encode("done\n")
        );
        assert!(sideband_pack(v2.as_bytes(), true));
        let v2_negotiating =
            format!("{}0001{}0000", encode("command=fetch\n"), encode(&format!("want {A}\n")));
        assert!(!sideband_pack(v2_negotiating.as_bytes(), true));
        let v0 = |caps: &str| {
            format!("{}0000{}", encode(&format!("want {A} {caps}\n")), encode("done\n"))
        };
        assert!(sideband_pack(v0("multi_ack side-band-64k ofs-delta").as_bytes(), false));
        assert!(sideband_pack(v0("side-band").as_bytes(), false));
        assert!(!sideband_pack(v0("multi_ack ofs-delta").as_bytes(), false));
        assert_eq!(progress("hi\n"), b"0008\x02hi\n");
    }

    #[test]
    fn whole_clone_only_without_haves_filters_or_depth() {
        let v2 = |extra: &str| {
            format!(
                "{}0001{}{}{}0000",
                encode("command=fetch\n"),
                encode(&format!("want {A}\n")),
                extra,
                encode("done\n")
            )
        };
        assert!(whole_clone(v2("").as_bytes(), true));
        for partial in [
            format!("have {B}\n"),
            "filter blob:none\n".to_owned(),
            "deepen 1\n".to_owned(),
            format!("shallow {B}\n"),
        ] {
            assert!(!whole_clone(v2(&encode(&partial)).as_bytes(), true), "{partial}");
        }
    }

    fn band(n: u8, data: &[u8]) -> Vec<u8> {
        let mut out = format!("{:04x}", data.len() + 5).into_bytes();
        out.push(n);
        out.extend_from_slice(data);
        out
    }

    #[test]
    fn demux_takes_band_one_across_chunk_edges() {
        for v2 in [true, false] {
            let mut wire = Vec::new();
            if v2 {
                wire.extend(encode("acknowledgments\n").bytes());
                wire.extend(encode("ready\n").bytes());
                wire.extend(b"0001");
                wire.extend(encode("packfile\n").bytes());
            } else {
                wire.extend(encode("NAK\n").bytes());
            }
            wire.extend(band(2, b"Counting objects\n"));
            wire.extend(band(1, b"PACK-part-one"));
            wire.extend(band(1, b"-part-two"));
            wire.extend(b"0000");
            for step in [1, 3, 7, wire.len()] {
                let mut d = PackDemux::new(v2);
                let mut pack = Vec::new();
                for chunk in wire.chunks(step) {
                    pack.extend(d.feed(chunk).unwrap());
                }
                assert_eq!(pack, b"PACK-part-one-part-two", "v2={v2} step={step}");
                assert!(d.whole());
            }
            let mut cut = PackDemux::new(v2);
            cut.feed(&wire[..wire.len() - 6]).unwrap();
            assert!(!cut.whole(), "a cut answer is not whole");
        }
        let mut err = PackDemux::new(false);
        assert!(err.feed(&band(3, b"boom")).is_err());
    }
}

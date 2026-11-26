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
        buf = &buf[len.max(4)..];
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
    let id = &rest[..end];
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
}

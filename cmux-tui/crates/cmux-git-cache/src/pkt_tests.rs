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
    let v0 =
        |caps: &str| format!("{}0000{}", encode(&format!("want {A} {caps}\n")), encode("done\n"));
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

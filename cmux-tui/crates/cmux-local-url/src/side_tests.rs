use super::{LinkSide, link_side};
use LinkSide::{Mac, NotWeb, Phone};

#[test]
fn each_address_opens_where_it_can_be_reached() {
    let table: &[(&str, LinkSide)] = &[
        // Public pages: the phone.
        ("https://github.com/login", Phone),
        ("https://github.com/manaflow-ai/cmux/pull/1?tab=files#diff", Phone),
        ("http://example.com", Phone),
        ("HTTPS://GitHub.COM/Login", Phone),
        ("https://github.com./login", Phone),
        ("https://example.com:8443/a", Phone),
        ("https://user:secret@github.com/", Phone),
        ("https://bücher.de/", Phone),
        ("https://xn--bcher-kva.de/", Phone),
        ("https://8.8.8.8/", Phone),
        ("https://[2606:4700:4700::1111]/", Phone),
        ("https://100.128.0.1/", Phone),
        ("https://172.32.0.1/", Phone),
        ("https://my.local.example.com/", Phone),
        // The cases of #43061's WebLinkPlaceTests (the Swift classifier this replaces).
        ("https://github.com/manaflow-ai/cmux/pull/1", Phone),
        ("https://github.com", Phone),
        ("http://example.com:8080/x", Phone),
        ("https://docs.swift.org/", Phone),
        ("https://[2606:4700::1111]/", Phone),
        ("https://localhost.example.com/", Phone),
        ("https://GitHub.com./login", Phone),
        ("https://example.test.com/", Phone),
        // The Mac's loopback: a dev server.
        ("http://localhost:3000/", Mac),
        ("http://LOCALHOST:3000", Mac),
        ("http://localhost./", Mac),
        ("http://app.localhost:5173/", Mac),
        ("http://127.0.0.1:8080/", Mac),
        ("http://127.1.2.3/", Mac),
        ("http://2130706433/", Mac),
        ("http://0.0.0.0:8000/", Mac),
        ("http://[::1]:3000/", Mac),
        ("http://[::]/", Mac),
        ("http://[::ffff:127.0.0.1]/", Mac),
        ("http://:3000/", Mac),
        // Userinfo never decides the host.
        ("https://github.com@127.0.0.1/", Mac),
        ("https://localhost:pw@github.com/", Phone),
        // A LAN, link-local or tailnet host.
        ("http://10.0.0.5/", Mac),
        ("http://172.16.0.1/", Mac),
        ("http://172.31.255.255/", Mac),
        ("http://192.168.1.20:8080/", Mac),
        ("http://169.254.10.1/", Mac),
        ("http://100.64.0.1/", Mac),
        ("http://100.127.255.254/", Mac),
        ("http://[fd7a:115c:a1e0::1]/", Mac),
        ("http://[fc00::1]/", Mac),
        ("http://[fe80::1]/", Mac),
        ("http://[::ffff:192.168.0.1]/", Mac),
        ("http://printer.local/", Mac),
        ("http://devbox.tail1234.ts.net:3000/", Mac),
        ("http://router.lan/", Mac),
        ("http://nas.home.arpa/", Mac),
        ("http://db.internal/", Mac),
        ("http://app.test:3000/", Mac),
        // The cases of #43061's WebLinkPlaceTests.
        ("http://LOCALHOST:5173", Mac),
        ("http://127.0.0.1:8000/api", Mac),
        ("http://0.0.0.0:3000", Mac),
        ("http://172.16.4.2/", Mac),
        ("http://169.254.1.1/", Mac),
        ("http://100.101.102.103:3000", Mac),
        ("http://my-mac.local:3000", Mac),
        ("https://box.tail1234.ts.net/", Mac),
        ("http://[fd7a:115c:a1e0::1]:3000/", Mac),
        ("http://router.home.arpa/", Mac),
        ("http://svc.internal/", Mac),
        ("http://[::ffff:127.0.0.1]:3000/", Mac),
        // Broadcast: no page on the internet answers it (WebLinkPlace said phone).
        ("http://255.255.255.255/", Mac),
        // A bare host name, IDN included.
        ("http://devbox:8080/", Mac),
        ("http://devbox./", Mac),
        ("http://ñ/", Mac),
        // Not a web page: nowhere.
        ("javascript:alert(1)", NotWeb),
        ("file:///etc/passwd", NotWeb),
        ("ftp://example.com/", NotWeb),
        ("mailto:a@example.com", NotWeb),
        ("cmux://tab/1", NotWeb),
        ("data:text/html,hi", NotWeb),
        ("http://", NotWeb),
        ("not a url", NotWeb),
        ("", NotWeb),
    ];
    let wrong: Vec<String> = table
        .iter()
        .filter_map(|(text, want)| {
            let got = link_side(text);
            (got != *want).then(|| format!("{text:?}: got {got:?}, want {want:?}"))
        })
        .collect();
    assert!(wrong.is_empty(), "{} of {} wrong:\n{}", wrong.len(), table.len(), wrong.join("\n"));
}

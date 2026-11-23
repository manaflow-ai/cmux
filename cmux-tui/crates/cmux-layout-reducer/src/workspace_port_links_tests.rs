use super::*;

fn ports(entry: &str) -> Vec<u16> {
    links(entry).into_iter().map(|link| link.port).collect()
}

#[test]
fn port_links_the_daemons_entry_gives_one_link_per_port() {
    assert_eq!(
        links(":3000, :5173"),
        vec![
            PortLink {
                port: 3000,
                label: "localhost:3000".into(),
                url: "http://localhost:3000/".into()
            },
            PortLink {
                port: 5173,
                label: "localhost:5173".into(),
                url: "http://localhost:5173/".into()
            },
        ]
    );
}

#[test]
fn port_links_a_hooks_entry_in_other_shapes() {
    assert_eq!(ports("3000 5173"), vec![3000, 5173]);
    assert_eq!(ports("localhost:8080,127.0.0.1:9000"), vec![8080, 9000]);
    assert_eq!(ports("http://localhost:5173/ [::1]:4000 0.0.0.0:3001"), vec![5173, 4000, 3001]);
    assert_eq!(ports("app.localhost:3000"), vec![3000]);
}

#[test]
fn port_links_none_for_an_entry_with_a_part_that_is_no_loopback_port() {
    assert_eq!(ports(""), Vec::<u16>::new());
    for part in [
        "web",
        ":0",
        ":65536",
        ":12ab",
        ":-1",
        ":",
        "192.168.1.5:3000",
        "example.com:443",
        "127.0.0:80",
    ] {
        assert_eq!(ports(part), Vec::<u16>::new(), "{part}");
        assert_eq!(ports(&format!(":3000, {part}")), Vec::<u16>::new(), "{part}");
    }
    // A hook's own words keep reading as written, not as a stray port.
    assert_eq!(ports("web :3000"), Vec::<u16>::new());
    assert_eq!(ports("3 dev servers"), Vec::<u16>::new());
}

#[test]
fn port_links_each_port_once_in_order_and_capped() {
    assert_eq!(ports(":5173, :3000, :5173, localhost:3000"), vec![5173, 3000]);
    assert_eq!(ports(":1, :2, :3, :4, :5, :6, :7, :8"), vec![1, 2, 3, 4, 5, 6]);
}

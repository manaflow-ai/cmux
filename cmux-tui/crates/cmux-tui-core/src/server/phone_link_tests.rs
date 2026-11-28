use super::*;

const GITHUB: &str = "https://github.com/login/device";

fn phone(client: u64, device: &str, attached: bool) -> Connection {
    Connection {
        client,
        remote_device: true,
        device_id: Some(device.into()),
        opens_links: attached,
        attached,
        open: true,
    }
}

fn mac(client: u64) -> Connection {
    Connection { client, attached: true, open: true, ..Connection::default() }
}

#[test]
fn a_link_opened_right_after_the_phones_key_goes_to_that_phone() {
    let now = Instant::now();
    // The phone types on its input lane (3), its attach channel (2) shows the terminal.
    let connections = [mac(1), phone(2, "iphone", true), phone(3, "iphone", false)];
    assert_eq!(phone_for(GITHUB, Some((3, now)), now, &connections), Some(2));
    // Typing on the attach channel itself.
    assert_eq!(phone_for(GITHUB, Some((2, now)), now, &connections), Some(2));
    assert_eq!(
        phone_for(GITHUB, Some((3, now)), now + Duration::from_secs(60), &connections),
        Some(2)
    );
}

#[test]
fn the_mac_keeps_every_other_link() {
    let now = Instant::now();
    let connections = [mac(1), phone(2, "iphone", true), phone(3, "iphone", false)];
    // The Mac typed last.
    assert_eq!(phone_for(GITHUB, Some((1, now)), now, &connections), None);
    // Nobody typed.
    assert_eq!(phone_for(GITHUB, None, now, &connections), None);
    // The phone's key is older than the window.
    let late = now + INPUT_WINDOW + Duration::from_secs(1);
    assert_eq!(phone_for(GITHUB, Some((3, now)), late, &connections), None);
    // Only the Mac reaches a dev server, a LAN or tailnet host; not a web page at all.
    for url in [
        "http://localhost:3000/",
        "http://mac.local/",
        "http://box.tail1.ts.net/",
        "file:///etc/hosts",
    ] {
        assert_eq!(phone_for(url, Some((3, now)), now, &connections), None, "{url}");
    }
    // A connection that typed but left.
    assert_eq!(phone_for(GITHUB, Some((9, now)), now, &connections), None);
}

#[test]
fn only_a_connection_of_the_same_phone_that_shows_the_terminal_and_opens_links_gets_it() {
    let now = Instant::now();
    // Another device shows the terminal; the typing phone does not.
    let other = [phone(2, "ipad", true), phone(3, "iphone", false)];
    assert_eq!(phone_for(GITHUB, Some((3, now)), now, &other), None);
    // A phone app that did not declare the capability.
    let old =
        [Connection { opens_links: false, ..phone(2, "iphone", true) }, phone(3, "iphone", false)];
    assert_eq!(phone_for(GITHUB, Some((3, now)), now, &old), None);
    // A closed attach channel.
    let closed =
        [Connection { open: false, ..phone(2, "iphone", true) }, phone(3, "iphone", false)];
    assert_eq!(phone_for(GITHUB, Some((3, now)), now, &closed), None);
    // A typist with no device id, or not a remote device (automation, the CLI).
    let anonymous =
        [phone(2, "iphone", true), Connection { device_id: None, ..phone(3, "iphone", false) }];
    assert_eq!(phone_for(GITHUB, Some((3, now)), now, &anonymous), None);
    let local = [
        phone(2, "iphone", true),
        Connection { remote_device: false, ..phone(3, "iphone", false) },
    ];
    assert_eq!(phone_for(GITHUB, Some((3, now)), now, &local), None);
}

#[test]
fn last_inputs_follow_the_newest_key_and_forget_a_connection_that_left() {
    let inputs = LastInputs::default();
    let surface: SurfaceId = 7;
    let now = Instant::now();
    inputs.note_at(surface, 3, now);
    inputs.note_at(surface, 1, now + Duration::from_secs(1));
    assert_eq!(inputs.last(surface).map(|(client, _)| client), Some(1));
    inputs.note_at(surface, 3, now + Duration::from_secs(2));
    inputs.disconnect(3);
    assert_eq!(inputs.last(surface), None);
}

#[test]
fn last_inputs_stay_bounded() {
    let inputs = LastInputs::default();
    let now = Instant::now();
    for surface in 0..(CAPACITY as u64 + 10) {
        inputs.note_at(surface, 1, now + Duration::from_millis(surface));
    }
    assert_eq!(inputs.0.lock().recover_poison().len(), CAPACITY);
    assert!(inputs.last(CAPACITY as u64 + 9).is_some());
    assert!(inputs.last(0).is_none());
}

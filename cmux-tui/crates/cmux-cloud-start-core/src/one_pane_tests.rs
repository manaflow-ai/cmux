use super::*;

fn request(kill: Option<&str>) -> Request {
    Request {
        in_place: true,
        page_live: true,
        cloud_page_free: true,
        kill_switch: kill.map(str::to_owned),
    }
}

#[test]
fn rehomes_by_default() {
    assert_eq!(shown(&request(None)), Shown::Rehome);
    assert_eq!(shown(&request(Some("1"))), Shown::Rehome);
    assert_eq!(shown(&request(Some(""))), Shown::Rehome);
}

#[test]
fn kill_switch_keeps_the_swap() {
    for value in ["0", "off", "FALSE", " no "] {
        assert_eq!(shown(&request(Some(value))), Shown::Swap, "{value}");
    }
}

#[test]
fn swaps_when_there_is_no_page_to_keep() {
    assert_eq!(shown(&Request { in_place: false, ..request(None) }), Shown::Swap);
    assert_eq!(shown(&Request { page_live: false, ..request(None) }), Shown::Swap);
    assert_eq!(shown(&Request { cloud_page_free: false, ..request(None) }), Shown::Swap);
}

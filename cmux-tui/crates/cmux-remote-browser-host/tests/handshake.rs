//! The rd handshake: the host grants service input (the Mac client sends
//! input only when the welcome lists `input.service`), and the probe offers
//! the cap and notices when the welcome does not grant it.

use cmux_rd_core::service::caps::INPUT_SERVICE;
use cmux_rd_proto::SERVICE_REMOTE_BROWSER;
use cmux_rd_proto::control::Control;
use cmux_remote_browser_host::handshake::negotiate_hello;
use cmux_remote_browser_host::probe::{hello_control, input_granted};

#[test]
fn the_host_grants_service_input_to_a_viewer_that_offers_it() {
    let offered = vec![INPUT_SERVICE.to_string(), "tile".to_string()];
    let n = negotiate_hello(SERVICE_REMOTE_BROWSER, &offered).expect("rb/1 is served");
    assert_eq!(n.service, SERVICE_REMOTE_BROWSER);
    assert_eq!(n.caps, vec![INPUT_SERVICE.to_string()]);
    let none = negotiate_hello(SERVICE_REMOTE_BROWSER, &[]).expect("rb/1 is served");
    assert!(none.caps.is_empty(), "a cap the viewer did not offer is not granted");
}

#[test]
fn the_probe_offers_service_input_like_the_mac_client() {
    let Control::Hello { service, caps, .. } = hello_control() else {
        panic!("the probe's first message is a hello");
    };
    assert_eq!(service, SERVICE_REMOTE_BROWSER);
    assert!(caps.iter().any(|c| c == INPUT_SERVICE), "{caps:?}");
}

#[test]
fn the_probe_sees_whether_the_welcome_grants_service_input() {
    let welcome = |caps: &[&str]| {
        serde_json::to_value(Control::Welcome {
            encoder: "videotoolbox".into(),
            width: 2400,
            height: 1600,
            max_datagram: 1332,
            carrier: "stream".into(),
            service: SERVICE_REMOTE_BROWSER.into(),
            caps: caps.iter().map(|c| (*c).to_string()).collect(),
        })
        .expect("json")
    };
    assert!(!input_granted(&[]), "no welcome yet");
    assert!(!input_granted(&[welcome(&[])]));
    assert!(input_granted(&[welcome(&[INPUT_SERVICE])]));
}

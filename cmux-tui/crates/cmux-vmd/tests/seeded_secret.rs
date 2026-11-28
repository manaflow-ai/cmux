//! Seeded secret through the self-hosted vmd provider (tests/egress_seeded.json, site
//! `cmux_vmd::provider`): the host's bearer token rides only in `authorization`.

use cmux_egress::capture;
use cmux_tui_machine_protocol::operations::{MachineHandle, MachineProvider as _};
use cmux_vmd::provider::VmdProvider;

#[tokio::test(flavor = "multi_thread")]
async fn the_vmd_token_rides_only_in_authorization() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
    let token = "SEEDvmdHostToken-5c31";
    let provider = VmdProvider::new("https://seeded-vmd.cmux.dev", token).unwrap();
    provider.pause(&MachineHandle("seeded-machine".into())).await.unwrap();
    assert_eq!(
        capture::leaks(token),
        ["seeded-vmd.cmux.dev POST /v1/machines/seeded-machine/pause: header authorization"
            .to_owned()]
    );
}

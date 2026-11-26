//! Seeded secrets through the coordinator's admin client, on the wire (cmux_egress::capture):
//! the admin token rides only in `Authorization`, and a minted key's request body carries no
//! token. tests/egress_seeded.json names this test for the `cmux_weft::admin` gate site.

use cmux_egress::capture;

use super::{AdminClient, MintAuthKey};

const HOST: &str = "vm.cmux.dev";

#[test]
fn the_admin_token_rides_only_in_authorization() {
    capture::install().unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let token = "SEEDweftAdminToken-93ab";
    let admin = AdminClient::new(&format!("https://{HOST}/seeded-weft/"), token);
    let key = MintAuthKey {
        tags: vec!["tag:seeded".into()],
        user: None,
        reusable: false,
        preapproved: true,
        ttl_seconds: 60,
    };
    runtime.block_on(async {
        let _ = admin.create_tailnet("seeded", true).await;
        let _ = admin.set_policy("seeded", "{}", Some(3)).await;
        let _ = admin.mint_auth_key("seeded", &key).await;
        let _ = admin.nodes("seeded").await;
    });
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-weft/"))
        .collect();
    assert_eq!(sent.len(), 4, "{sent:?}");
    let places = capture::leaks(token);
    assert_eq!(places.len(), 4, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}

//! Seeded secrets through the Cloud journey's machine client, on the wire
//! (cmux_egress::capture): the bearer rides only in `Authorization` on a file write, a
//! client-session mint and the exec route, never in a route, query or body.
//! tests/egress_seeded.json names this test for the `cmux_tui::cli::cloud_journey` gate site.

use cmux_cloud_client::machine::Scope;
use cmux_egress::capture;

use super::Exec;

const HOST: &str = "cloud-api.cmux.dev";
const VM: &str = "vm_seededjourney0000001";

#[test]
fn the_bearer_rides_only_in_authorization() {
    capture::install().unwrap();
    cmux_build_space::init_process(Ok(None));
    let bearer = "SEEDcloudJourneyBearer-91d3";
    let client = super::exec_client("cmux/seeded cloud-journey").unwrap();
    let scope = Scope::new(&format!("https://{HOST}"), Some("team_seeded")).unwrap();
    let machine = scope.machine(VM).unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let mut exec = Exec {
            client: &client,
            scope: &scope,
            credential: bearer,
            machine,
            session: None,
            direct: false,
        };
        let _ = exec.write("/tmp/seeded", b"seeded file", 0o600).await;
        // The capture server answers the mint `200 {}`, which holds no session.
        let _ = exec.run("true", 1_000).await;
        exec.direct = true;
        let _ = exec.run("true", 1_000).await;
    });
    let sent: Vec<_> =
        capture::requests_to(HOST).into_iter().filter(|r| r.target.contains(VM)).collect();
    assert_eq!(sent.len(), 3, "{sent:?}");
    let places = capture::leaks(bearer);
    assert_eq!(places.len(), 3, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}

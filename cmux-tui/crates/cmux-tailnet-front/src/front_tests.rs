use super::*;

#[test]
fn ssh_layout_assigns_22_then_2201() {
    let map = PortMap::ssh_layout("main", &["main", "api", "web"]).with_preview(8080, "web", 3000);
    assert_eq!(map.route(22), Some(&Route::Ssh { workspace: "main".into() }));
    assert_eq!(map.route(2201).map(Route::workspace), Some("api"));
    assert_eq!(map.route(2202).map(Route::workspace), Some("web"));
    assert_eq!(map.route(2203), None);
    assert_eq!(map.route(8080), Some(&Route::Preview { workspace: "web".into(), port: 3000 }));
}

#[test]
fn config_is_off_by_default() {
    assert!(!FrontConfig::default().enabled);
}

#[tokio::test]
async fn disabled_config_binds_nothing() {
    let table = Arc::new(PlacementTable::new());
    let config = FrontConfig { ports: PortMap::ssh_layout("main", &[]), ..FrontConfig::default() };
    let started =
        Front::start_tcp(table, &config, IpAddr::from([127, 0, 0, 1])).await.expect("start");
    assert!(started.is_none());
}

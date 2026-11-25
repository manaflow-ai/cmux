use crate::*;

fn wifi_obs(band: Band, rssi: i32, rate: f64) -> Observations {
    Observations {
        host: "mac".into(),
        wifi: Some(WifiLink {
            interface: "en0".into(),
            band: Some(band),
            channel: Some(149),
            rssi_dbm: Some(rssi),
            noise_dbm: Some(-94),
            tx_rate_mbps: Some(rate),
            ..WifiLink::default()
        }),
        route: RouteInfo {
            interface: Some("en0".into()),
            gateway: Some("192.168.1.1".into()),
            medium: Some(Medium::Wifi),
            idle_wired_with_link: vec![],
        },
        ..Observations::default()
    }
}

fn sample(rtts: &[f64]) -> RttSample {
    RttSample { sent: rtts.len() as u32, received: rtts.len() as u32, rtts_ms: rtts.to_vec() }
}

#[test]
fn a_good_link_reads_as_good() {
    let mut obs = wifi_obs(Band::Ghz5, -52, 866.0);
    obs.gateway_idle = Some(sample(&[2.0, 2.5, 3.0, 2.2]));
    obs.gateway_loaded = Some(sample(&[4.0, 6.0, 7.0, 5.0]));
    let r = Report::new(obs);
    assert_eq!(r.findings.len(), 1);
    assert_eq!(r.findings[0].code, "ok");
    assert_eq!(r.headline(), "Link looks good: 5 GHz, -52 dBm, 866 Mbit/s, +5 ms under load");
}

#[test]
fn the_worst_finding_is_the_headline() {
    let mut obs = wifi_obs(Band::Ghz2_4, -80, 54.0);
    obs.wifi.as_mut().unwrap().channel = Some(6);
    let r = Report::new(obs);
    let codes: Vec<_> = r.findings.iter().map(|f| f.code.as_str()).collect();
    assert_eq!(codes, ["wifi_weak", "wifi_2_4ghz", "wifi_noisy", "wifi_slow_rate"]);
    assert!(r.headline().starts_with("Wi-Fi signal is weak (-80 dBm)"), "{}", r.headline());
}

#[test]
fn a_cable_with_link_under_wifi_is_named() {
    let mut obs = wifi_obs(Band::Ghz5, -50, 1200.0);
    obs.route.idle_wired_with_link = vec!["en7 (Thunderbolt Ethernet)".into()];
    let r = Report::new(obs);
    assert_eq!(r.findings[0].code, "wired_unused");
    assert!(r.headline().contains("en7"));
}

#[test]
fn wifi_radio_is_ignored_when_traffic_is_wired() {
    let mut obs = wifi_obs(Band::Ghz2_4, -85, 6.0);
    obs.route.medium = Some(Medium::Wired);
    obs.route.interface = Some("en7".into());
    let r = Report::new(obs);
    assert_eq!(r.findings[0].code, "ok");
    assert!(r.headline().contains("wired"));
}

#[test]
fn bufferbloat_is_loaded_p95_over_idle_p50() {
    let mut obs = wifi_obs(Band::Ghz5, -50, 866.0);
    obs.gateway_idle = Some(sample(&[3.0; 20]));
    let mut loaded = vec![10.0; 18];
    loaded.extend([180.0, 220.0]);
    obs.gateway_loaded = Some(sample(&loaded));
    let r = Report::new(obs);
    assert_eq!(r.findings[0].code, "bufferbloat");
    assert_eq!(r.findings[0].severity, Severity::Bad);
    assert!(r.headline().contains("+177 ms"), "{}", r.headline());
}

#[test]
fn a_derp_peer_is_named_and_a_direct_one_is_not() {
    let mut obs = wifi_obs(Band::Ghz5, -50, 866.0);
    obs.tailscale_peers = vec![
        TailscalePeer {
            name: "iphone-69".into(),
            online: true,
            derp_region: Some("sfo".into()),
            ping_ms: Some(48.0),
            ..TailscalePeer::default()
        },
        TailscalePeer {
            name: "air-blue".into(),
            online: true,
            direct_addr: Some("192.168.1.20:41641".into()),
            ..TailscalePeer::default()
        },
        TailscalePeer { name: "offline-box".into(), online: false, ..TailscalePeer::default() },
    ];
    let r = Report::new(obs);
    let derp: Vec<_> = r.findings.iter().filter(|f| f.code == "tailscale_derp").collect();
    assert_eq!(derp.len(), 1);
    assert!(derp[0].line.contains("iphone-69") && derp[0].line.contains("sfo, 48 ms"));
}

#[test]
fn low_data_mode_on_the_phone_is_a_warning() {
    let obs = Observations {
        host: "phone".into(),
        phone: Some(PhonePath { constrained: true, ..PhonePath::default() }),
        ..Observations::default()
    };
    let r = Report::new(obs);
    assert_eq!(r.findings[0].code, "low_data_mode");
}

#[test]
fn loss_to_the_router_is_bad() {
    let mut obs = wifi_obs(Band::Ghz5, -50, 866.0);
    obs.gateway_idle = Some(RttSample { sent: 20, received: 18, rtts_ms: vec![2.0; 18] });
    let r = Report::new(obs);
    assert_eq!(r.findings[0].code, "gateway_loss");
}

#[test]
fn observations_round_trip_as_json_from_a_phone() {
    let json = r#"{"host":"phone","phone":{"constrained":false,"expensive":false,"medium":"wifi","same_lan_as_mac":true},
        "wifi":{"interface":"en0","band":"6ghz","rssi_dbm":-48}}"#;
    let obs: Observations = serde_json::from_str(json).unwrap();
    assert_eq!(obs.wifi.as_ref().unwrap().band, Some(Band::Ghz6));
    let back: Observations = serde_json::from_str(&serde_json::to_string(&obs).unwrap()).unwrap();
    assert_eq!(back, obs);
}

#[test]
fn quantile_is_nearest_rank() {
    let v: Vec<f64> = (1..=100).map(f64::from).collect();
    assert_eq!(quantile(&v, 0.5), Some(50.0));
    assert_eq!(quantile(&v, 0.95), Some(95.0));
    assert_eq!(quantile(&v, 0.99), Some(99.0));
    assert_eq!(quantile(&[], 0.5), None);
}

#[test]
fn many_relayed_peers_read_as_one_line_with_the_closest_named() {
    // cosmic-gray's first reading: 15 relayed peers printed 15 lines.
    let mut obs = wifi_obs(Band::Ghz5, -50, 866.0);
    obs.tailscale_peers = (0..15)
        .map(|i| TailscalePeer {
            name: format!("peer-{i}"),
            online: true,
            derp_region: Some("sfo".into()),
            ping_ms: (i % 2 == 0).then_some(f64::from(100 - i)),
            ..TailscalePeer::default()
        })
        .chain([TailscalePeer {
            name: "near".into(),
            online: true,
            direct_addr: Some("172.20.21.235:41641".into()),
            ..TailscalePeer::default()
        }])
        .collect();
    let r = Report::new(obs);
    let derp: Vec<_> = r.findings.iter().filter(|f| f.code == "tailscale_derp").collect();
    assert_eq!(derp.len(), 1);
    assert!(derp[0].line.contains("15 of 16 online peers"), "{}", derp[0].line);
    assert!(derp[0].line.contains("peer-14 (via sfo, 86 ms)"), "{}", derp[0].line);
}

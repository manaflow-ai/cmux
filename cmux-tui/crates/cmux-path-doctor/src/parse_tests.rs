use super::*;

const SP_WIFI: &str = r#"{"SPAirPortDataType":[{"spairport_airport_interfaces":[
  {"_name":"en0","spairport_status_information":"spairport_status_connected",
   "spairport_current_network_information":{"_name":"home",
     "spairport_network_channel":"149 (5GHz, 80MHz)","spairport_network_phymode":"802.11ax",
     "spairport_network_rate":1200,"spairport_signal_noise":"-55 dBm / -94 dBm"}},
  {"_name":"awdl0"}]}]}"#;

#[test]
fn system_profiler_wifi() {
    let w = macos_system_profiler_wifi(SP_WIFI).unwrap();
    assert_eq!(w.interface, "en0");
    assert_eq!(w.channel, Some(149));
    assert_eq!(w.band, Some(Band::Ghz5));
    assert_eq!(w.width_mhz, Some(80));
    assert_eq!(w.rssi_dbm, Some(-55));
    assert_eq!(w.noise_dbm, Some(-94));
    assert_eq!(w.tx_rate_mbps, Some(1200.0));
    assert_eq!(w.phy_mode.as_deref(), Some("802.11ax"));
}

#[test]
fn system_profiler_2_4_and_6ghz_and_unassociated() {
    let two = SP_WIFI.replace("149 (5GHz, 80MHz)", "6 (2GHz, 20MHz)");
    assert_eq!(macos_system_profiler_wifi(&two).unwrap().band, Some(Band::Ghz2_4));
    let six = SP_WIFI.replace("149 (5GHz, 80MHz)", "37 (6GHz, 160MHz)");
    let w = macos_system_profiler_wifi(&six).unwrap();
    assert_eq!((w.band, w.width_mhz), (Some(Band::Ghz6), Some(160)));
    let none = r#"{"SPAirPortDataType":[{"spairport_airport_interfaces":[{"_name":"en0"}]}]}"#;
    assert_eq!(macos_system_profiler_wifi(none), None);
    assert_eq!(macos_system_profiler_wifi("not json"), None);
}

#[test]
fn iw_link() {
    let text = "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: home\n\tfreq: 5180.0\n\tRX: 1 bytes\n\tsignal: -61 dBm\n\ttx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2\n";
    let w = linux_iw_link("wlan0", text).unwrap();
    assert_eq!(w.band, Some(Band::Ghz5));
    assert_eq!(w.rssi_dbm, Some(-61));
    assert_eq!(w.tx_rate_mbps, Some(866.7));
    assert_eq!(w.width_mhz, Some(80));
    assert_eq!(linux_iw_link("wlan0", "Not connected.\n"), None);
}

#[test]
fn routes() {
    let mac = "   route to: default\ndestination: default\n       mask: default\n    gateway: 192.168.1.1\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>\n";
    assert_eq!(macos_route_default(mac), (Some("en0".into()), Some("192.168.1.1".into())));
    let linux = "default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.5 metric 100\n";
    assert_eq!(linux_route_default(linux), (Some("eth0".into()), Some("10.0.0.1".into())));
    assert_eq!(linux_route_default(""), (None, None));
}

#[test]
fn hardware_ports_and_link() {
    let text = "\nHardware Port: Ethernet\nDevice: en0\nEthernet Address: x\n\nHardware Port: Wi-Fi\nDevice: en1\nEthernet Address: y\n\nVLAN Configurations\n===================\n";
    assert_eq!(
        macos_hardware_ports(text),
        [("Ethernet".to_owned(), "en0".to_owned()), ("Wi-Fi".to_owned(), "en1".to_owned())]
    );
    assert_eq!(ifconfig_active("en0: flags=8863<UP>\n\tstatus: active\n"), Some(true));
    assert_eq!(ifconfig_active("awdl0: flags=8843\n\tstatus: inactive\n"), Some(false));
    assert_eq!(ifconfig_active("lo0: flags\n"), None);
}

#[test]
fn tailscale_status_direct_and_derp() {
    let json = r#"{"Self":{"HostName":"cosmic-gray"},"Peer":{
      "nodekey:a":{"HostName":"air-blue","TailscaleIPs":["100.64.0.7","fd7a::7"],"DNSName":"air-blue.t.ts.net.","Online":true,"CurAddr":"192.168.1.20:41641","Relay":"sfo"},
      "nodekey:b":{"HostName":"","DNSName":"iphone-69.t.ts.net.","Online":true,"CurAddr":"","Relay":"sea"},
      "nodekey:c":{"HostName":"old","Online":false,"CurAddr":"","Relay":""}}}"#;
    let peers = tailscale_status(json);
    assert_eq!(peers.len(), 3);
    assert_eq!(peers[0].name, "air-blue");
    assert!(peers[0].is_direct());
    assert_eq!(peers[0].derp_region, None);
    assert_eq!(peers[0].address.as_deref(), Some("100.64.0.7"));
    assert_eq!(peers[1].name, "iphone-69");
    assert_eq!(peers[1].derp_region.as_deref(), Some("sea"));
    assert!(!peers[2].online);
    assert!(tailscale_status("{}").is_empty());
}

#[test]
fn tailscale_ping_lines() {
    let derp = "pong from iphone-69 (100.101.1.2) via DERP(sfo) in 48ms\n";
    assert_eq!(tailscale_ping(derp), Some((None, Some("sfo".into()), 48.0)));
    let direct = "pong from iphone-69 (100.101.1.2) via DERP(sfo) in 50ms\npong from iphone-69 (100.101.1.2) via 192.168.1.30:41641 in 4ms\n";
    assert_eq!(tailscale_ping(direct), Some((Some("192.168.1.30:41641".into()), None, 4.0)));
    let us = "pong from x (100.1.1.1) via 10.0.0.2:41641 in 850µs\n";
    assert_eq!(tailscale_ping(us), Some((Some("10.0.0.2:41641".into()), None, 0.85)));
    assert_eq!(tailscale_ping("timeout\n"), None);
}

#[test]
fn ping_macos_and_linux() {
    let mac = "PING 192.168.1.1 (192.168.1.1): 56 data bytes\n64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=2.871 ms\n64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=3.402 ms\nRequest timeout for icmp_seq 2\n\n--- 192.168.1.1 ping statistics ---\n3 packets transmitted, 2 packets received, 33.3% packet loss\nround-trip min/avg/max/stddev = 2.871/3.136/3.402/0.266 ms\n";
    let s = ping_output(mac);
    assert_eq!((s.sent, s.received), (3, 2));
    assert_eq!(s.rtts_ms, [2.871, 3.402]);
    let linux = "64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=0.412 ms\n--- 10.0.0.1 ping statistics ---\n1 packets transmitted, 1 received, 0% packet loss, time 0ms\n";
    let s = ping_output(linux);
    assert_eq!((s.sent, s.received, s.rtts_ms.len()), (1, 1, 1));
}

#[test]
fn ifconfig_ethernet_medium() {
    // cosmic-gray's en7: a USB-C adapter the port list did not name.
    let en7 = "en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tmedia: autoselect (1000baseT <full-duplex>)\n\tstatus: active\n";
    assert!(ifconfig_is_ethernet(en7));
    let wifi = "en0: flags=8863<UP> mtu 1500\n\tmedia: autoselect\n\tstatus: active\n";
    assert!(!ifconfig_is_ethernet(wifi));
}

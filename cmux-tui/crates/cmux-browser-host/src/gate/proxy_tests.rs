use super::proxy_urls;

#[test]
fn proxy_server_values_name_their_proxies() {
    let hosts = |server: &str| {
        proxy_urls(server)
            .map(|urls| urls.iter().map(|u| u.host_str().unwrap().to_owned()).collect::<Vec<_>>())
    };
    assert_eq!(hosts("127.0.0.1:8080"), Some(vec!["127.0.0.1".into()]));
    assert_eq!(hosts("socks5://p.test:1080"), Some(vec!["p.test".into()]));
    assert_eq!(
        hosts("http=a.test:1;https=b.test:2,direct://"),
        Some(vec!["a.test".into(), "b.test".into()])
    );
    assert_eq!(hosts("http://[::1]:3128"), Some(vec!["[::1]".into()]));
    assert_eq!(hosts("http://"), None);
}

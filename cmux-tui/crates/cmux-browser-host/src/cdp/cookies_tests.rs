use super::on_site;

#[test]
fn cookie_domains_belong_to_their_site_and_its_subdomains() {
    assert!(on_site(".example.com", "example.com"));
    assert!(on_site("a.Example.com", "example.com"));
    assert!(on_site("example.com", "example.com"));
    assert!(!on_site("notexample.com", "example.com"));
    assert!(!on_site("example.org", "example.com"));
}

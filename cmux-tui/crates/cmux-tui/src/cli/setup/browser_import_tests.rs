use super::{BROWSERS, registry_id};

#[test]
fn registry_id_reads_ids_and_product_names() {
    assert!(BROWSERS.contains(&("chrome", "Google Chrome")), "{BROWSERS:?}");
    for given in ["chrome", "Google Chrome", "google-chrome", "GOOGLE CHROME"] {
        assert_eq!(registry_id(given), "chrome", "{given}");
    }
    assert_eq!(registry_id("No Such Browser"), "No Such Browser");
}

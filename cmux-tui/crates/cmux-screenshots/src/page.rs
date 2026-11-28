//! The Screenshots page's address (Swift `ScreenshotsPageAddress`).

/// The address a browser tab or the command palette opens the pane with.
pub const ADDRESS: &str = "cmux://screenshots";

/// Whether `url` is the Screenshots page: scheme `cmux`, host `screenshots`, any case, any path.
pub fn matches(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once(':') else { return false };
    if !scheme.eq_ignore_ascii_case("cmux") {
        return false;
    }
    let Some(authority) = rest.strip_prefix("//") else { return false };
    let authority = authority.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    let host = host.split(':').next().unwrap_or_default();
    host.eq_ignore_ascii_case("screenshots")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_page_in_any_case() {
        assert!(matches(ADDRESS));
        assert!(matches("CMUX://Screenshots"));
        assert!(matches("cmux://screenshots/anything?q=1"));
        assert!(!matches("cmux://settings"));
        assert!(!matches("https://screenshots"));
        assert!(!matches("cmux:screenshots"));
        assert!(!matches("screenshots"));
    }
}

//! What a loopback listener's process is (stub; cx-pmq7 red).

/// The process that holds a listener.
#[allow(dead_code)]
pub(crate) struct Holder {
    pub(crate) path: String,
    pub(crate) args: Vec<String>,
    pub(crate) env: Vec<String>,
}

#[allow(dead_code)]
pub(crate) fn holder_refusal(_holder: &Holder, _port: u16, _family: bool) -> Option<String> {
    None
}

#[allow(dead_code)]
pub(crate) fn bundle_is_chromium_family(_path: &str) -> bool {
    false
}

#[allow(dead_code)]
pub(crate) fn parse_procargs2(_data: &[u8]) -> Option<(Vec<String>, Vec<String>)> {
    None
}

#[cfg(test)]
#[path = "egress_holders_tests.rs"]
mod tests;

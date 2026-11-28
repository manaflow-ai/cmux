//! Exact-size idle New Tab frame preparation policy.
use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"new_tab_prefetch"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&cmux_layout_reducer::new_tab_prefetch::plan(request))
        .map_err(|_| ERR_INVALID)
}

#[cfg(test)]
mod tests {
    #[test]
    fn new_tab_prefetch_dispatches_through_the_json_channel() {
        let request = br#"{"parked":{"width":1000,"height":800},"splits":[{"width":500,"height":800}],"cached":[]}"#;
        let reply = crate::respond_op_module(b"new_tab_prefetch", request).unwrap().unwrap();
        let sizes: serde_json::Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(sizes[0]["width"], 500.0);
        assert_eq!(sizes[1]["width"], 1000.0);
    }
}

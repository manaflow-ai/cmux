//! Shutdown failure reporting without a panic path.

use super::*;

#[test]
fn shutdown_failures_combine_by_count() {
    assert!(combine_shutdown_failures(Vec::new()).is_ok());
    let one = combine_shutdown_failures(vec![anyhow!("first")]).unwrap_err();
    assert_eq!(one.to_string(), "first");
    let two = combine_shutdown_failures(vec![anyhow!("first"), anyhow!("second")]).unwrap_err();
    assert_eq!(
        two.to_string(),
        "remote daemon shutdown encountered multiple failures: first; second"
    );
}

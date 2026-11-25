//! Prints the VM join script for a request read from stdin (JSON `JoinRequest`), for
//! testing/headscale-e2e.sh's `JOIN_SCRIPT`. The key in the request is only checked, never printed.
fn main() {
    let request: cmux_tailnet_join::JoinRequest =
        serde_json::from_reader(std::io::stdin()).expect("a JoinRequest as JSON on stdin");
    let checked = request.check().unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(2)
    });
    if std::env::args().nth(1).as_deref() == Some("leave") {
        print!("{}", cmux_tailnet_join::vm_leave_script());
    } else {
        print!("{}", cmux_tailnet_join::vm_join_script(&checked));
    }
}

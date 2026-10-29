//! Connect requests that reach the provider runtime directly.

use std::thread;

use super::tests::{
    TestProviderSocket, active_workspace_snapshot, provider_managed_snapshot,
    serve_initial_snapshot, serve_runtime_refresh, serve_workspace_snapshot, token,
};
use super::*;

#[test]
fn provider_runtime_refuses_a_local_connect_with_an_error() {
    let socket = TestProviderSocket::bind();
    let listener = socket.listener();
    let catalog = provider_managed_snapshot(1);
    let workspace = active_workspace_snapshot(1);
    let server = thread::spawn(move || {
        let (mut stream, mut reader) = serve_initial_snapshot(&listener, catalog.clone());
        serve_workspace_snapshot(&mut stream, &mut reader, &workspace);
        serve_runtime_refresh(&mut stream, &mut reader, &catalog, Some(&workspace));
    });

    let mut runtime = ProviderMachineRuntime::connect(&socket.path, token()).unwrap();
    let error = runtime
        .perform_request(MachineRequest::Connect {
            target: "mini.local".into(),
            route: MachineConnectRoute::Local,
        })
        .err()
        .expect("the provider runtime owns no client-local catalog");
    assert_eq!(error.to_string(), localization::catalog().sidebar.client_machine_unavailable);
    drop(runtime);
    server.join().unwrap();
}

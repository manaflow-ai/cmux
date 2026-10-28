//! The frontend's reserved worker permits: with
//! automation holding every shared surface or resource worker permit, the
//! verified app's op is still admitted at once, and automation never takes a
//! reserved permit.

use std::sync::Arc;

use serde_json::{Value, json};

use super::super::origin_gate::set_hello;
use super::super::terminal_io_wire::ClearHistoryParams;
use super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, RESOURCE_WAITS_PER_CLIENT_CAPACITY, RESOURCE_WAITS_SERVER_CAPACITY, Request,
    ResourceRequestId, SERVER_SURFACE_WORKER_CAPACITY,
};
use super::{
    FRONTEND_RESERVED_WORKER_PERMITS, ResourceWorkerAdmission, ResourceWorkerAdmissionError,
    ServerSurfaceOperationAdmission, WorkerClass,
};
use crate::diagnostics::LockCaller;
use crate::panic_free::RecoverPoison;
use crate::request_origin::HelloRole;

#[test]
fn worker_class_follows_the_connection_caller() {
    assert_eq!(WorkerClass::of(LockCaller::Frontend), WorkerClass::Frontend);
    assert_eq!(WorkerClass::of(LockCaller::Automation), WorkerClass::Automation);
    assert_eq!(WorkerClass::of(LockCaller::Program), WorkerClass::Automation);
}

#[test]
fn automation_never_takes_a_reserved_surface_worker() {
    let admission = Arc::new(ServerSurfaceOperationAdmission::default());
    let shared: Vec<_> = (0..SERVER_SURFACE_WORKER_CAPACITY)
        .map(|_| admission.try_reserve_worker(WorkerClass::Automation).expect("a shared worker"))
        .collect();
    assert!(admission.try_reserve_worker(WorkerClass::Automation).is_none());

    let reserved: Vec<_> = (0..FRONTEND_RESERVED_WORKER_PERMITS)
        .map(|_| admission.try_reserve_worker(WorkerClass::Frontend).expect("a reserved worker"))
        .collect();
    assert!(
        admission.try_reserve_worker(WorkerClass::Frontend).is_none(),
        "the frontend is bounded too: shared plus reserved"
    );

    // A released shared permit goes back to automation; the frontend's
    // reserved ones stay held.
    drop(shared);
    assert!(admission.try_reserve_worker(WorkerClass::Automation).is_some());
    drop(reserved);
    assert_eq!(admission.state.lock().recover_poison().workers, 0);
}

#[test]
fn automation_never_takes_a_reserved_resource_worker() {
    let per_client = 4;
    let shared = 8;
    let admission = ResourceWorkerAdmission::new(per_client, shared);
    let automation: Vec<_> = (0..shared)
        .map(|index| {
            admission
                .try_reserve(index as u64 / per_client as u64, WorkerClass::Automation)
                .expect("a shared permit")
        })
        .collect();
    assert!(matches!(
        admission.try_reserve(100, WorkerClass::Automation),
        Err(ResourceWorkerAdmissionError::ServerCapacity)
    ));

    let frontend = 200;
    let reserved: Vec<_> = (0..FRONTEND_RESERVED_WORKER_PERMITS)
        .map(|_| admission.try_reserve(frontend, WorkerClass::Frontend).expect("a reserved permit"))
        .collect();
    assert!(matches!(
        admission.try_reserve(frontend, WorkerClass::Frontend),
        Err(ResourceWorkerAdmissionError::ServerCapacity)
    ));
    assert_eq!(admission.active(), shared + FRONTEND_RESERVED_WORKER_PERMITS);
    drop((automation, reserved));
    assert_eq!(admission.active(), 0);
}

#[test]
fn the_frontend_keeps_its_per_client_resource_capacity() {
    let admission = ResourceWorkerAdmission::new(1, 8);
    let _held = admission.try_reserve(1, WorkerClass::Frontend).expect("a permit");
    assert!(matches!(
        admission.try_reserve(1, WorkerClass::Frontend),
        Err(ResourceWorkerAdmissionError::ClientCapacity)
    ));
}

fn captured_writer() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    (MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None }), outbound)
}

/// The clear-history reply `writer`'s connection gets while automation holds
/// every shared surface worker.
fn clear_reply(
    mux: &Arc<crate::Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: &BoundedOutbound,
) -> Value {
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let mut clear = Some(Request {
        id: Some(json!(1)),
        cmd: Command::ClearHistory(ClearHistoryParams { surface: surface.id, fallback_key: None }),
    });
    assert_eq!(scheduler.dispatch(mux.clone(), client, &mut clear, 0, writer), Some(true));
    scheduler.finish_and_wait();
    let reply = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    mux.close_surface(surface.id).unwrap();
    reply
}

/// The acceptance case: automation holds every shared surface worker, so its
/// own clear-history is refused, and the verified app's is admitted at once.
#[test]
fn a_frontend_surface_op_is_admitted_while_automation_holds_every_shared_worker() {
    let mux =
        crate::Mux::new_for_test("worker-admission-reserved", crate::SurfaceOptions::default());
    let _shared: Vec<_> = (0..SERVER_SURFACE_WORKER_CAPACITY)
        .map(|_| {
            mux.surface_operation_admission
                .try_reserve_worker(WorkerClass::Automation)
                .expect("a shared worker")
        })
        .collect();

    let (cli_writer, cli_outbound) = captured_writer();
    let cli = mux.control_clients.register(ClientTransport::Unix, cli_writer.clone());
    assert_eq!(cli_writer.lock_caller.get(), LockCaller::Automation);
    let refused = clear_reply(&mux, cli, cli_writer, &cli_outbound);
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(
        refused["error"], "too many clear-history operations are already in progress",
        "{refused}"
    );

    let (app_writer, app_outbound) = captured_writer();
    let app = mux.control_clients.register(ClientTransport::Unix, app_writer.clone());
    assert!(set_hello(&mux, app, HelloRole::Main, None, true, None, false));
    assert_eq!(app_writer.lock_caller.get(), LockCaller::Frontend);
    let admitted = clear_reply(&mux, app, app_writer, &app_outbound);
    assert_eq!(admitted["id"], 1, "{admitted}");
    assert_eq!(admitted["ok"], true, "{admitted}");
}

/// The same for a resource wait: automation connections fill the shared
/// server capacity, and the verified app still installs one.
#[test]
fn a_frontend_resource_wait_is_admitted_while_automation_holds_every_shared_permit() {
    let mux = crate::Mux::new_for_test("worker-admission-waits", crate::SurfaceOptions::default());
    let mut held = Vec::new();
    let mut next_id = 0_u64;
    let mut request_id = || {
        next_id += 1;
        ResourceRequestId::parse(format!("reserved-wait-{next_id}")).unwrap()
    };
    for _ in 0..(RESOURCE_WAITS_SERVER_CAPACITY / RESOURCE_WAITS_PER_CLIENT_CAPACITY) {
        let (writer, _) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer);
        for _ in 0..RESOURCE_WAITS_PER_CLIENT_CAPACITY {
            held.push(
                mux.control_clients
                    .install_resource_wait(client, &request_id())
                    .expect("a shared permit"),
            );
        }
    }
    let (writer, _) = captured_writer();
    let late = mux.control_clients.register(ClientTransport::Unix, writer);
    assert!(mux.control_clients.install_resource_wait(late, &request_id()).is_err());

    let (app_writer, _) = captured_writer();
    let app = mux.control_clients.register(ClientTransport::Unix, app_writer);
    assert!(set_hello(&mux, app, HelloRole::Main, None, true, None, false));
    held.push(
        mux.control_clients
            .install_resource_wait(app, &request_id())
            .expect("the frontend's reserved permit"),
    );
    assert_eq!(
        mux.control_clients.resource_wait_admission.active(),
        RESOURCE_WAITS_SERVER_CAPACITY + 1
    );
}

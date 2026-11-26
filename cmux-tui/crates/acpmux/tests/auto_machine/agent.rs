//! A Cloud agent's Auto mode socket for tests: a real Unix socket that reads cmux-host's call
//! lines and answers each from a [`FakeAutoCloud`] called as one machine's VM install, in
//! cmux-host's own reply shapes. A daemon under test reaches the fake store through it exactly
//! as it reaches the real one through the real agent.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use acpmux::auto_session::machine::MachineCloud;
use cmux_auto_session::cloud::{AutoCloud, AutoCloudError, CloudResult};
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{
    Assignments, EventsAppended, Fence, InboxPage, SessionAnswer, SnapshotPosted,
};
use cmux_host::cloud::auto_session::{Call, Kind, REQUEST_KEY, machine_reply, refusal, reply_for};
use cmux_server::cloud_http::Response;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

/// What a test sets and reads on the running agent.
#[derive(Default)]
struct Control {
    /// The agent's own refusal for the next call, instead of sending it.
    refuse_next: Mutex<Option<String>>,
    /// Every call's name, in the order they arrived.
    calls: Mutex<Vec<&'static str>>,
    /// Routes the store answers 404 for now, by call name.
    lost: Mutex<Vec<&'static str>>,
}

/// The agent of one Cloud machine. Dropping it closes the socket.
pub struct FakeAgent {
    _dir: tempfile::TempDir,
    socket: PathBuf,
    control: Arc<Control>,
    task: tokio::task::JoinHandle<()>,
}

impl FakeAgent {
    /// Starts the agent of `machine` over `store`.
    pub fn start(store: &FakeAutoCloud, machine: &str) -> FakeAgent {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("auto-session.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let control = Arc::new(Control::default());
        let (cloud, machine) = (store.as_machine(machine), machine.to_owned());
        let shared = Arc::clone(&control);
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let (cloud, machine) = (cloud.clone(), machine.clone());
                let control = Arc::clone(&shared);
                tokio::spawn(async move { serve(stream, &cloud, &machine, &control).await });
            }
        });
        FakeAgent { _dir: dir, socket, control, task }
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// The daemon's transport to this agent.
    pub fn cloud(&self) -> MachineCloud {
        MachineCloud::new(&self.socket)
    }

    /// The next call is answered by the agent itself with this refusal (`busy`,
    /// `auto.unreachable`, `auto.resumed`, ...), and never reaches the store.
    pub fn refuse_next(&self, code: &str) {
        *self.control.refuse_next.lock().unwrap() = Some(code.to_owned());
    }

    /// From now on the store answers every call of `kind` with 404, as for something it does
    /// not have; [`Self::find`] ends that.
    pub fn lose(&self, kind: Kind) {
        self.control.lost.lock().unwrap().push(kind.name());
    }

    pub fn find(&self, kind: Kind) {
        self.control.lost.lock().unwrap().retain(|lost| *lost != kind.name());
    }

    /// The calls that arrived, by name, in order.
    pub fn calls(&self) -> Vec<&'static str> {
        self.control.calls.lock().unwrap().clone()
    }
}

impl Drop for FakeAgent {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// One connection: one call line in, one reply line out.
async fn serve(stream: UnixStream, cloud: &FakeAutoCloud, machine: &str, control: &Control) {
    let mut stream = BufReader::new(stream);
    let mut line = String::new();
    if stream.read_line(&mut line).await.is_err() {
        return;
    }
    let call = serde_json::from_str::<Value>(&line)
        .map_err(|_| "the line is not JSON".to_owned())
        .and_then(|value| Call::from_json(value.get(REQUEST_KEY).unwrap_or(&Value::Null)));
    let reply = match call {
        Err(why) => refusal("request.invalid", &why),
        Ok(call) => {
            control.calls.lock().unwrap().push(call.kind.name());
            let refused = control.refuse_next.lock().unwrap().take();
            let lost = control.lost.lock().unwrap().contains(&call.kind.name());
            match refused {
                Some(code) => refusal(&code, "the test's agent refused this call"),
                None if lost => {
                    let body = br#"{"error":{"code":"not_found","message":"not found"}}"#;
                    let gone = Response { status: 404, retry_after: None, bytes: body.to_vec() };
                    reply_for(&call, Some(&gone))
                }
                None => answer(cloud, machine, &call).await,
            }
        }
    };
    let _ = stream.get_mut().write_all(format!("{reply}\n").as_bytes()).await;
}

/// The reply line for `call`, as cmux-host's agent would write it.
async fn answer(cloud: &FakeAutoCloud, machine: &str, call: &Call) -> Value {
    if call.kind == Kind::Machine {
        return machine_reply(machine);
    }
    let response = match route(cloud, call).await {
        Ok((status, bytes)) => Some(Response { status, retry_after: None, bytes }),
        // A refusal is the store's answer too: its status and its error body.
        Err(error) => error.envelope().map(|(status, envelope)| Response {
            status,
            retry_after: None,
            bytes: serde_json::to_vec(&envelope).unwrap(),
        }),
    };
    reply_for(call, response.as_ref())
}

/// The store's answer to `call`: its status and body.
async fn route(cloud: &FakeAutoCloud, call: &Call) -> CloudResult<(u16, Vec<u8>)> {
    let id = call.session.as_str();
    let session = |session| json(&SessionAnswer { session });
    match call.kind {
        Kind::Machine => Err(AutoCloudError::http(400, "request.invalid", "not a store route")),
        Kind::Assignments => {
            json(&Assignments { assignments: cloud.assignments(call.timeout_ms).await? })
        }
        Kind::Get => session(cloud.get(id).await?),
        Kind::Lease => json(&cloud.lease(id, &body(call)?).await?),
        Kind::Release => session(cloud.release(id, &body(call)?).await?),
        Kind::EventsAppend => {
            json(&EventsAppended { last_seq: cloud.append_events(id, &body(call)?).await? })
        }
        Kind::Events => json(&cloud.events(id, call.after, call.limit).await?),
        Kind::ChunkPut => {
            let (holder, epoch) = call.writer.clone().unwrap_or_default();
            let holder = holder
                .parse()
                .map_err(|_| AutoCloudError::http(400, "request.invalid", "holder is not one"))?;
            cloud.put_chunk(id, &call.sha256, &call.bytes, &Fence::new(holder, epoch)).await?;
            Ok((204, Vec::new()))
        }
        Kind::Chunk => Ok((200, cloud.chunk(id, &call.sha256).await?)),
        Kind::SnapshotPost => {
            json(&SnapshotPosted { snapshot: cloud.post_snapshot(id, &body(call)?).await? })
        }
        Kind::Snapshot => json(&cloud.snapshot(id).await?),
        Kind::Inbox => json(&InboxPage { messages: cloud.inbox(id, call.after).await? }),
        Kind::InboxAck => session(cloud.ack_inbox(id, &body(call)?).await?),
        Kind::AssignmentAck => session(cloud.ack_assignment(id, &body(call)?).await?),
    }
}

fn json(answer: &impl Serialize) -> CloudResult<(u16, Vec<u8>)> {
    Ok((200, serde_json::to_vec(answer).unwrap()))
}

/// The call's JSON body as the route's request, refused as the store refuses a bad body.
fn body<T: DeserializeOwned>(call: &Call) -> CloudResult<T> {
    serde_json::from_value(call.body.clone().unwrap_or(Value::Null))
        .map_err(|error| AutoCloudError::http(400, "request.invalid", error.to_string()))
}

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fmt;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

pub type Result<T> = std::result::Result<T, MuxError>;

#[derive(Debug)]
pub enum MuxError {
    Command { message: String, id: Option<Value> },
    Decode(String),
    Connection(String),
    Timeout(String),
    ProtocolVersion(String),
}

impl fmt::Display for MuxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command { message, .. } => write!(f, "{message}"),
            Self::Decode(message)
            | Self::Connection(message)
            | Self::Timeout(message)
            | Self::ProtocolVersion(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for MuxError {}

#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub socket_path: PathBuf,
    pub timeout: Duration,
    pub allow_protocol_v6_attach: bool,
}

impl ClientConfig {
    pub fn from_socket_path(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
            timeout: Duration::from_secs(10),
            allow_protocol_v6_attach: true,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct IdentifyResult {
    pub app: String,
    pub version: String,
    pub protocol: u32,
    pub session: String,
    pub pid: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceResult {
    pub surface: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReadScreenResult {
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VtStateResult {
    pub cols: u16,
    pub rows: u16,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tree {
    pub workspaces: Vec<Workspace>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Workspace {
    pub id: u64,
    pub name: String,
    pub active: bool,
    pub screens: Vec<Screen>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Screen {
    pub id: u64,
    pub name: Option<String>,
    pub active: bool,
    pub active_pane: u64,
    pub layout: Layout,
    pub panes: Vec<Pane>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum Layout {
    #[serde(rename = "leaf")]
    Leaf { pane: u64 },
    #[serde(rename = "split")]
    Split { dir: String, ratio: f32, a: Box<Layout>, b: Box<Layout> },
}

#[derive(Debug, Clone, Deserialize)]
pub struct Pane {
    pub id: u64,
    pub name: Option<String>,
    #[serde(default)]
    pub active_tab: usize,
    #[serde(default)]
    pub tabs: Vec<Tab>,
    #[serde(default)]
    pub dead: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tab {
    pub surface: u64,
    pub kind: String,
    pub browser_source: Option<String>,
    pub name: Option<String>,
    pub title: String,
    pub size: Option<Size>,
    pub dead: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceEvent {
    pub surface: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceResizedEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VtStateEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OutputEvent {
    pub surface: u64,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ResizedEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
    pub replay: String,
}

#[non_exhaustive]
#[derive(Debug, Clone)]
pub enum Event {
    TreeChanged,
    SurfaceOutput(SurfaceEvent),
    SurfaceResized(SurfaceResizedEvent),
    SurfaceExited(SurfaceEvent),
    TitleChanged(SurfaceEvent),
    Bell(SurfaceEvent),
    Empty,
    VtState(VtStateEvent),
    Output(OutputEvent),
    Resized(ResizedEvent),
    Detached(SurfaceEvent),
    Unknown(Value),
}

pub struct MuxClient {
    config: ClientConfig,
    conn: JsonLineConnection,
    next_id: u64,
    protocol: Option<u32>,
}

impl MuxClient {
    pub fn connect(config: ClientConfig) -> Result<Self> {
        let conn = JsonLineConnection::connect(&config.socket_path, config.timeout)?;
        Ok(Self { config, conn, next_id: 1, protocol: None })
    }

    pub fn send_raw(&mut self, mut request: Map<String, Value>) -> Result<Value> {
        if !request.contains_key("id") {
            let id = self.next_id();
            request.insert("id".to_string(), Value::from(id));
        }
        let request_id = request.get("id").cloned();
        self.conn.send(&Value::Object(request))?;
        loop {
            let response = self.conn.recv()?;
            if response.get("event").is_some() {
                continue;
            }
            if response.get("id") != request_id.as_ref() && response.get("id").is_some() {
                continue;
            }
            return Ok(response);
        }
    }

    pub fn request<T: for<'de> Deserialize<'de>>(
        &mut self,
        cmd: &str,
        params: Map<String, Value>,
    ) -> Result<T> {
        let mut request = params;
        let id = self.next_id();
        request.insert("id".to_string(), Value::from(id));
        request.insert("cmd".to_string(), Value::from(cmd));
        let response = self.send_raw(request)?;
        if response.get("ok") == Some(&Value::Bool(true)) {
            let data = response.get("data").cloned().unwrap_or(Value::Object(Map::new()));
            serde_json::from_value(data).map_err(|err| MuxError::Decode(err.to_string()))
        } else {
            Err(MuxError::Command {
                message: response
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error")
                    .to_string(),
                id: response.get("id").cloned(),
            })
        }
    }

    pub fn identify(&mut self) -> Result<IdentifyResult> {
        let result: IdentifyResult = self.request("identify", Map::new())?;
        self.protocol = Some(result.protocol);
        Ok(result)
    }

    pub fn list_workspaces(&mut self) -> Result<Tree> {
        self.request("list-workspaces", Map::new())
    }

    pub fn send(&mut self, surface: u64, text: Option<&str>, bytes: Option<&str>) -> Result<()> {
        let mut params = Map::new();
        params.insert("surface".to_string(), Value::from(surface));
        insert_opt(&mut params, "text", text);
        insert_opt(&mut params, "bytes", bytes);
        self.request::<Empty>("send", params).map(|_| ())
    }

    pub fn read_screen(&mut self, surface: u64) -> Result<ReadScreenResult> {
        self.request("read-screen", surface_params(surface))
    }

    pub fn vt_state(&mut self, surface: u64) -> Result<VtStateResult> {
        self.request("vt-state", surface_params(surface))
    }

    pub fn new_tab(
        &mut self,
        pane: Option<u64>,
        cwd: Option<&str>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        insert_opt(&mut params, "pane", pane);
        insert_opt(&mut params, "cwd", cwd);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-tab", params)
    }

    pub fn new_browser_tab(
        &mut self,
        url: &str,
        pane: Option<u64>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        params.insert("url".to_string(), Value::from(url));
        insert_opt(&mut params, "pane", pane);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-browser-tab", params)
    }

    pub fn new_workspace(
        &mut self,
        name: Option<&str>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        insert_opt(&mut params, "name", name);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-workspace", params)
    }

    pub fn new_screen(
        &mut self,
        workspace: Option<u64>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        insert_opt(&mut params, "workspace", workspace);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-screen", params)
    }

    pub fn split(
        &mut self,
        pane: u64,
        dir: &str,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("dir".to_string(), Value::from(dir));
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("split", params)
    }

    pub fn set_ratio(&mut self, pane: u64, dir: &str, ratio: f32) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("dir".to_string(), Value::from(dir));
        params.insert("ratio".to_string(), Value::from(ratio));
        self.request::<Empty>("set-ratio", params).map(|_| ())
    }

    pub fn set_default_colors(&mut self, fg: Option<&str>, bg: Option<&str>) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "fg", fg);
        insert_opt(&mut params, "bg", bg);
        self.request::<Empty>("set-default-colors", params).map(|_| ())
    }

    pub fn close_surface(&mut self, surface: u64) -> Result<()> {
        self.request::<Empty>("close-surface", surface_params(surface)).map(|_| ())
    }

    pub fn close_pane(&mut self, pane: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        self.request::<Empty>("close-pane", params).map(|_| ())
    }

    pub fn close_screen(&mut self, screen: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("screen".to_string(), Value::from(screen));
        self.request::<Empty>("close-screen", params).map(|_| ())
    }

    pub fn close_workspace(&mut self, workspace: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("workspace".to_string(), Value::from(workspace));
        self.request::<Empty>("close-workspace", params).map(|_| ())
    }

    pub fn rename_pane(&mut self, pane: u64, name: &str) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-pane", params).map(|_| ())
    }

    pub fn rename_surface(&mut self, surface: u64, name: &str) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-surface", params).map(|_| ())
    }

    pub fn rename_screen(&mut self, screen: u64, name: &str) -> Result<()> {
        let mut params = Map::new();
        params.insert("screen".to_string(), Value::from(screen));
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-screen", params).map(|_| ())
    }

    pub fn rename_workspace(&mut self, workspace: u64, name: &str) -> Result<()> {
        let mut params = Map::new();
        params.insert("workspace".to_string(), Value::from(workspace));
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-workspace", params).map(|_| ())
    }

    pub fn resize_surface(&mut self, surface: u64, cols: u16, rows: u16) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("cols".to_string(), Value::from(cols));
        params.insert("rows".to_string(), Value::from(rows));
        self.request::<Empty>("resize-surface", params).map(|_| ())
    }

    pub fn focus_pane(&mut self, pane: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        self.request::<Empty>("focus-pane", params).map(|_| ())
    }

    pub fn select_tab(
        &mut self,
        pane: Option<u64>,
        index: Option<usize>,
        delta: Option<isize>,
    ) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "pane", pane);
        insert_opt(&mut params, "index", index);
        insert_opt(&mut params, "delta", delta);
        self.request::<Empty>("select-tab", params).map(|_| ())
    }

    pub fn select_screen(&mut self, index: Option<usize>, delta: Option<isize>) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "index", index);
        insert_opt(&mut params, "delta", delta);
        self.request::<Empty>("select-screen", params).map(|_| ())
    }

    pub fn select_workspace(&mut self, index: Option<usize>, delta: Option<isize>) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "index", index);
        insert_opt(&mut params, "delta", delta);
        self.request::<Empty>("select-workspace", params).map(|_| ())
    }

    pub fn move_tab(&mut self, surface: u64, pane: u64, index: usize) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("index".to_string(), Value::from(index));
        self.request::<Empty>("move-tab", params).map(|_| ())
    }

    pub fn move_workspace(&mut self, workspace: u64, index: usize) -> Result<()> {
        let mut params = Map::new();
        params.insert("workspace".to_string(), Value::from(workspace));
        params.insert("index".to_string(), Value::from(index));
        self.request::<Empty>("move-workspace", params).map(|_| ())
    }

    pub fn scroll_surface(&mut self, surface: u64, delta: isize) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("delta".to_string(), Value::from(delta));
        self.request::<Empty>("scroll-surface", params).map(|_| ())
    }

    pub fn subscribe(&mut self) -> Result<MuxStream> {
        self.open_stream("subscribe", Map::new())
    }

    pub fn attach_surface(&mut self, surface: u64) -> Result<MuxStream> {
        let protocol = match self.protocol {
            Some(protocol) => protocol,
            None => self.identify()?.protocol,
        };
        if protocol > 6 || (protocol > 5 && !self.config.allow_protocol_v6_attach) {
            return Err(MuxError::ProtocolVersion(format!(
                "unsupported attach protocol {protocol}"
            )));
        }
        self.open_stream("attach-surface", surface_params(surface))
    }

    fn open_stream(&mut self, cmd: &str, mut params: Map<String, Value>) -> Result<MuxStream> {
        let id = self.next_id();
        params.insert("id".to_string(), Value::from(id));
        params.insert("cmd".to_string(), Value::from(cmd));
        MuxStream::open(&self.config.socket_path, self.config.timeout, Value::Object(params))
    }

    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}

pub struct MuxStream {
    conn: JsonLineConnection,
    buffered: Vec<Event>,
}

impl MuxStream {
    fn open(socket_path: &PathBuf, timeout: Duration, request: Value) -> Result<Self> {
        let mut conn = JsonLineConnection::connect(socket_path, timeout)?;
        let request_id = request.get("id").cloned();
        conn.send(&request)?;
        let mut buffered = Vec::new();
        loop {
            let response = conn.recv()?;
            if response.get("event").is_some() {
                buffered.push(parse_event(response));
                continue;
            }
            if response.get("id") != request_id.as_ref() {
                continue;
            }
            if response.get("ok") == Some(&Value::Bool(true)) {
                return Ok(Self { conn, buffered });
            }
            return Err(MuxError::Command {
                message: response
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error")
                    .to_string(),
                id: response.get("id").cloned(),
            });
        }
    }

    pub fn recv(&mut self) -> Result<Event> {
        if !self.buffered.is_empty() {
            return Ok(self.buffered.remove(0));
        }
        loop {
            let value = self.conn.recv()?;
            if value.get("event").is_some() {
                return Ok(parse_event(value));
            }
        }
    }

    pub fn recv_timeout(&mut self, timeout: Duration) -> Result<Event> {
        if !self.buffered.is_empty() {
            return Ok(self.buffered.remove(0));
        }
        self.conn.with_read_timeout(timeout, |conn| loop {
            let value = conn.recv()?;
            if value.get("event").is_some() {
                return Ok(parse_event(value));
            }
        })
    }
}

impl Iterator for MuxStream {
    type Item = Result<Event>;

    fn next(&mut self) -> Option<Self::Item> {
        Some(self.recv())
    }
}

struct JsonLineConnection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl JsonLineConnection {
    fn connect(socket_path: &PathBuf, timeout: Duration) -> Result<Self> {
        let stream = UnixStream::connect(socket_path).map_err(|err| {
            MuxError::Connection(format!(
                "cannot connect to session socket {}: {err}",
                socket_path.display()
            ))
        })?;
        stream
            .set_read_timeout(Some(timeout))
            .map_err(|err| MuxError::Connection(format!("set read timeout failed: {err}")))?;
        stream
            .set_write_timeout(Some(timeout))
            .map_err(|err| MuxError::Connection(format!("set write timeout failed: {err}")))?;
        let writer = stream
            .try_clone()
            .map_err(|err| MuxError::Connection(format!("socket clone failed: {err}")))?;
        Ok(Self { writer, reader: BufReader::new(stream) })
    }

    fn send(&mut self, value: &Value) -> Result<()> {
        let mut encoded =
            serde_json::to_vec(value).map_err(|err| MuxError::Decode(err.to_string()))?;
        encoded.push(b'\n');
        self.writer
            .write_all(&encoded)
            .map_err(|err| MuxError::Connection(format!("socket write failed: {err}")))
    }

    fn recv(&mut self) -> Result<Value> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => Err(MuxError::Connection("session socket closed".to_string())),
            Ok(_) => serde_json::from_str(&line).map_err(|err| MuxError::Decode(err.to_string())),
            Err(err)
                if err.kind() == std::io::ErrorKind::WouldBlock
                    || err.kind() == std::io::ErrorKind::TimedOut =>
            {
                Err(MuxError::Timeout("session did not respond".to_string()))
            }
            Err(err) => Err(MuxError::Connection(format!("socket read failed: {err}"))),
        }
    }

    fn with_read_timeout<T>(
        &mut self,
        timeout: Duration,
        operation: impl FnOnce(&mut Self) -> Result<T>,
    ) -> Result<T> {
        let previous =
            self.reader.get_ref().read_timeout().map_err(|err| {
                MuxError::Connection(format!("read timeout lookup failed: {err}"))
            })?;
        self.reader
            .get_ref()
            .set_read_timeout(Some(timeout))
            .map_err(|err| MuxError::Connection(format!("set read timeout failed: {err}")))?;
        let result = operation(self);
        let restore = self
            .reader
            .get_ref()
            .set_read_timeout(previous)
            .map_err(|err| MuxError::Connection(format!("restore read timeout failed: {err}")));
        match (result, restore) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(err), _) => Err(err),
            (Ok(_), Err(err)) => Err(err),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Empty {}

fn parse_event(value: Value) -> Event {
    let event = value.get("event").and_then(Value::as_str).unwrap_or_default();
    match event {
        "tree-changed" => Event::TreeChanged,
        "surface-output" => parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceOutput),
        "surface-resized" => parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceResized),
        "surface-exited" => parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceExited),
        "title-changed" => parse_typed(value).map_or_else(Event::Unknown, Event::TitleChanged),
        "bell" => parse_typed(value).map_or_else(Event::Unknown, Event::Bell),
        "empty" => Event::Empty,
        "vt-state" => parse_typed(value).map_or_else(Event::Unknown, Event::VtState),
        "output" => parse_typed(value).map_or_else(Event::Unknown, Event::Output),
        "resized" => parse_typed(value).map_or_else(Event::Unknown, Event::Resized),
        "detached" => parse_typed(value).map_or_else(Event::Unknown, Event::Detached),
        _ => Event::Unknown(value),
    }
}

fn parse_typed<T: for<'de> Deserialize<'de>>(value: Value) -> std::result::Result<T, Value> {
    serde_json::from_value(value.clone()).map_err(|_| value)
}

fn surface_params(surface: u64) -> Map<String, Value> {
    let mut params = Map::new();
    params.insert("surface".to_string(), Value::from(surface));
    params
}

fn insert_opt<T: Serialize>(params: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        params.insert(
            key.to_string(),
            serde_json::to_value(value).expect("serializing command parameter must not fail"),
        );
    }
}

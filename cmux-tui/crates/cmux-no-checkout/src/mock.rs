//! A GitHub stand-in on loopback with the routes this crate calls (feature `mock`): the
//! repository, a branch, a recursive tree, blobs, and the git data and pull request writes. Tests
//! read back what a branch holds; the bench counts the bytes each way. Its tasks belong to its
//! [`cmux_scope::Scope`]: [`Mock::close`] ends them.

use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash as _, Hasher as _};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::net::{TcpListener, TcpStream};

type Files = BTreeMap<String, (String, String)>;

#[derive(Default)]
struct State {
    blobs: HashMap<String, Vec<u8>>,
    trees: HashMap<String, Files>,
    commits: HashMap<String, (String, Option<String>, String)>,
    refs: BTreeMap<String, String>,
    pulls: Vec<Value>,
    next: u64,
}

impl State {
    fn id(&mut self, seed: &[u8]) -> String {
        self.next += 1;
        let mut h = std::collections::hash_map::DefaultHasher::new();
        seed.hash(&mut h);
        self.next.hash(&mut h);
        format!("{:016x}{:024x}", h.finish(), self.next)
    }
}

/// What every connection shares.
struct Shared {
    state: Mutex<State>,
    up: AtomicU64,
    down: AtomicU64,
    prefix: String,
}

/// A running stand-in.
pub struct Mock {
    pub url: String,
    pub repo: String,
    shared: Arc<Shared>,
    scope: cmux_scope::Scope,
    /// The connections' tasks, a child of `scope`.
    conns: Arc<cmux_scope::Scope>,
}

impl Mock {
    /// A repository `repo` whose `main` holds `files` (path to bytes and mode).
    pub async fn start(repo: &str, files: &[(&str, &[u8], &str)]) -> std::io::Result<Self> {
        let mut state = State::default();
        let mut tree = Files::new();
        for (path, bytes, mode) in files {
            let id = state.id(bytes);
            state.blobs.insert(id.clone(), bytes.to_vec());
            tree.insert((*path).to_owned(), (id, (*mode).to_owned()));
        }
        let tree_id = state.id(b"tree");
        state.trees.insert(tree_id.clone(), tree);
        let commit = state.id(b"commit");
        state.commits.insert(commit.clone(), (tree_id, None, "base".to_owned()));
        state.refs.insert("main".to_owned(), commit);
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}", listener.local_addr()?);
        let shared = Arc::new(Shared {
            state: Mutex::new(state),
            up: AtomicU64::new(0),
            down: AtomicU64::new(0),
            prefix: format!("/repos/{repo}"),
        });
        let scope = cmux_scope::Scope::new("cmux-no-checkout mock");
        let conns = Arc::new(scope.child("mock connection"));
        let (accepts, serving, stop) = (Arc::clone(&shared), Arc::clone(&conns), scope.cancelled());
        scope.spawn_named("mock accept", async move {
            tokio::select! {
                () = stop => {}
                () = async {
                    while let Ok((stream, _)) = listener.accept().await {
                        let (shared, stop) = (Arc::clone(&accepts), serving.cancelled());
                        serving.spawn_named("mock serve", async move {
                            tokio::select! {
                                () = stop => {}
                                () = serve(stream, &shared) => {}
                            }
                        });
                    }
                } => {}
            }
        });
        Ok(Self { url, repo: repo.to_owned(), shared, scope, conns })
    }

    /// Stops serving and joins every task.
    pub async fn close(self) {
        let _ = self.scope.close(Duration::from_secs(5)).await;
        let _ = self.conns.close(Duration::from_secs(1)).await;
    }

    /// Bytes the client sent (request lines, headers, bodies).
    #[must_use]
    pub fn bytes_up(&self) -> u64 {
        self.shared.up.load(Ordering::Relaxed)
    }

    /// Bytes this stand-in answered.
    #[must_use]
    pub fn bytes_down(&self) -> u64 {
        self.shared.down.load(Ordering::Relaxed)
    }

    /// What `branch` holds now: path to bytes and mode, or `None` with no such branch.
    #[must_use]
    pub fn branch(&self, branch: &str) -> Option<BTreeMap<String, (Vec<u8>, String)>> {
        let state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        let commit = state.refs.get(branch)?;
        let tree = &state.trees[&state.commits[commit].0];
        Some(
            tree.iter()
                .map(|(path, (blob, mode))| {
                    (path.clone(), (state.blobs[blob].clone(), mode.clone()))
                })
                .collect(),
        )
    }

    /// The pull requests opened so far.
    #[must_use]
    pub fn pulls(&self) -> Vec<Value> {
        self.shared.state.lock().unwrap_or_else(PoisonError::into_inner).pulls.clone()
    }
}

async fn serve(stream: TcpStream, shared: &Shared) {
    let (read, mut writer) = stream.into_split();
    let mut reader = BufReader::new(read);
    loop {
        let mut head = String::new();
        let mut length = 0usize;
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line).await {
                Ok(0) | Err(_) => return,
                Ok(n) => shared.up.fetch_add(n as u64, Ordering::Relaxed),
            };
            if line == "\r\n" {
                break;
            }
            if let Some((k, v)) = line.split_once(':')
                && k.eq_ignore_ascii_case("content-length")
            {
                length = v.trim().parse().unwrap_or(0);
            }
            if head.is_empty() {
                head = line;
            }
        }
        let mut body = vec![0u8; length];
        if reader.read_exact(&mut body).await.is_err() {
            return;
        }
        shared.up.fetch_add(length as u64, Ordering::Relaxed);
        let mut parts = head.split_whitespace();
        let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        let (status, bytes, kind) = {
            let mut state = shared.state.lock().unwrap_or_else(PoisonError::into_inner);
            route(
                &mut state,
                method,
                target.strip_prefix(shared.prefix.as_str()).unwrap_or("!"),
                &body,
            )
        };
        let reply = format!(
            "HTTP/1.1 {status} X\r\ncontent-type: {kind}\r\ncontent-length: {}\r\n\r\n",
            bytes.len()
        );
        shared.down.fetch_add((reply.len() + bytes.len()) as u64, Ordering::Relaxed);
        if writer.write_all(reply.as_bytes()).await.is_err()
            || writer.write_all(&bytes).await.is_err()
        {
            return;
        }
    }
}

fn ok(v: &Value) -> (u16, Vec<u8>, &'static str) {
    (200, v.to_string().into_bytes(), "application/json")
}

fn missing() -> (u16, Vec<u8>, &'static str) {
    (404, br#"{"message":"Not Found"}"#.to_vec(), "application/json")
}

fn route(
    state: &mut State,
    method: &str,
    path: &str,
    body: &Value,
) -> (u16, Vec<u8>, &'static str) {
    let (path, _query) = path.split_once('?').unwrap_or((path, ""));
    match (method, path) {
        ("GET", "") => ok(&json!({"default_branch": "main"})),
        ("GET", p) if p.starts_with("/branches/") => {
            let Some(commit) = state.refs.get(&p["/branches/".len()..]) else { return missing() };
            let tree = &state.commits[commit].0;
            ok(&json!({"commit": {"sha": commit, "commit": {"tree": {"sha": tree}}}}))
        }
        ("GET", p) if p.starts_with("/git/trees/") => {
            let Some(tree) = state.trees.get(&p["/git/trees/".len()..]) else { return missing() };
            let entries: Vec<Value> = tree
                .iter()
                .map(|(path, (blob, mode))| {
                    let size = state.blobs[blob].len();
                    json!({"path": path, "mode": mode, "type": "blob", "sha": blob, "size": size})
                })
                .collect();
            ok(&json!({"tree": entries, "truncated": false}))
        }
        ("GET", p) if p.starts_with("/git/blobs/") => {
            match state.blobs.get(&p["/git/blobs/".len()..]) {
                Some(bytes) => (200, bytes.clone(), "application/octet-stream"),
                None => missing(),
            }
        }
        ("POST", "/git/blobs") => {
            let content = body["content"].as_str().unwrap_or_default();
            let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(content) else {
                return (422, b"{}".to_vec(), "application/json");
            };
            let id = state.id(&bytes);
            state.blobs.insert(id.clone(), bytes);
            ok(&json!({"sha": id}))
        }
        ("POST", "/git/trees") => {
            let Some(mut tree) =
                body["base_tree"].as_str().and_then(|b| state.trees.get(b)).cloned()
            else {
                return (422, b"{}".to_vec(), "application/json");
            };
            for entry in body["tree"].as_array().into_iter().flatten() {
                let path = entry["path"].as_str().unwrap_or_default().to_owned();
                match entry["sha"].as_str() {
                    Some(sha) if state.blobs.contains_key(sha) => {
                        let mode = entry["mode"].as_str().unwrap_or("100644").to_owned();
                        tree.insert(path, (sha.to_owned(), mode));
                    }
                    Some(_) => return (422, b"{}".to_vec(), "application/json"),
                    None => {
                        tree.remove(&path);
                    }
                }
            }
            let id = state.id(b"tree");
            state.trees.insert(id.clone(), tree);
            ok(&json!({"sha": id}))
        }
        ("POST", "/git/commits") => {
            let tree = body["tree"].as_str().unwrap_or_default().to_owned();
            let parent = body["parents"][0].as_str().map(str::to_owned);
            if !state.trees.contains_key(&tree) {
                return (422, b"{}".to_vec(), "application/json");
            }
            let id = state.id(b"commit");
            let message = body["message"].as_str().unwrap_or_default().to_owned();
            state.commits.insert(id.clone(), (tree, parent, message));
            ok(&json!({"sha": id}))
        }
        ("POST", "/git/refs") => {
            let name = body["ref"].as_str().unwrap_or_default();
            let Some(branch) = name.strip_prefix("refs/heads/") else {
                return (422, b"{}".to_vec(), "application/json");
            };
            if state.refs.contains_key(branch) {
                return (
                    422,
                    br#"{"message":"Reference already exists"}"#.to_vec(),
                    "application/json",
                );
            }
            let sha = body["sha"].as_str().unwrap_or_default().to_owned();
            state.refs.insert(branch.to_owned(), sha);
            ok(&json!({"ref": name}))
        }
        ("PATCH", p) if p.starts_with("/git/refs/heads/") => {
            let branch = &p["/git/refs/heads/".len()..];
            let sha = body["sha"].as_str().unwrap_or_default().to_owned();
            // Fast-forward only: the new commit's parent is the branch's head.
            let head = state.refs.get(branch).cloned();
            if head.is_none() || state.commits.get(&sha).and_then(|c| c.1.clone()) != head {
                return (
                    422,
                    br#"{"message":"Update is not a fast forward"}"#.to_vec(),
                    "application/json",
                );
            }
            state.refs.insert(branch.to_owned(), sha);
            ok(&json!({}))
        }
        ("DELETE", p) if p.starts_with("/git/refs/heads/") => {
            match state.refs.remove(&p["/git/refs/heads/".len()..]) {
                Some(_) => (204, Vec::new(), "application/json"),
                None => missing(),
            }
        }
        ("POST", "/pulls") => {
            let number = state.pulls.len() as u64 + 1;
            let mut pull = body.clone();
            pull["number"] = json!(number);
            pull["state"] = json!("open");
            pull["html_url"] = json!(format!("https://github.invalid/pull/{number}"));
            state.pulls.push(pull.clone());
            ok(&pull)
        }
        ("PATCH", p) if p.starts_with("/pulls/") => {
            let number: usize = p["/pulls/".len()..].parse().unwrap_or(0);
            match state.pulls.get_mut(number.wrapping_sub(1)) {
                Some(pull) => {
                    pull["state"] = body["state"].clone();
                    ok(pull)
                }
                None => missing(),
            }
        }
        _ => missing(),
    }
}

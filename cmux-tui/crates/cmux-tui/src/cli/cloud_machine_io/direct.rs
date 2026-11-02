//! The direct route: Freestyle's `exec-await` with the machine's client session
//! (`x-freestyle-identity-access-token`), as its work user.
//!
//! Freestyle lets an identity token call only a VM's exec and PTY routes; its
//! `/fs/*` routes answer `403 forbidden: identity tokens may only use VM exec
//! and PTY routes`. So the file operations run as one Python program through
//! exec, the same way the cmux API's own file routes run them
//! (cmux-platform `src/server/cloud/MachineGuest.ts` `FS_PROGRAM`), with the
//! same answers and exit codes. Two differences, both because this runs as the
//! work user, not root: a path the work user may not touch, or an existing file
//! someone else owns (whose owner a root write keeps), exits [`NEEDS_ROOT`] and
//! the caller takes the proxied route instead; and a file larger than one exec's
//! stdin (1 MiB) is staged in chunks, then renamed over the target once its
//! sha256 matches, so a write is still atomic and has no size cap.

use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::cloud_client_session::{ExecAnswer, IDENTITY_HEADER, exec_answer};
use super::{Answer, Op, Request};

/// The program's exit codes (44 to 47 as the cmux API's file routes use them).
const NOT_FOUND: i32 = 44;
const WRONG_KIND: i32 = 45;
const TOO_LARGE: i32 = 46;
const ROOT: i32 = 47;
/// The work user may not do it; root (the proxied route) may.
pub(super) const NEEDS_ROOT: i32 = 48;
/// A staged write whose bytes do not match the sha256 they were sent with.
const CORRUPT: i32 = 49;
/// The file changed while one ranged read read it.
const CHANGED: i32 = 50;
/// How many times a read starts over when the file changes between its chunks.
const READ_TRIES: usize = 3;

/// Freestyle's limit on one exec's stdin (decoded).
pub(super) const STDIN_MAX: usize = 1024 * 1024;
/// One ranged read's bytes (its base64 is a third larger in the exec's stdout).
pub(super) const READ_CHUNK: u64 = 4 * 1024 * 1024;
/// The cmux API's limits, kept so both routes answer alike.
const DIR_MAX_ENTRIES: u32 = 10_000;
const DIR_MAX_BYTES: u32 = 2 * 1024 * 1024;
const OUTPUT_MAX_BYTES: u32 = 1024 * 1024;
pub(super) const COMMAND_MAX_BYTES: usize = 64 * 1024;
pub(super) const EXEC_DEFAULT_MS: u64 = 30_000;
/// Freestyle's inline exec limit (five minutes).
pub(super) const EXEC_MAX_MS: u64 = 300_000;
const FS_TIMEOUT_MS: u64 = 60_000;

/// The file program. argv: op, path, then the op's own arguments:
/// `read OFFSET LIMIT`, `write [MODE]` (stdin: the bytes), `stage` (prints a staging
/// file beside the path), `append OFFSET` (path: the staging file; stdin: the chunk),
/// `commit STAGE SHA256 [MODE]`, `abort` (path: the staging file).
pub(super) const FS_PROGRAM: &str = r#"import base64,hashlib,json,os,shutil,stat,sys,tempfile
op,p=sys.argv[1],sys.argv[2]
DN,DB=%DN%,%DB%
P=".cmux-write-"
def k(m):return "directory" if stat.S_ISDIR(m) else "symlink" if stat.S_ISLNK(m) else "file"
def i(s):return {"kind":k(s.st_mode),"size":s.st_size,"mode":stat.S_IMODE(s.st_mode),"modifiedAt":int(s.st_mtime*1000)}
def old(q):
 try:s=os.stat(q)
 except FileNotFoundError:return None
 if stat.S_ISDIR(s.st_mode):sys.exit(%WRONG_KIND%)
 if s.st_uid!=os.getuid():sys.exit(%NEEDS_ROOT%)
 return s
def staged(q,d):
 if os.path.dirname(q)!=d or not os.path.basename(q).startswith(P):sys.exit(%WRONG_KIND%)
 s=os.lstat(q)
 if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid():sys.exit(%WRONG_KIND%)
def mode(a,o):return int(a) if a else (stat.S_IMODE(o.st_mode) if o else 0o600)
def done(t,q,m,o):
 if o and os.stat(t).st_gid!=o.st_gid:os.chown(t,-1,o.st_gid)
 os.chmod(t,m)
 fd=os.open(t,os.O_RDONLY)
 try:os.fsync(fd)
 finally:os.close(fd)
 os.replace(t,q)
try:
 if op=="stat":o={"path":p,**i(os.lstat(p))}
 elif op=="dir":
  e=[];n=16
  with os.scandir(p) as d:
   for x in d:
    if len(e)>=DN:sys.exit(%TOO_LARGE%)
    y={"name":x.name,**i(x.stat(follow_symlinks=False))}
    n+=len(json.dumps(y))+2
    if n>DB:sys.exit(%TOO_LARGE%)
    e.append(y)
  o={"entries":e}
 elif op=="read":
  s=os.stat(p)
  if stat.S_ISDIR(s.st_mode):sys.exit(%WRONG_KIND%)
  with open(p,"rb") as f:
   s=os.fstat(f.fileno());f.seek(int(sys.argv[3]));b=f.read(int(sys.argv[4]))
   v=os.fstat(f.fileno())
  w=lambda s:"%d:%d:%d:%d:%d"%(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
  if w(s)!=w(v):sys.exit(%CHANGED%)
  o={"path":p,"dataBase64":base64.b64encode(b).decode(),"size":len(b),"total":s.st_size,"version":w(s)}
 elif op=="write":
  b=sys.stdin.buffer.read();s=old(p);m=mode(sys.argv[3] if len(sys.argv)>3 else None,s)
  fd,t=tempfile.mkstemp(dir=os.path.dirname(p),prefix=P)
  try:
   with os.fdopen(fd,"wb") as f:f.write(b)
   done(t,p,m,s)
  except BaseException:
   try:os.unlink(t)
   except OSError:pass
   raise
  o={"ok":True,"path":p}
 elif op=="stage":
  old(p);fd,t=tempfile.mkstemp(dir=os.path.dirname(p),prefix=P);os.close(fd)
  o={"stage":t}
 elif op=="append":
  staged(p,os.path.dirname(p))
  with open(p,"r+b") as f:
   f.seek(int(sys.argv[3]));f.write(sys.stdin.buffer.read());f.truncate()
  o={"ok":True}
 elif op=="commit":
  t=sys.argv[3];staged(t,os.path.dirname(p));s=old(p)
  h=hashlib.sha256()
  with open(t,"rb") as f:
   for c in iter(lambda:f.read(1<<20),b""):h.update(c)
  if h.hexdigest()!=sys.argv[4]:
   os.unlink(t);sys.exit(%CORRUPT%)
  done(t,p,mode(sys.argv[5] if len(sys.argv)>5 else None,s),s)
  o={"ok":True,"path":p}
 elif op=="abort":
  staged(p,os.path.dirname(p));os.unlink(p)
  o={"ok":True}
 elif op=="mkdir":
  os.makedirs(p,exist_ok=True)
  o={"ok":True,"path":p}
 elif op=="remove":
  q=os.path.normpath(p)
  if os.path.realpath(q)=="/":sys.exit(%ROOT%)
  s=os.lstat(q)
  if stat.S_ISDIR(s.st_mode):shutil.rmtree(q)
  else:os.unlink(q)
  o={"ok":True,"path":p}
 else:sys.exit(2)
except PermissionError:sys.exit(%NEEDS_ROOT%)
except FileNotFoundError:sys.exit(%NOT_FOUND%)
except (NotADirectoryError,IsADirectoryError,FileExistsError):sys.exit(%WRONG_KIND%)
sys.stdout.write(json.dumps(o))
"#;

/// Runs `bash -c argv[2]` with its output capped (the cmux API's `OUTPUT_CAP_PROGRAM`,
/// unchanged): at most argv[1] bytes of each stream, and it ends half a second after the
/// command exits even when a child the command left running still holds the pipes.
const OUTPUT_CAP_PROGRAM: &str = r#"import os,selectors,subprocess,sys,time
n=int(sys.argv[1])
p=subprocess.Popen(["bash","-c",sys.argv[2]],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def wr(f,b):
 while b:b=b[os.write(f,b):]
o={p.stdout.fileno():[1,0],p.stderr.fileno():[2,0]}
cut=False
s=selectors.DefaultSelector()
for f in o:
 os.set_blocking(f,False);s.register(f,selectors.EVENT_READ)
end=None
while s.get_map():
 if end is None and p.poll() is not None:end=time.monotonic()+0.5
 if end is not None and time.monotonic()>=end:break
 for k,_ in s.select(0.1):
  try:d=os.read(k.fd,65536)
  except BlockingIOError:continue
  if not d:
   s.unregister(k.fd);continue
  w=o[k.fd]
  if w[1]+len(d)>n:cut=True
  keep=d[:max(0,n-w[1])]
  if keep:
   wr(w[0],keep);w[1]+=len(keep)
r=p.wait()
if cut:wr(2,b"\ncmux: output cut at %d bytes per stream\n"%n)
sys.exit(r if r>=0 else 128-r)
"#;

/// The session the direct route uses (a cached or fresh client session).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(super) struct Grant {
    pub(super) vm_id: String,
    pub(super) linux_user: String,
    pub(super) token: String,
    pub(super) api_base_url: String,
}

/// What the direct route did.
#[derive(Debug)]
pub(super) enum Direct {
    /// The machine answered; this is the answer (a file error included).
    Done(Answer),
    /// Freestyle refused the token (401 or 403): mint again, or take the proxy.
    Auth,
    /// Nothing ran that could have changed the machine, or what did is safe to run again
    /// through the proxy (a refused path, an unreachable or busy provider).
    Fallback,
}

/// Why one exec gave no answer.
#[derive(Debug, PartialEq, Eq)]
enum Failure {
    Auth,
    /// The request never left (no connection): nothing ran.
    NotSent,
    /// Any other status, or an answer that is not Freestyle's: the command may have run.
    Unavailable,
}

pub(super) fn quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', r"'\''"))
}

/// The shell line that runs the file program for `op` with `args`.
pub(super) fn fs_command(op: &str, path: &str, args: &[String]) -> String {
    let program = FS_PROGRAM
        .replace("%DN%", &DIR_MAX_ENTRIES.to_string())
        .replace("%DB%", &DIR_MAX_BYTES.to_string())
        .replace("%NOT_FOUND%", &NOT_FOUND.to_string())
        .replace("%WRONG_KIND%", &WRONG_KIND.to_string())
        .replace("%TOO_LARGE%", &TOO_LARGE.to_string())
        .replace("%ROOT%", &ROOT.to_string())
        .replace("%NEEDS_ROOT%", &NEEDS_ROOT.to_string())
        .replace("%CORRUPT%", &CORRUPT.to_string())
        .replace("%CHANGED%", &CHANGED.to_string());
    let mut words =
        vec!["python3".to_owned(), "-c".to_owned(), quote(&program), op.to_owned(), quote(path)];
    words.extend(args.iter().map(|a| quote(a)));
    words.join(" ")
}

pub(super) fn exec_command(command: &str) -> String {
    format!("python3 -c {} {OUTPUT_MAX_BYTES} {}", quote(OUTPUT_CAP_PROGRAM), quote(command))
}

async fn exec(
    client: &reqwest::Client,
    grant: &Grant,
    command: &str,
    stdin: Option<&[u8]>,
    timeout_ms: u64,
) -> Result<ExecAnswer, Failure> {
    let url =
        format!("{}/v5/vms/{}/exec-await", grant.api_base_url.trim_end_matches('/'), grant.vm_id);
    let mut body = serde_json::Map::new();
    body.insert("command".into(), json!(command));
    body.insert("linuxUser".into(), json!(grant.linux_user));
    body.insert("timeoutMs".into(), json!(timeout_ms));
    if let Some(stdin) = stdin {
        body.insert("stdin".into(), json!(BASE64.encode(stdin)));
    }
    let response = client
        .post(url)
        .header(IDENTITY_HEADER, &grant.token)
        .timeout(Duration::from_millis(timeout_ms).saturating_add(Duration::from_secs(15)))
        .json(&body)
        .send()
        .await
        .map_err(|e| if e.is_connect() { Failure::NotSent } else { Failure::Unavailable })?;
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        return Err(Failure::Auth);
    }
    let body: Option<Value> = response.json().await.ok();
    if status != 200 {
        return Err(Failure::Unavailable);
    }
    exec_answer(body).map_err(|_| Failure::Unavailable)
}

/// Whether a file program op changes what the caller asked about. Only these are never replayed
/// through the proxy once they may have run: a replay could undo a change someone made after the
/// first run did its work. `stage`, `append` and `abort` touch only this call's own staging file.
fn changes_target(op: &str) -> bool {
    matches!(op, "write" | "commit" | "mkdir" | "remove")
}

/// One file program run. `Ok(value)` is its JSON answer; `Err` is what the caller does.
async fn fs(
    client: &reqwest::Client,
    grant: &Grant,
    op: &str,
    path: &str,
    args: &[String],
    stdin: Option<&[u8]>,
) -> Result<Value, Direct> {
    let answer = match exec(client, grant, &fs_command(op, path, args), stdin, FS_TIMEOUT_MS).await
    {
        Ok(answer) => answer,
        Err(Failure::Auth) => return Err(Direct::Auth),
        // Nothing ran, or what may have run changed nothing the caller can see: the proxy runs it.
        Err(Failure::NotSent) => return Err(Direct::Fallback),
        Err(Failure::Unavailable) if !changes_target(op) => return Err(Direct::Fallback),
        // A change that may have been made is reported, never made a second time.
        Err(Failure::Unavailable) => {
            return Err(Direct::Done(Answer::error(
                502,
                "vm_unavailable",
                "the machine did not answer; the change may have been made",
            )));
        }
    };
    let refuse = |status, code: &str, message: String| {
        Err(Direct::Done(Answer::error(status, code, &message)))
    };
    match answer.exit_code {
        0 => {}
        // The program checks before it changes anything; a remove or mkdir stopped part way by a
        // root-owned entry is finished by the proxy, as root would have done it whole.
        NEEDS_ROOT | CHANGED => return Err(Direct::Fallback),
        NOT_FOUND => return refuse(404, "vm_file_not_found", format!("no such file: {path}")),
        ROOT if op == "remove" => {
            return refuse(400, "vm_invalid_path", "the path is the machine's root".into());
        }
        WRONG_KIND => {
            let message = if op == "dir" {
                "not a directory"
            } else {
                "the path is a directory, or a part of it is a file"
            };
            return refuse(400, "vm_invalid_path", message.into());
        }
        TOO_LARGE => {
            let message = format!(
                "the directory has over {DIR_MAX_ENTRIES} entries, or its listing is over {DIR_MAX_BYTES} bytes"
            );
            return refuse(413, "vm_file_too_large", message);
        }
        CORRUPT => {
            return refuse(
                502,
                "vm_file_operation_failed",
                "the file changed on its way to the machine".into(),
            );
        }
        _ => {}
    }
    match serde_json::from_str::<Value>(&answer.stdout) {
        Ok(value) if answer.exit_code == 0 && value.is_object() => Ok(value),
        _ => {
            let tail = if answer.stderr.is_empty() { &answer.stdout } else { &answer.stderr };
            let tail: String =
                tail.chars().rev().take(500).collect::<Vec<_>>().into_iter().rev().collect();
            let message = if tail.is_empty() {
                format!("the file operation exited {}", answer.exit_code)
            } else {
                tail
            };
            refuse(502, "vm_file_operation_failed", message)
        }
    }
}

/// Runs `request` (already checked: [`Request::direct_ready`]) on the machine as `grant`.
pub(super) async fn run(client: &reqwest::Client, grant: &Grant, request: &Request) -> Direct {
    let path = request.path.as_deref().unwrap_or_default();
    let mode = request.mode.map(|m| m.to_string());
    let result = match request.op {
        Op::Stat => fs(client, grant, "stat", path, &[], None).await,
        Op::Dir => fs(client, grant, "dir", path, &[], None).await,
        Op::Mkdir => fs(client, grant, "mkdir", path, &[], None).await,
        Op::Remove => fs(client, grant, "remove", path, &[], None).await,
        Op::Read => read(client, grant, path).await,
        Op::Write => match request.data() {
            Some(data) => write(client, grant, path, &data, mode).await,
            None => return Direct::Fallback,
        },
        Op::Exec => return run_exec(client, grant, request).await,
    };
    match result {
        Ok(value) => Direct::Done(Answer::ok(value)),
        Err(direct) => direct,
    }
}

/// The file in ranged chunks, every chunk from the same version of it (device, inode, size and
/// change times, read from the open file). A file that changes between chunks is read again from
/// the start; one that keeps changing goes to the proxy, which reads it in one go.
async fn read(client: &reqwest::Client, grant: &Grant, path: &str) -> Result<Value, Direct> {
    'tries: for _ in 0..READ_TRIES {
        let (mut bytes, mut version) = (Vec::new(), None::<String>);
        loop {
            let args = [bytes.len().to_string(), READ_CHUNK.to_string()];
            let value = fs(client, grant, "read", path, &args, None).await?;
            let chunk = value
                .get("dataBase64")
                .and_then(Value::as_str)
                .and_then(|b| BASE64.decode(b).ok())
                .ok_or(Direct::Fallback)?;
            let total = value.get("total").and_then(Value::as_u64).ok_or(Direct::Fallback)?;
            let seen = value.get("version").and_then(Value::as_str).ok_or(Direct::Fallback)?;
            if version.as_deref().is_some_and(|v| v != seen) {
                continue 'tries;
            }
            version = Some(seen.to_owned());
            let empty = chunk.is_empty();
            bytes.extend_from_slice(&chunk);
            if empty || bytes.len() as u64 >= total {
                if bytes.len() as u64 != total {
                    continue 'tries;
                }
                return Ok(
                    json!({ "path": path, "dataBase64": BASE64.encode(&bytes), "size": bytes.len() }),
                );
            }
        }
    }
    Err(Direct::Fallback)
}

async fn write(
    client: &reqwest::Client,
    grant: &Grant,
    path: &str,
    data: &[u8],
    mode: Option<String>,
) -> Result<Value, Direct> {
    if data.len() <= STDIN_MAX {
        return fs(client, grant, "write", path, &mode.into_iter().collect::<Vec<_>>(), Some(data))
            .await;
    }
    let staged = fs(client, grant, "stage", path, &[], None).await?;
    let stage = staged.get("stage").and_then(Value::as_str).ok_or(Direct::Fallback)?.to_owned();
    let mut sent = 0;
    for chunk in data.chunks(STDIN_MAX) {
        if let Err(direct) =
            fs(client, grant, "append", &stage, &[sent.to_string()], Some(chunk)).await
        {
            let _ = fs(client, grant, "abort", &stage, &[], None).await;
            return Err(direct);
        }
        sent += chunk.len();
    }
    let digest: String = Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect();
    let args: Vec<String> = [stage.clone(), digest].into_iter().chain(mode).collect();
    let committed = fs(client, grant, "commit", path, &args, None).await;
    if committed.is_err() {
        let _ = fs(client, grant, "abort", &stage, &[], None).await;
    }
    committed
}

async fn run_exec(client: &reqwest::Client, grant: &Grant, request: &Request) -> Direct {
    let command = request.command.as_deref().unwrap_or_default();
    let timeout = request.exec_timeout_ms();
    match exec(client, grant, &exec_command(command), None, timeout).await {
        Ok(answer) => Direct::Done(Answer::ok(
            json!({ "exitCode": answer.exit_code, "stdout": answer.stdout, "stderr": answer.stderr }),
        )),
        Err(Failure::Auth) => Direct::Auth,
        // Only a command that never left may run again through the proxy.
        Err(Failure::NotSent) => Direct::Fallback,
        Err(Failure::Unavailable) => Direct::Done(Answer::error(
            502,
            "vm_unavailable",
            "the machine did not answer the command; it may have run",
        )),
    }
}

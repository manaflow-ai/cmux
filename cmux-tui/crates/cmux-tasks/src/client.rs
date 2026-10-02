//! Reaching the owner: the socket of a running `cmux-tasks serve`, or the
//! store in-process under its writer lock when no server runs. Either way
//! there is exactly one writer.

use std::io::{self, BufRead, BufReader, Write};

use cmux_tasks_core::ids::Principal;
use serde_json::Value;

use crate::engine::{Engine, system_clock};
use crate::owner::LocalOwner;
use crate::protocol::{ErrorBody, ErrorCode, Request, ServerLine};
use crate::store::OpenError;

pub enum Conn {
    #[cfg(unix)]
    Socket {
        reader: BufReader<std::os::unix::net::UnixStream>,
        writer: std::os::unix::net::UnixStream,
        next_id: u64,
    },
    InProcess {
        engine: Box<Engine>,
        actor: Principal,
    },
}

fn unreachable(message: impl Into<String>) -> ErrorBody {
    ErrorBody::new(ErrorCode::OwnerUnreachable, message)
}

impl Conn {
    /// Connect to the local owner: socket first, else open the store.
    pub fn open(
        owner: &LocalOwner,
        actor: &Principal,
        key_prefix: &str,
    ) -> Result<Self, ErrorBody> {
        #[cfg(unix)]
        if let Ok(stream) = std::os::unix::net::UnixStream::connect(&owner.socket) {
            let writer = stream.try_clone().map_err(|e| unreachable(e.to_string()))?;
            let mut conn = Conn::Socket { reader: BufReader::new(stream), writer, next_id: 0 };
            conn.send_line(&serde_json::json!({"hello": {"actor": actor}}))
                .map_err(|e| unreachable(e.to_string()))?;
            return Ok(conn);
        }
        match Engine::open(&owner.dir, &owner.team, key_prefix, system_clock()) {
            Ok(engine) => Ok(Conn::InProcess { engine: Box::new(engine), actor: actor.clone() }),
            Err(OpenError::Locked) => {
                Err(unreachable("the Tasks owner holds the store but its socket is not answering"))
            }
            Err(e) => Err(ErrorBody::new(ErrorCode::Internal, e.to_string())),
        }
    }

    /// Bound every later read on the socket (bounded `task watch`).
    pub fn set_deadline(&mut self, after: std::time::Duration) {
        #[cfg(unix)]
        if let Conn::Socket { reader, .. } = self {
            let _ = reader.get_ref().set_read_timeout(Some(after));
        }
        #[cfg(not(unix))]
        let _ = after;
    }

    pub fn is_in_process(&self) -> bool {
        matches!(self, Conn::InProcess { .. })
    }

    #[cfg(unix)]
    fn send_line(&mut self, value: &Value) -> io::Result<()> {
        if let Conn::Socket { writer, .. } = self {
            let mut text = serde_json::to_vec(value).map_err(io::Error::other)?;
            text.push(b'\n');
            writer.write_all(&text)?;
        }
        Ok(())
    }

    #[cfg(not(unix))]
    fn send_line(&mut self, _value: &Value) -> io::Result<()> {
        Ok(())
    }

    /// Next line from the owner (socket mode only).
    pub fn read_line(&mut self) -> Result<ServerLine, ErrorBody> {
        #[cfg(unix)]
        if let Conn::Socket { reader, .. } = self {
            let mut text = String::new();
            let n = reader.read_line(&mut text).map_err(|e| match e.kind() {
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => {
                    ErrorBody::new(ErrorCode::Timeout, "deadline passed")
                }
                _ => unreachable(e.to_string()),
            })?;
            if n == 0 {
                return Err(unreachable("the Tasks owner closed the connection"));
            }
            return serde_json::from_str(&text)
                .map_err(|e| ErrorBody::new(ErrorCode::Internal, format!("bad owner line: {e}")));
        }
        Err(ErrorBody::new(ErrorCode::Usage, "no socket connection"))
    }

    /// One request; returns the reply and the settled sequence.
    pub fn call(
        &mut self,
        op: &str,
        params: Value,
        key: Option<String>,
    ) -> Result<(Value, u64), ErrorBody> {
        match self {
            Conn::InProcess { engine, actor } => {
                let request = Request { id: 1, op: op.to_owned(), params, key, origin: None };
                let outcome = engine.handle(actor, request).map_err(|e| {
                    ErrorBody::new(ErrorCode::Internal, format!("log write failed: {e}"))
                })?;
                outcome.reply.map(|v| (v, outcome.settled.seq))
            }
            #[cfg(unix)]
            Conn::Socket { next_id, .. } => {
                *next_id += 1;
                let id = *next_id;
                let request = Request { id, op: op.to_owned(), params, key, origin: None };
                let value = serde_json::to_value(&request)
                    .map_err(|e| ErrorBody::new(ErrorCode::Internal, e.to_string()))?;
                self.send_line(&value).map_err(|e| unreachable(e.to_string()))?;
                let mut reply = None;
                loop {
                    match self.read_line()? {
                        ServerLine::Ok { id: rid, ok } if rid == id => reply = Some(Ok(ok)),
                        ServerLine::Err { id: rid, err } if rid == id || rid == 0 => {
                            reply = Some(Err(err));
                        }
                        ServerLine::Settled { settled } if settled.id == id => {
                            let reply = reply.unwrap_or_else(|| {
                                Err(ErrorBody::new(ErrorCode::Internal, "settled without a reply"))
                            });
                            return reply.map(|v| (v, settled.seq));
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}

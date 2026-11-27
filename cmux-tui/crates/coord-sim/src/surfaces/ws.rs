//! The smallest WebSocket client the relay target needs (RFC 6455 over a plain TCP stream, std only): the
//! upgrade, masked client frames, and reads of text, binary, ping and close. The crate stays serde-only, so a
//! bench tool builds in seconds without the cmux-tui workspace.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub struct Ws {
    stream: TcpStream,
    mask_state: u64,
}

pub enum Frame {
    Text(String),
    Binary(Vec<u8>),
    Closed,
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [
            chunk.first().copied().unwrap_or(0),
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

impl Ws {
    /// Opens `ws://addr/path`.
    pub fn connect(addr: &str, path: &str, seed: u64) -> Result<Ws, String> {
        let mut stream = TcpStream::connect(addr).map_err(|e| format!("connect {addr}: {e}"))?;
        stream.set_nodelay(true).map_err(|e| e.to_string())?;
        stream.set_read_timeout(Some(Duration::from_secs(20))).map_err(|e| e.to_string())?;
        let key = base64(&seed.to_le_bytes().repeat(2));
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: {addr}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        );
        stream.write_all(req.as_bytes()).map_err(|e| format!("upgrade write: {e}"))?;
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            let n = stream.read(&mut byte).map_err(|e| format!("upgrade read: {e}"))?;
            if n == 0 || head.len() > 8192 {
                return Err("upgrade: connection closed".into());
            }
            head.push(byte[0]);
        }
        let text = String::from_utf8_lossy(&head);
        if !text.starts_with("HTTP/1.1 101") {
            return Err(format!("upgrade refused: {}", text.lines().next().unwrap_or("")));
        }
        Ok(Ws { stream, mask_state: seed | 1 })
    }

    pub fn try_clone(&self) -> Result<Ws, String> {
        Ok(Ws {
            stream: self.stream.try_clone().map_err(|e| e.to_string())?,
            mask_state: self.mask_state ^ 0x55,
        })
    }

    pub fn set_read_timeout(&self, t: Option<Duration>) -> Result<(), String> {
        self.stream.set_read_timeout(t).map_err(|e| e.to_string())
    }

    pub fn shutdown(&self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }

    fn write_frame(&mut self, opcode: u8, payload: &[u8]) -> Result<(), String> {
        let mut out = Vec::with_capacity(payload.len() + 14);
        out.push(0x80 | opcode);
        let len = payload.len();
        if len < 126 {
            out.push(0x80 | len as u8);
        } else if len <= 0xffff {
            out.push(0x80 | 126);
            out.extend_from_slice(&(len as u16).to_be_bytes());
        } else {
            out.push(0x80 | 127);
            out.extend_from_slice(&(len as u64).to_be_bytes());
        }
        self.mask_state ^= self.mask_state << 13;
        self.mask_state ^= self.mask_state >> 7;
        self.mask_state ^= self.mask_state << 17;
        let mask = (self.mask_state as u32).to_be_bytes();
        out.extend_from_slice(&mask);
        out.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i & 3]));
        self.stream.write_all(&out).map_err(|e| format!("ws write: {e}"))
    }

    pub fn send_text(&mut self, text: &str) -> Result<(), String> {
        self.write_frame(0x1, text.as_bytes())
    }

    pub fn send_binary(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.write_frame(0x2, bytes)
    }

    pub fn close(&mut self) {
        let _ = self.write_frame(0x8, &1000u16.to_be_bytes());
        self.shutdown();
    }

    /// The next text or binary message; pings are answered, a close or EOF reads as `Closed`.
    pub fn read(&mut self) -> Result<Frame, String> {
        let mut message: Vec<u8> = Vec::new();
        let mut message_op = 0u8;
        loop {
            let mut h = [0u8; 2];
            if let Err(e) = self.stream.read_exact(&mut h) {
                return match e.kind() {
                    std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset => {
                        Ok(Frame::Closed)
                    }
                    _ => Err(format!("ws read: {e}")),
                };
            }
            let fin = h[0] & 0x80 != 0;
            let op = h[0] & 0x0f;
            let masked = h[1] & 0x80 != 0;
            let mut len = (h[1] & 0x7f) as u64;
            if len == 126 {
                let mut b = [0u8; 2];
                self.stream.read_exact(&mut b).map_err(|e| format!("ws read: {e}"))?;
                len = u16::from_be_bytes(b) as u64;
            } else if len == 127 {
                let mut b = [0u8; 8];
                self.stream.read_exact(&mut b).map_err(|e| format!("ws read: {e}"))?;
                len = u64::from_be_bytes(b);
            }
            if len > 64 * 1024 * 1024 {
                return Err(format!("ws read: frame of {len} bytes"));
            }
            let mut mask = [0u8; 4];
            if masked {
                self.stream.read_exact(&mut mask).map_err(|e| format!("ws read: {e}"))?;
            }
            let mut payload = vec![0u8; len as usize];
            self.stream.read_exact(&mut payload).map_err(|e| format!("ws read: {e}"))?;
            if masked {
                for (i, b) in payload.iter_mut().enumerate() {
                    *b ^= mask[i & 3];
                }
            }
            match op {
                0x8 => return Ok(Frame::Closed),
                0x9 => self.write_frame(0xA, &payload)?,
                0xA => {}
                0x0..=0x2 => {
                    if op != 0 {
                        message_op = op;
                    }
                    message.extend_from_slice(&payload);
                    if fin {
                        return Ok(if message_op == 0x1 {
                            Frame::Text(String::from_utf8_lossy(&message).into_owned())
                        } else {
                            Frame::Binary(message)
                        });
                    }
                }
                _ => return Err(format!("ws read: opcode {op}")),
            }
        }
    }
}

#[cfg(test)]
#[path = "ws_tests.rs"]
mod tests;

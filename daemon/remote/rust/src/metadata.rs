const MAX_OSC_BYTES: usize = 8192;

#[derive(Debug, Clone, Copy, Default)]
enum State {
    #[default]
    Ground,
    Esc,
    Osc,
    OscEsc,
}

#[derive(Debug, Default)]
pub struct OscTracker {
    state: State,
    buf: Vec<u8>,
    title: String,
    pwd: String,
}

impl OscTracker {
    pub fn feed(&mut self, data: &[u8]) {
        for &byte in data {
            match self.state {
                State::Ground => {
                    if byte == 0x1b {
                        self.state = State::Esc;
                    }
                }
                State::Esc => {
                    if byte == b']' {
                        self.buf.clear();
                        self.state = State::Osc;
                    } else {
                        self.state = State::Ground;
                    }
                }
                State::Osc => match byte {
                    0x07 => self.finish_osc(),
                    0x1b => self.state = State::OscEsc,
                    _ => self.push(byte),
                },
                State::OscEsc => {
                    if byte == b'\\' {
                        self.finish_osc();
                    } else {
                        self.push(0x1b);
                        self.push(byte);
                        self.state = State::Osc;
                    }
                }
            }
        }
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    pub fn pwd(&self) -> &str {
        &self.pwd
    }

    fn push(&mut self, byte: u8) {
        if self.buf.len() < MAX_OSC_BYTES {
            self.buf.push(byte);
        }
    }

    fn finish_osc(&mut self) {
        if let Ok(payload) = String::from_utf8(self.buf.clone()) {
            self.apply_payload(&payload);
        }
        self.buf.clear();
        self.state = State::Ground;
    }

    fn apply_payload(&mut self, payload: &str) {
        let Some((kind, value)) = payload.split_once(';') else {
            return;
        };
        match kind {
            "0" | "2" => {
                self.title.clear();
                self.title.push_str(value);
            }
            "7" => {
                if let Some(decoded) = decode_pwd(value) {
                    self.pwd = decoded;
                }
            }
            _ => {}
        }
    }
}

fn decode_pwd(value: &str) -> Option<String> {
    if value.is_empty() {
        return Some(String::new());
    }
    if value.starts_with('/') {
        return Some(percent_decode(value));
    }

    let (_, rest) = value.split_once("://")?;
    let slash = rest.find('/').unwrap_or(rest.len());
    if slash == rest.len() {
        return Some("/".to_string());
    }
    Some(percent_decode(&rest[slash..]))
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = Vec::with_capacity(input.len());
    let mut idx = 0;
    while idx < bytes.len() {
        if bytes[idx] == b'%' && idx + 2 < bytes.len() {
            let hi = from_hex(bytes[idx + 1]);
            let lo = from_hex(bytes[idx + 2]);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                output.push(hi << 4 | lo);
                idx += 3;
                continue;
            }
        }
        output.push(bytes[idx]);
        idx += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn from_hex(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::decode_pwd;

    #[test]
    fn decode_pwd_preserves_utf8_paths() {
        assert_eq!(
            decode_pwd("file:///tmp/caf%C3%A9").as_deref(),
            Some("/tmp/café")
        );
    }
}

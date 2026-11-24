//! `cmux keys` words: the verbs, names, hosts, targets and `use`'s key list.

use super::*;

/// An env name, as GitHub and shells take it: `[A-Z_][A-Z0-9_]*`, at most 80.
pub(in crate::cli) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name.chars().next().is_some_and(|c| c.is_ascii_uppercase() || c == '_')
        && name.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

/// A variable a command may get: any POSIX env name.
pub(super) fn valid_var(var: &str) -> bool {
    !var.is_empty()
        && var.len() <= 128
        && var.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && var.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

pub(super) fn name_arg(name: &str) -> Result<String, UsageError> {
    if valid_name(name) {
        Ok(name.to_owned())
    } else {
        Err(UsageError::new(format!(
            "{name:?} is not a key name: upper case letters, digits and _, starting with a letter or _ (at most 80)"
        )))
    }
}

/// `example.com,api.example.com`: lower case DNS names, each at most 253.
pub(super) fn parse_hosts(text: &str) -> Result<Vec<String>, UsageError> {
    let mut hosts = Vec::new();
    for host in text.split(',').map(str::trim).filter(|h| !h.is_empty()) {
        let host = host.to_ascii_lowercase();
        let ok = host.len() <= 253
            && host.split('.').all(|label| {
                !label.is_empty()
                    && label.len() <= 63
                    && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            });
        if !ok {
            return Err(UsageError::new(format!("--hosts: {host:?} is not a host name")));
        }
        if !hosts.contains(&host) {
            hosts.push(host);
        }
    }
    if hosts.is_empty() || hosts.len() > 16 {
        return Err(UsageError::new("--hosts takes 1 to 16 host names, comma separated"));
    }
    Ok(hosts)
}

pub(super) fn parse_duration(
    flag: &str,
    text: &str,
    max: Duration,
) -> Result<Duration, UsageError> {
    let bad = || UsageError::new(format!("{flag} {text:?}: expected a number and d, h or m"));
    let (number, unit) = text.split_at(text.len().saturating_sub(1));
    let n: u64 = number.parse().map_err(|_| bad())?;
    let seconds = match unit {
        "d" => n.checked_mul(86_400),
        "h" => n.checked_mul(3_600),
        "m" => n.checked_mul(60),
        _ => None,
    }
    .ok_or_else(bad)?;
    let duration = Duration::from_secs(seconds);
    if duration.is_zero() || duration > max {
        return Err(bad());
    }
    Ok(duration)
}

/// The flags every way of storing a key shares; `extra` takes the verb's own (true when taken).
pub(super) fn parse_put(
    name: &str,
    flags: &[String],
    mut extra: impl FnMut(
        &str,
        &mut dyn FnMut() -> Result<String, UsageError>,
    ) -> Result<bool, UsageError>,
) -> Result<Put, UsageError> {
    let mut put = Put {
        name: name_arg(name)?,
        purpose: None,
        hosts: Vec::new(),
        ttl: None,
        replace: false,
        asked_by: None,
        from_person: false,
    };
    let mut it = flags.iter();
    while let Some(flag) = it.next() {
        let mut value =
            || it.next().cloned().ok_or_else(|| UsageError::new(format!("{flag} needs a value")));
        match flag.as_str() {
            "--purpose" => {
                let text = value()?;
                if text.trim().is_empty() || text.chars().count() > MAX_PURPOSE_CHARS {
                    return Err(UsageError::new(format!(
                        "--purpose is 1 to {MAX_PURPOSE_CHARS} characters"
                    )));
                }
                put.purpose = Some(text.trim().to_owned());
            }
            "--hosts" => put.hosts = parse_hosts(&value()?)?,
            "--ttl" => put.ttl = Some(super::super::parse_ttl(&value()?)?),
            "--replace" => put.replace = true,
            // Explicit spelling of the default: the value comes on stdin.
            "--from-stdin" => {}
            "--from-person" => put.from_person = true,
            "--asked-by" => {
                let text = value()?;
                if text.is_empty() || text.len() > 200 {
                    return Err(UsageError::new("--asked-by is 1 to 200 bytes"));
                }
                put.asked_by = Some(text);
            }
            other => {
                if !extra(other, &mut value)? {
                    return Err(UsageError::new(format!("unknown flag {other:?}\nusage: {USAGE}")));
                }
            }
        }
    }
    Ok(put)
}

/// A `write` target.
pub(super) fn parse_target(spec: &str) -> Result<Target, UsageError> {
    let file_and_path = |rest: &str, what: &str| -> Result<(PathBuf, String), UsageError> {
        let (file, field) = rest
            .rsplit_once('#')
            .ok_or_else(|| UsageError::new(format!("--to {spec:?}: expected {what}:PATH#FIELD")))?;
        if file.is_empty() || field.is_empty() {
            return Err(UsageError::new(format!("--to {spec:?}: expected {what}:PATH#FIELD")));
        }
        Ok((absolute(file), field.to_owned()))
    };
    let dotted = |field: &str| -> Result<Vec<String>, UsageError> {
        let parts: Vec<String> = field.split('.').map(str::to_owned).collect();
        if parts.iter().any(String::is_empty) || parts.len() > 16 {
            return Err(UsageError::new(format!("--to {spec:?}: a field is a.b.c")));
        }
        Ok(parts)
    };
    if let Some(path) = spec.strip_prefix("file:") {
        if path.is_empty() {
            return Err(UsageError::new("--to file:PATH needs a path"));
        }
        return Ok(Target::File(absolute(path)));
    }
    if let Some(rest) = spec.strip_prefix("json:") {
        let (file, field) = file_and_path(rest, "json")?;
        return Ok(Target::Json(file, dotted(&field)?));
    }
    if let Some(rest) = spec.strip_prefix("toml:") {
        let (file, field) = file_and_path(rest, "toml")?;
        return Ok(Target::Toml(file, dotted(&field)?));
    }
    if let Some(rest) = spec.strip_prefix("env-file:") {
        let (file, var) = file_and_path(rest, "env-file")?;
        if !valid_var(&var) {
            return Err(UsageError::new(format!("--to {spec:?}: {var:?} is not an env name")));
        }
        return Ok(Target::EnvFile(file, var));
    }
    Store::parse(spec).map(Target::Store).map_err(|_| {
        UsageError::new(format!(
            "--to {spec:?}: expected gh-secret:OWNER/REPO[@ENV]:SECRET, keychain:[OWNER/REPO:]SECRET, vault:VAR, file:PATH, json:PATH#a.b, toml:PATH#a.b or env-file:PATH#VAR"
        ))
    })
}

pub(super) fn absolute(path: &str) -> PathBuf {
    let path = Path::new(path);
    if let Some(rest) = path.to_str().and_then(|p| p.strip_prefix("~/"))
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map(|dir| dir.join(path)).unwrap_or_else(|_| path.to_path_buf())
    }
}

/// `Some` when `verb` is one of this module's.
pub(in crate::cli) fn parse(verb: &str, rest: &[String]) -> Option<Result<Local, UsageError>> {
    let usage = || UsageError::new(format!("usage: {USAGE}"));
    Some(match (verb, rest) {
        ("put", [name, flags @ ..]) => parse_put(name, flags, |_, _| Ok(false)).map(Local::Put),
        ("generate", [name, flags @ ..]) => {
            let mut bytes = 32;
            let mut format = Format::Base64Url;
            parse_put(name, flags, |flag, value| {
                match flag {
                    "--bytes" => {
                        bytes = value()?
                            .parse()
                            .ok()
                            .filter(|n| (16..=256).contains(n))
                            .ok_or_else(|| UsageError::new("--bytes is 16 to 256"))?;
                    }
                    "--format" => {
                        format = match value()?.as_str() {
                            "base64url" => Format::Base64Url,
                            "hex" => Format::Hex,
                            "alnum" => Format::Alnum,
                            other => {
                                return Err(UsageError::new(format!(
                                    "--format {other:?}: base64url, hex or alnum"
                                )));
                            }
                        }
                    }
                    _ => return Ok(false),
                }
                Ok(true)
            })
            .and_then(|put| {
                if put.from_person {
                    return Err(UsageError::new("a generated key is not from a person"));
                }
                Ok(Local::Generate { put, bytes, format })
            })
        }
        ("request", [name, flags @ ..]) => {
            let mut timeout = DEFAULT_REQUEST_TIMEOUT;
            parse_put(name, flags, |flag, value| {
                if flag != "--timeout" {
                    return Ok(false);
                }
                timeout = parse_duration("--timeout", &value()?, MAX_REQUEST_TIMEOUT)?;
                Ok(true)
            })
            .and_then(|put| {
                if put.purpose.is_none() {
                    return Err(UsageError::new(
                        "request needs --purpose: the person sees it and decides by it",
                    ));
                }
                if put.from_person || put.asked_by.is_some() {
                    return Err(UsageError::new("--from-person and --asked-by are the app's own"));
                }
                Ok(Local::Request { put, timeout })
            })
        }
        ("use" | "run", args) => parse_use(args).map(Local::Use),
        ("write", [name, flags @ ..]) => (|| {
            let name = name_arg(name)?;
            let mut targets = Vec::new();
            let mut it = flags.iter();
            while let Some(flag) = it.next() {
                match flag.as_str() {
                    "--to" | "--store" => {
                        let spec = it
                            .next()
                            .ok_or_else(|| UsageError::new(format!("{flag} needs a target")))?;
                        targets.push(parse_target(spec)?);
                    }
                    other => {
                        return Err(UsageError::new(format!(
                            "unknown flag {other:?}\nusage: {USAGE}"
                        )));
                    }
                }
            }
            if targets.is_empty() {
                return Err(UsageError::new("write needs at least one --to TARGET"));
            }
            Ok(Local::Write { name, targets })
        })(),
        ("fill", [name, flags @ ..]) => (|| {
            let mut fill =
                Fill { name: name_arg(name)?, tab: None, selector: String::new(), typing: false };
            let mut it = flags.iter();
            while let Some(flag) = it.next() {
                let mut value = || {
                    it.next()
                        .cloned()
                        .ok_or_else(|| UsageError::new(format!("{flag} needs a value")))
                };
                match flag.as_str() {
                    "--tab" | "--browser" => fill.tab = Some(value()?),
                    "--selector" => fill.selector = value()?,
                    "--type" => fill.typing = true,
                    "--app" => {
                        return Err(UsageError::new(
                            "filling a desktop app goes through Computer Use: call the keys_fill tool of cmux's MCP server (in a cmux chat) with target app",
                        ));
                    }
                    other => {
                        return Err(UsageError::new(format!(
                            "unknown flag {other:?}\nusage: {USAGE}"
                        )));
                    }
                }
            }
            if fill.selector.is_empty() {
                return Err(UsageError::new(
                    "fill needs --selector CSS (or a snapshot ref like e3)",
                ));
            }
            Ok(Local::Fill(fill))
        })(),
        ("put" | "generate" | "request" | "write" | "fill", []) => Err(usage()),
        _ => return None,
    })
}

pub(super) fn parse_use(args: &[String]) -> Result<Use, UsageError> {
    let split = args.iter().position(|a| a == "--").ok_or_else(|| {
        UsageError::new("use needs -- before the command: cmux keys use NAME -- CMD")
    })?;
    let (spec, rest) = args.split_at(split);
    let argv = rest.get(1..).unwrap_or_default();
    if argv.is_empty() {
        return Err(UsageError::new("use needs a command after --"));
    }
    let mut keys: Vec<(String, String)> = Vec::new();
    let mut mask = true;
    let mut it = spec.iter();
    while let Some(word) = it.next() {
        match word.as_str() {
            "--no-mask" => mask = false,
            "--env" | "--as" => {
                let var = it.next().ok_or_else(|| UsageError::new("--env needs a VAR"))?;
                let last = keys
                    .last_mut()
                    .ok_or_else(|| UsageError::new("--env VAR follows the key it names"))?;
                if !valid_var(var) {
                    return Err(UsageError::new(format!("{var:?} is not an env name")));
                }
                last.1 = var.clone();
            }
            other if other.starts_with('-') => {
                return Err(UsageError::new(format!("unknown flag {other:?}\nusage: {USAGE}")));
            }
            other => {
                let (name, var) = other.split_once('=').unwrap_or((other, other));
                let name = name_arg(name)?;
                if !valid_var(var) {
                    return Err(UsageError::new(format!("{var:?} is not an env name")));
                }
                keys.push((name, var.to_owned()));
            }
        }
    }
    if keys.is_empty() {
        return Err(UsageError::new("use needs at least one key: cmux keys use NAME -- CMD"));
    }
    let mut vars: Vec<&str> = keys.iter().map(|(_, v)| v.as_str()).collect();
    vars.sort_unstable();
    if vars.windows(2).any(|w| matches!(w, [a, b] if a == b)) {
        return Err(UsageError::new("two keys go into one env var"));
    }
    Ok(Use { keys, mask, argv: argv.to_vec() })
}

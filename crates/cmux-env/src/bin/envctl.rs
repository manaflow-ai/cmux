use std::fs::{self, File};
use std::io::{self, Read};
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use cmux_env::{
    client_send, client_send_autostart, parse_dotenv, parse_dotenv_base64, Request, Response,
    Scope, ShellKind,
};

#[derive(Parser, Debug)]
#[command(name = "envctl", version, about = "Client for cmux-envd")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Set KEY=VAL. Optional --dir to scope to directory.
    Set {
        kv: String,
        #[arg(long)]
        dir: Option<PathBuf>,
    },
    /// Unset KEY. Optional --dir to scope to directory.
    Unset {
        key: String,
        #[arg(long)]
        dir: Option<PathBuf>,
    },
    /// Get effective value for KEY at PWD
    Get {
        key: String,
        #[arg(long)]
        pwd: Option<PathBuf>,
    },
    /// List effective variables at PWD
    List {
        #[arg(long)]
        pwd: Option<PathBuf>,
    },
    /// Load .env from file or stdin (-). Optional --dir to scope to directory.
    Load {
        #[arg(value_name = "INPUT")]
        input: String,
        #[arg(long)]
        dir: Option<PathBuf>,
        #[arg(long, help = "Treat INPUT (or stdin) as base64-encoded content")]
        base64: bool,
    },
    /// Print export/unset script diff since GEN and bump gen
    Export {
        shell: ShellType,
        #[arg(long, default_value_t = 0)]
        since: u64,
        #[arg(long)]
        pwd: Option<PathBuf>,
    },
    /// Print hook for bash/zsh/fish
    Hook { shell: ShellType },
    /// Install hook into the user's shell rc file
    InstallHook {
        shell: ShellType,
        #[arg(long, help = "Override rc file path")]
        rcfile: Option<PathBuf>,
    },
    /// Show daemon status
    Status,
    /// Ping daemon
    Ping,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum ShellType {
    Bash,
    Zsh,
    Fish,
}

impl From<ShellType> for ShellKind {
    fn from(s: ShellType) -> Self {
        match s {
            ShellType::Bash => ShellKind::Bash,
            ShellType::Zsh => ShellKind::Zsh,
            ShellType::Fish => ShellKind::Fish,
        }
    }
}

impl ShellType {
    fn as_str(&self) -> &'static str {
        match self {
            ShellType::Bash => "bash",
            ShellType::Zsh => "zsh",
            ShellType::Fish => "fish",
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Ping => {
            let resp = client_send(&Request::Ping)?;
            match resp {
                Response::Pong => {
                    println!("pong");
                    Ok(())
                }
                _ => Err(anyhow!("unexpected response")),
            }
        }
        Commands::Status => {
            let resp = client_send(&Request::Status)?;
            match resp {
                Response::Status {
                    generation,
                    globals,
                    scopes,
                } => {
                    println!("generation: {}", generation);
                    println!("globals: {}", globals);
                    println!("scopes: {}", scopes);
                    Ok(())
                }
                _ => Err(anyhow!("unexpected response")),
            }
        }
        Commands::Set { kv, dir } => {
            let (key, val) = parse_kv(&kv)?;
            let scope = dir.map(Scope::Dir).unwrap_or(Scope::Global);
            let _ = client_send_autostart(&Request::Set {
                key,
                value: val,
                scope,
            })?;
            Ok(())
        }
        Commands::Unset { key, dir } => {
            let scope = dir.map(Scope::Dir).unwrap_or(Scope::Global);
            let _ = client_send_autostart(&Request::Unset { key, scope })?;
            Ok(())
        }
        Commands::Get { key, pwd } => {
            let pwd = match pwd {
                Some(pwd) => pwd,
                None => std::env::current_dir()?,
            };
            let resp = client_send_autostart(&Request::Get {
                key,
                pwd: Some(pwd),
            })?;
            match resp {
                Response::Value { value } => {
                    if let Some(v) = value {
                        println!("{}", v);
                    }
                    Ok(())
                }
                _ => Err(anyhow!("unexpected response")),
            }
        }
        Commands::List { pwd } => {
            let pwd = match pwd {
                Some(pwd) => pwd,
                None => std::env::current_dir()?,
            };
            let resp = client_send_autostart(&Request::List { pwd: Some(pwd) })?;
            match resp {
                Response::Map { entries } => {
                    let mut pairs: Vec<_> = entries.into_iter().collect();
                    pairs.sort_by(|a, b| a.0.cmp(&b.0));

                    if pairs.is_empty() {
                        println!("No environment variables found.");
                    } else {
                        println!("Active environment variables ({}):", pairs.len());
                        for (key, value) in pairs {
                            println!("  - {}={}", key, value);
                        }
                    }
                    Ok(())
                }
                _ => Err(anyhow!("unexpected response")),
            }
        }
        Commands::Load { input, dir, base64 } => {
            let scope = dir.map(Scope::Dir).unwrap_or(Scope::Global);
            let entries = if base64 {
                let payload = if input == "-" {
                    let mut buf = String::new();
                    io::stdin().read_to_string(&mut buf)?;
                    buf
                } else {
                    input.clone()
                };
                parse_dotenv_base64(payload)?
            } else if input == "-" {
                let mut buf = String::new();
                io::stdin().read_to_string(&mut buf)?;
                parse_dotenv(buf.as_bytes())?
            } else {
                let f = File::open(&input).with_context(|| format!("open {}", input))?;
                parse_dotenv(f)?
            };
            let _ = client_send_autostart(&Request::Load { entries, scope })?;
            Ok(())
        }
        Commands::Export { shell, since, pwd } => {
            let shell: ShellKind = shell.into();
            let pwd = pwd.unwrap_or(std::env::current_dir()?);
            // If --since not specified (0), try ENVCTL_GEN to provide a smoother UX
            let since = if since == 0 {
                std::env::var("ENVCTL_GEN")
                    .ok()
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0)
            } else {
                since
            };
            let resp = client_send_autostart(&Request::Export { shell, since, pwd })?;
            match resp {
                Response::Export {
                    script,
                    new_generation: _,
                } => {
                    print!("{}", script);
                    Ok(())
                }
                _ => Err(anyhow!("unexpected response")),
            }
        }
        Commands::Hook { shell } => {
            match shell {
                ShellType::Bash => print!("{}", hook_bash()),
                ShellType::Zsh => print!("{}", hook_zsh()),
                ShellType::Fish => print!("{}", hook_fish()),
            }
            Ok(())
        }
        Commands::InstallHook { shell, rcfile } => {
            install_hook(shell, rcfile)?;
            Ok(())
        }
    }
}

fn install_hook(shell: ShellType, rcfile: Option<PathBuf>) -> Result<()> {
    const START_MARKER: &str = "# >>> envctl hook >>>";
    const END_MARKER: &str = "# <<< envctl hook <<<";

    let rc_path = rcfile.unwrap_or(default_rc_path(shell)?);
    if let Some(parent) = rc_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating rcfile directory {}", parent.display()))?;
    }

    let mut contents = if rc_path.exists() {
        fs::read_to_string(&rc_path)
            .with_context(|| format!("reading rcfile {}", rc_path.display()))?
    } else {
        String::new()
    };

    if let Some(start_idx) = contents.find(START_MARKER) {
        let end_search = &contents[start_idx..];
        if let Some(end_rel) = end_search.find(END_MARKER) {
            let mut end_idx = start_idx + end_rel + END_MARKER.len();
            while let Some(&byte) = contents.as_bytes().get(end_idx) {
                if byte == b'\n' || byte == b'\r' {
                    end_idx += 1;
                } else {
                    break;
                }
            }
            contents.replace_range(start_idx..end_idx, "");
        } else {
            contents.truncate(start_idx);
        }
        contents = contents.trim_end_matches('\n').to_string();
    }

    if !contents.is_empty() && !contents.ends_with('\n') {
        contents.push('\n');
    }

    let hook_body = match shell {
        ShellType::Bash => hook_bash(),
        ShellType::Zsh => hook_zsh(),
        ShellType::Fish => hook_fish(),
    };

    let mut block = String::new();
    block.push_str(START_MARKER);
    block.push('\n');
    block.push_str(&hook_body);
    if !hook_body.ends_with('\n') {
        block.push('\n');
    }
    block.push_str(END_MARKER);
    block.push('\n');

    contents.push_str(&block);

    fs::write(&rc_path, contents)
        .with_context(|| format!("writing rcfile {}", rc_path.display()))?;

    println!(
        "Installed envctl hook for {} at {}",
        shell.as_str(),
        rc_path.display()
    );

    Ok(())
}

fn default_rc_path(shell: ShellType) -> Result<PathBuf> {
    let home = std::env::var("HOME").context("HOME not set")?;
    let base = PathBuf::from(home);
    let path = match shell {
        ShellType::Bash => base.join(".bashrc"),
        ShellType::Zsh => base.join(".zshrc"),
        ShellType::Fish => base.join(".config").join("fish").join("config.fish"),
    };
    Ok(path)
}

fn parse_kv(s: &str) -> Result<(String, String)> {
    if let Some(eq) = s.find('=') {
        let (k, v) = s.split_at(eq);
        if k.is_empty() {
            return Err(anyhow!("empty key"));
        }
        Ok((k.to_string(), v[1..].to_string()))
    } else {
        Err(anyhow!("expected KEY=VAL"))
    }
}

fn hook_bash() -> String {
    r#"# envctl bash hook
# Apply env diffs safely (idempotent, uses ENVCTL_GEN)
__envctl_apply() {
  local out
  out="$(envctl export bash --since "${ENVCTL_GEN:-0}" --pwd "$PWD")" || return
  eval "$out"
}

# Capture existing DEBUG trap handler (if any) so we can chain it later
__envctl_capture_debug_trap() {
  builtin local -a __envctl_terms
  builtin eval "__envctl_terms=( $(trap -p DEBUG) )" 2>/dev/null || return
  if (( ${#__envctl_terms[@]} >= 3 )); then
    builtin printf '%s' "${__envctl_terms[2]}"
  fi
}

# DEBUG trap runs before each command; apply updates and chain previous trap safely
__envctl_debug_trap() {
  local __envctl_status=$?
  local __envctl_trap_arg="$1"
  if (( ${__envctl_in_debug_trap:-0} )); then
    return $__envctl_status
  fi
  __envctl_in_debug_trap=1

  local __envctl_saved_bash_command=$BASH_COMMAND
  local __envctl_saved_arg="$__envctl_trap_arg"

  __envctl_apply

  if [[ -n "${__envctl_prev_debug_trap:-}" ]]; then
    BASH_COMMAND=$__envctl_saved_bash_command
    : "$__envctl_saved_arg"
    builtin eval "${__envctl_prev_debug_trap}"
  fi

  __envctl_in_debug_trap=0
  return $__envctl_status
}

if [[ -z "${__envctl_debug_trap_installed:-}" ]]; then
  __envctl_prev_debug_trap="$(__envctl_capture_debug_trap)"
  if [[ "${__envctl_prev_debug_trap}" == '__envctl_debug_trap'* ]]; then
    __envctl_prev_debug_trap=''
  fi
  __envctl_debug_trap_installed=1
fi

trap '__envctl_debug_trap "$_"' DEBUG

# Apply once at shell start
__envctl_apply
"#
    .to_string()
}

fn hook_zsh() -> String {
    r#"# envctl zsh hook
autoload -U add-zsh-hook
envctl_preexec() {
  local out
  out="$(envctl export zsh --since "${ENVCTL_GEN:-0}" --pwd "$PWD")" || return
  eval "$out"
}
add-zsh-hook preexec envctl_preexec
# Apply once at shell start
envctl_preexec
"#
    .to_string()
}

fn hook_fish() -> String {
    r#"# envctl fish hook
function __envctl_preexec --on-event fish_preexec
  envctl export fish --since "$ENVCTL_GEN" --pwd "$PWD" | source
end
function __envctl_prompt --on-event fish_prompt
  envctl export fish --since "$ENVCTL_GEN" --pwd "$PWD" | source
end
# Apply once at shell start
envctl export fish --since "$ENVCTL_GEN" --pwd "$PWD" | source
"#
    .to_string()
}

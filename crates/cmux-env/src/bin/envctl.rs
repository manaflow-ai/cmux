use std::fs::File;
use std::io::{self, Read};
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use cmux_env::{client_send, parse_dotenv, Request, Response, Scope, ShellKind};

#[derive(Parser, Debug)]
#[command(name = "envctl", version, about = "Client for cmux-envd")] 
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Set KEY=VAL. Optional --dir to scope to directory.
    Set { kv: String, #[arg(long)] dir: Option<PathBuf> },
    /// Unset KEY. Optional --dir to scope to directory.
    Unset { key: String, #[arg(long)] dir: Option<PathBuf> },
    /// Get effective value for KEY at PWD
    Get { key: String, #[arg(long)] pwd: Option<PathBuf> },
    /// List effective variables at PWD
    List { #[arg(long)] pwd: Option<PathBuf> },
    /// Load .env from file or stdin (-). Optional --dir to scope to directory.
    Load { file: String, #[arg(long)] dir: Option<PathBuf> },
    /// Print export/unset script diff since GEN and bump gen
    Export { shell: ShellType, #[arg(long, default_value_t = 0)] since: u64, #[arg(long)] pwd: Option<PathBuf> },
    /// Print hook for bash/zsh/fish
    Hook { shell: ShellType },
    /// Show daemon status
    Status,
    /// Ping daemon
    Ping,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum ShellType { Bash, Zsh, Fish }

impl From<ShellType> for ShellKind {
    fn from(s: ShellType) -> Self {
        match s { ShellType::Bash => ShellKind::Bash, ShellType::Zsh => ShellKind::Zsh, ShellType::Fish => ShellKind::Fish }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Ping => {
            let resp = client_send(&Request::Ping)?;
            match resp { Response::Pong => { println!("pong"); Ok(()) }, _ => Err(anyhow!("unexpected response")) }
        }
        Commands::Status => {
            let resp = client_send(&Request::Status)?;
            match resp { Response::Status { generation, globals, scopes } => {
                println!("generation: {}", generation);
                println!("globals: {}", globals);
                println!("scopes: {}", scopes);
                Ok(())
            }, _ => Err(anyhow!("unexpected response")) }
        }
        Commands::Set { kv, dir } => {
            let (key, val) = parse_kv(&kv)?;
            let scope = dir.map(Scope::Dir).unwrap_or(Scope::Global);
            let _ = client_send(&Request::Set { key, value: val, scope })?;
            Ok(())
        }
        Commands::Unset { key, dir } => {
            let scope = dir.map(Scope::Dir).unwrap_or(Scope::Global);
            let _ = client_send(&Request::Unset { key, scope })?; Ok(())
        }
        Commands::Get { key, pwd } => {
            let resp = client_send(&Request::Get { key, pwd })?;
            match resp { Response::Value { value } => {
                if let Some(v) = value { println!("{}", v); }
                Ok(())
            }, _ => Err(anyhow!("unexpected response")) }
        }
        Commands::List { pwd } => {
            let resp = client_send(&Request::List { pwd })?;
            match resp { Response::Map { entries } => {
                for (k, v) in entries { println!("{}={}", k, v); }
                Ok(())
            }, _ => Err(anyhow!("unexpected response")) }
        }
        Commands::Load { file, dir } => {
            let scope = dir.map(Scope::Dir).unwrap_or(Scope::Global);
            let entries = if file == "-" {
                let mut buf = String::new();
                io::stdin().read_to_string(&mut buf)?;
                parse_dotenv(buf.as_bytes())?
            } else {
                let f = File::open(&file).with_context(|| format!("open {}", file))?;
                parse_dotenv(f)?
            };
            let _ = client_send(&Request::Load { entries, scope })?;
            Ok(())
        }
        Commands::Export { shell, since, pwd } => {
            let shell: ShellKind = shell.into();
            let pwd = pwd.unwrap_or(std::env::current_dir()?);
            // If --since not specified (0), try ENVCTL_GEN to provide a smoother UX
            let since = if since == 0 {
                std::env::var("ENVCTL_GEN").ok().and_then(|s| s.parse::<u64>().ok()).unwrap_or(0)
            } else { since };
            let resp = client_send(&Request::Export { shell, since, pwd })?;
            match resp { Response::Export { script, new_generation: _ } => { print!("{}", script); Ok(()) }, _ => Err(anyhow!("unexpected response")) }
        }
        Commands::Hook { shell } => {
            match shell {
                ShellType::Bash => print!("{}", hook_bash()),
                ShellType::Zsh => print!("{}", hook_zsh()),
                ShellType::Fish => print!("{}", hook_fish()),
            }
            Ok(())
        }
    }
}

fn parse_kv(s: &str) -> Result<(String, String)> {
    if let Some(eq) = s.find('=') {
        let (k, v) = s.split_at(eq);
        if k.is_empty() { return Err(anyhow!("empty key")); }
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

# DEBUG trap runs before each command; disable trap during apply to avoid recursion
__envctl_debug_trap() {
  trap - DEBUG
  __envctl_apply
  trap '__envctl_debug_trap' DEBUG
}

trap '__envctl_debug_trap' DEBUG

# Apply once at shell start
__envctl_apply
"#.to_string()
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
"#.to_string()
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
"#.to_string()
}


//! Which packages a shell command installs, by package manager.
//!
//! A Cloud machine's image is baked with the packages a first session would
//! otherwise download (`web/scripts/cmux-vm-image/dep-cache.ts`). Which ones
//! is measured, not guessed: acpmux counts each install an agent's shell call
//! ran (`hub/tool_shell.rs`), and those counts choose the next bake's list.
//!
//! [`package_installs`] reads one command the way [`crate::classify`] does
//! (the same lexer: quoting, `&&`, pipelines, `$(...)`, `VAR=val`, `sudo`,
//! `env`, `timeout`, `bash -c`) and names each install in it. It names only
//! a registry package by its registry name: a path, URL, git source, tarball,
//! a requirements file or a name with characters a registry would refuse is
//! skipped, so a private file or address never becomes a name. A version
//! (`react@18`, `numpy==2.1`, `serde@1`) is dropped; the name stays.

use crate::lex::{self, Token};
use crate::rules::{is_assignment, is_flag};

/// Nesting deepest followed (`bash -c "sudo bash -c '...'"`).
const MAX_DEPTH: usize = 8;

/// One install a command runs: the package manager and the registry names it
/// installs. `packages` is empty for an install of the project's own
/// manifest (`npm install`, `uv sync`, `cargo build` is not one).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageInstall {
    /// `npm`, `pnpm`, `yarn`, `bun`, `pip`, `uv`, `cargo`, `go`, `apt`,
    /// `brew` or `gem`.
    pub manager: &'static str,
    pub packages: Vec<String>,
}

/// Every install `command` runs, in order. A command the lexer can't read
/// installs nothing as far as this says.
pub fn package_installs(command: &str) -> Vec<PackageInstall> {
    let mut out = Vec::new();
    script(command, 0, &mut out);
    out
}

fn script(src: &str, depth: usize, out: &mut Vec<PackageInstall>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(tokens) = lex::lex(src) else { return };
    let mut words: Vec<String> = Vec::new();
    for token in tokens {
        match token {
            Token::Word(word) => {
                for sub in &word.subs {
                    script(sub, depth.saturating_add(1), out);
                }
                words.push(word.text);
            }
            Token::Redirect { .. } => {}
            Token::Separator | Token::Background => {
                simple(&words, depth, out);
                words.clear();
            }
        }
    }
    simple(&words, depth, out);
}

/// One simple command: assignments and wrappers first, then the command.
fn simple(words: &[String], depth: usize, out: &mut Vec<PackageInstall>) {
    let argv: Vec<&str> = words.iter().map(String::as_str).collect();
    command(&argv, depth, out);
}

fn command(argv: &[&str], depth: usize, out: &mut Vec<PackageInstall>) {
    if depth > MAX_DEPTH {
        return;
    }
    let mut i = 0;
    while argv
        .get(i)
        .is_some_and(|w| is_assignment(w) || matches!(*w, "!" | "{" | "then" | "do" | "else"))
    {
        i = i.saturating_add(1);
    }
    let Some((&first, tail)) = argv.get(i..).and_then(<[&str]>::split_first) else { return };
    let name = first.rsplit('/').next().unwrap_or(first);
    let next = depth.saturating_add(1);
    match name {
        "sudo" | "doas" => {
            command(skip_flags(tail, &["-u", "-g", "-C", "-D", "-h", "-p", "-U"]), next, out)
        }
        "env" => command(skip_env(tail), next, out),
        "timeout" => command(
            skip_flags(tail, &["-s", "-k", "--signal", "--kill-after"])
                .get(1..)
                .unwrap_or_default(),
            next,
            out,
        ),
        "nice" | "nohup" | "time" | "command" | "exec" | "stdbuf" | "runuser" => {
            command(skip_flags(tail, &["-n", "-u", "-i", "-o", "-e", "-a", "--user"]), next, out);
        }
        "bash" | "sh" | "zsh" | "dash" => {
            if let Some(src) = shell_script(tail) {
                script(src, next, out);
            }
        }
        "python" | "python3" if tail.first() == Some(&"-m") && tail.get(1) == Some(&"pip") => {
            pip("pip", tail.get(2..).unwrap_or_default(), out);
        }
        "pip" | "pip3" => pip("pip", tail, out),
        "uv" => uv(tail, out),
        "npm" | "pnpm" | "yarn" | "bun" => node(node_manager(name), tail, out),
        "cargo" => cargo(tail, out),
        "go" => go(tail, out),
        "apt" | "apt-get" => system("apt", tail, &["install"], out),
        "brew" => system("brew", tail, &["install"], out),
        "gem" => system("gem", tail, &["install"], out),
        _ => {}
    }
}

fn node_manager(name: &str) -> &'static str {
    match name {
        "pnpm" => "pnpm",
        "yarn" => "yarn",
        "bun" => "bun",
        _ => "npm",
    }
}

/// The words after a wrapper's flags (and the values of `valued` ones).
fn skip_flags<'a>(tail: &'a [&'a str], valued: &[&str]) -> &'a [&'a str] {
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        if word == "--" {
            j = j.saturating_add(1);
            break;
        }
        if !is_flag(word) {
            break;
        }
        j = j.saturating_add(if valued.contains(&word) { 2 } else { 1 });
    }
    tail.get(j..).unwrap_or_default()
}

fn skip_env<'a>(tail: &'a [&'a str]) -> &'a [&'a str] {
    let mut j = 0;
    while let Some(&word) = tail.get(j) {
        match word {
            "-u" | "-C" | "--unset" | "--chdir" => j = j.saturating_add(2),
            _ if is_flag(word) || is_assignment(word) || word == "-" => j = j.saturating_add(1),
            _ => break,
        }
    }
    tail.get(j..).unwrap_or_default()
}

/// `bash -c 'script'`'s script (also `-lc`, `-ec`, `-euo pipefail -c`).
fn shell_script<'a>(tail: &[&'a str]) -> Option<&'a str> {
    let mut j = 0;
    let mut has_c = false;
    while let Some(&word) = tail.get(j) {
        match word {
            "-o" | "+o" | "-O" | "+O" => j = j.saturating_add(2),
            _ if word.starts_with("--") => j = j.saturating_add(1),
            _ if word.len() > 1 && (word.starts_with('-') || word.starts_with('+')) => {
                let flags = word.get(1..).unwrap_or_default();
                has_c |= word.starts_with('-') && flags.contains('c');
                j = j.saturating_add(if flags.contains(['o', 'O']) { 2 } else { 1 });
            }
            _ => break,
        }
    }
    has_c.then(|| tail.get(j).copied()).flatten()
}

/// The non-flag words of `args`, skipping the values of `valued` flags. A
/// flag written `--flag=value` carries its own value.
fn operands<'a>(args: &[&'a str], valued: &[&str]) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut j = 0;
    while let Some(&word) = args.get(j) {
        j = j.saturating_add(1);
        if word == "--" {
            out.extend(args.get(j..).unwrap_or_default());
            break;
        }
        if is_flag(word) {
            if valued.contains(&word) {
                j = j.saturating_add(1);
            }
            continue;
        }
        out.push(word);
    }
    out
}

fn push(out: &mut Vec<PackageInstall>, manager: &'static str, packages: Vec<String>) {
    out.push(PackageInstall { manager, packages });
}

/// `npm install|i|add X`, `pnpm add X`, `yarn add X`, `bun add X`; a bare
/// `npm install`/`pnpm install`/`yarn`/`bun install` installs the manifest.
fn node(manager: &'static str, tail: &[&str], out: &mut Vec<PackageInstall>) {
    const VALUED: &[&str] = &[
        "--prefix",
        "-C",
        "--dir",
        "--cwd",
        "--filter",
        "-F",
        "--workspace",
        "-w",
        "--registry",
        "--tag",
    ];
    let args = operands(tail, VALUED);
    let global = tail.iter().any(|w| matches!(*w, "-g" | "--global"));
    let (verb, rest) = match args.split_first() {
        Some((verb, rest)) => (*verb, rest),
        // `yarn` alone installs the manifest.
        None if manager == "yarn" => ("install", &[][..]),
        None => return,
    };
    if !matches!(verb, "install" | "i" | "add" | "ci") {
        return;
    }
    let packages: Vec<String> = rest.iter().filter_map(|w| npm_name(w)).collect();
    // `npm install ./lib` names only things this skips: not a manifest install either.
    if !rest.is_empty() && packages.is_empty() {
        return;
    }
    if global && packages.is_empty() {
        return;
    }
    push(out, manager, packages);
}

/// A registry name from an npm package spec, without its version or tag.
fn npm_name(spec: &str) -> Option<String> {
    let (scope, rest) = match spec.strip_prefix('@') {
        Some(rest) => {
            let (scope, name) = rest.split_once('/')?;
            (Some(scope), name)
        }
        None => (None, spec),
    };
    let name = rest.split_once('@').map_or(rest, |(name, _)| name);
    let valid = |part: &str| {
        !part.is_empty()
            && part.len() <= 214
            && !part.starts_with('.')
            && part.bytes().all(|b| {
                b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'.' | b'_')
            })
    };
    if !valid(name) || scope.is_some_and(|scope| !valid(scope)) {
        return None;
    }
    Some(match scope {
        Some(scope) => format!("@{scope}/{name}"),
        None => name.to_owned(),
    })
}

/// `pip install X` (not `-r file`, `-e path`, a URL or a wheel).
fn pip(manager: &'static str, tail: &[&str], out: &mut Vec<PackageInstall>) {
    const VALUED: &[&str] = &[
        "-r",
        "--requirement",
        "-c",
        "--constraint",
        "-e",
        "--editable",
        "-i",
        "--index-url",
        "--extra-index-url",
        "-t",
        "--target",
        "--python",
        "-p",
    ];
    let args = operands(tail, VALUED);
    let Some((&"install", rest)) = args.split_first() else { return };
    let packages: Vec<String> = rest.iter().filter_map(|w| python_name(w)).collect();
    if packages.is_empty() {
        return;
    }
    push(out, manager, packages);
}

/// `uv pip install X`, `uv add X`, `uv tool install X`; `uv sync` installs the manifest.
fn uv(tail: &[&str], out: &mut Vec<PackageInstall>) {
    const VALUED: &[&str] = &[
        "--python",
        "-p",
        "--directory",
        "--project",
        "--index",
        "--extra-index-url",
        "-r",
        "--requirements",
        "--group",
        "--extra",
        "--with",
        "-c",
        "--constraint",
    ];
    let args = operands(tail, VALUED);
    let (packages, manifest) = match args.as_slice() {
        ["pip", "install", rest @ ..] | ["add", rest @ ..] | ["tool", "install", rest @ ..] => {
            (rest.iter().filter_map(|w| python_name(w)).collect::<Vec<_>>(), false)
        }
        ["sync", ..] => (Vec::new(), true),
        _ => return,
    };
    if packages.is_empty() && !manifest {
        return;
    }
    push(out, "uv", packages);
}

/// A PyPI name from a requirement (`numpy==2.1`, `fastapi[all]>=0.1`),
/// normalized as PyPI does (lowercase, `_` and `.` as `-`).
fn python_name(spec: &str) -> Option<String> {
    let end = spec
        .find(|c: char| matches!(c, '[' | '=' | '<' | '>' | '!' | '~' | ';' | ' '))
        .unwrap_or(spec.len());
    let name = spec.get(..end)?;
    let valid = !name.is_empty()
        && name.len() <= 100
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        && name.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
        && name.bytes().last().is_some_and(|b| b.is_ascii_alphanumeric());
    valid.then(|| name.to_ascii_lowercase().replace(['_', '.'], "-"))
}

/// `cargo add X`, `cargo install X` (not `--path`, `--git`).
fn cargo(tail: &[&str], out: &mut Vec<PackageInstall>) {
    const VALUED: &[&str] = &[
        "--features",
        "-F",
        "--version",
        "--vers",
        "--rename",
        "--package",
        "-p",
        "--manifest-path",
        "--target",
        "--registry",
        "--branch",
        "--tag",
        "--rev",
        "--root",
        "--bin",
        "--example",
    ];
    if tail.iter().any(|w| {
        matches!(*w, "--path" | "--git") || w.starts_with("--path=") || w.starts_with("--git=")
    }) {
        return;
    }
    let args = operands(tail, VALUED);
    let Some((&verb, rest)) = args.split_first() else { return };
    if !matches!(verb, "add" | "install") {
        return;
    }
    let packages: Vec<String> = rest
        .iter()
        .filter_map(|w| {
            let name = w.split_once('@').map_or(*w, |(name, _)| name);
            let valid = !name.is_empty()
                && name.len() <= 64
                && name.bytes().next().is_some_and(|b| b.is_ascii_alphabetic())
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'));
            valid.then(|| name.to_ascii_lowercase())
        })
        .collect();
    if packages.is_empty() {
        return;
    }
    push(out, "cargo", packages);
}

/// `go get M`, `go install M@v`: a module path on a public host (`github.com/x/y`).
fn go(tail: &[&str], out: &mut Vec<PackageInstall>) {
    let args = operands(tail, &["-C", "-modfile", "-tags"]);
    let Some((&verb, rest)) = args.split_first() else { return };
    if !matches!(verb, "get" | "install") {
        return;
    }
    let packages: Vec<String> = rest
        .iter()
        .filter_map(|w| {
            let module = w.split_once('@').map_or(*w, |(module, _)| module);
            let host = module.split('/').next()?;
            let valid = module.len() <= 128
                && host.contains('.')
                && host.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
                && !module.contains("..")
                && module.bytes().all(|b| {
                    b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'/' | b'~')
                })
                && module.matches('/').count() >= 1;
            valid.then(|| module.to_owned())
        })
        .collect();
    if packages.is_empty() {
        return;
    }
    push(out, "go", packages);
}

/// `apt install X`, `brew install X`, `gem install X`.
fn system(manager: &'static str, tail: &[&str], verbs: &[&str], out: &mut Vec<PackageInstall>) {
    let args =
        operands(tail, &["-o", "-t", "--target-release", "-v", "--version", "-i", "--install-dir"]);
    let Some((verb, rest)) = args.split_first() else { return };
    if !verbs.contains(verb) {
        return;
    }
    let packages: Vec<String> = rest
        .iter()
        .filter_map(|w| {
            let name = w.split_once(['=', ':']).map_or(*w, |(name, _)| name);
            let valid = !name.is_empty()
                && name.len() <= 64
                && name.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
                && name.bytes().all(|b| {
                    b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'+' | b'@')
                })
                && !name.ends_with(".deb");
            valid.then(|| name.to_ascii_lowercase())
        })
        .collect();
    if packages.is_empty() {
        return;
    }
    push(out, manager, packages);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installs(command: &str) -> Vec<(&'static str, Vec<String>)> {
        package_installs(command).into_iter().map(|i| (i.manager, i.packages)).collect()
    }

    fn one(manager: &'static str, packages: &[&str]) -> Vec<(&'static str, Vec<String>)> {
        vec![(manager, packages.iter().map(|p| (*p).to_owned()).collect())]
    }

    #[test]
    fn node_managers_name_registry_packages_without_versions() {
        assert_eq!(
            installs("npm install react@18 @types/node -D"),
            one("npm", &["react", "@types/node"])
        );
        assert_eq!(installs("npm i -g typescript"), one("npm", &["typescript"]));
        assert_eq!(installs("pnpm add zod --filter web"), one("pnpm", &["zod"]));
        assert_eq!(installs("yarn add vite@latest"), one("yarn", &["vite"]));
        assert_eq!(installs("bun add hono"), one("bun", &["hono"]));
    }

    #[test]
    fn a_bare_install_is_the_manifest() {
        assert_eq!(installs("npm install"), one("npm", &[]));
        assert_eq!(installs("npm ci"), one("npm", &[]));
        assert_eq!(installs("yarn"), one("yarn", &[]));
        assert_eq!(installs("uv sync"), one("uv", &[]));
    }

    #[test]
    fn paths_urls_and_git_sources_are_never_names() {
        assert!(installs("npm install ./packages/lib").is_empty());
        assert!(installs("npm install git+ssh://git@example.com/secret.git").is_empty());
        assert!(installs("npm install https://example.com/x.tgz").is_empty());
        assert!(installs("pip install -r requirements.txt").is_empty());
        assert!(installs("pip install -e .").is_empty());
        assert!(installs("pip install https://example.com/a.whl").is_empty());
        assert!(installs("cargo install --path .").is_empty());
        assert!(installs("cargo install --git https://example.com/x").is_empty());
        assert!(installs("go install ./cmd/tool").is_empty());
        assert!(installs("sudo apt install ./local.deb").is_empty());
        assert!(installs("npm install Secret_Thing").is_empty());
    }

    #[test]
    fn python_names_are_normalized() {
        assert_eq!(
            installs("pip install Flask==3.0 'fastapi[all]>=0.1'"),
            one("pip", &["flask", "fastapi"])
        );
        assert_eq!(
            installs("python3 -m pip install --user ruamel.yaml"),
            one("pip", &["ruamel-yaml"])
        );
        assert_eq!(
            installs("uv pip install numpy pydantic_core"),
            one("uv", &["numpy", "pydantic-core"])
        );
        assert_eq!(installs("uv add httpx --dev"), one("uv", &["httpx"]));
    }

    #[test]
    fn other_managers() {
        assert_eq!(installs("cargo add serde@1 --features derive"), one("cargo", &["serde"]));
        assert_eq!(
            installs("go install golang.org/x/tools/gopls@latest"),
            one("go", &["golang.org/x/tools/gopls"])
        );
        assert_eq!(
            installs("sudo apt-get install -y ripgrep jq=1.6-2"),
            one("apt", &["ripgrep", "jq"])
        );
        assert_eq!(installs("brew install gh"), one("brew", &["gh"]));
        assert_eq!(installs("gem install bundler -v 2.5"), one("gem", &["bundler"]));
    }

    #[test]
    fn wrappers_chains_and_shells_are_followed() {
        assert_eq!(
            installs("cd web && CI=1 npm install vite && bash -lc 'pip install requests'"),
            vec![("npm", vec!["vite".to_owned()]), ("pip", vec!["requests".to_owned()])]
        );
        assert_eq!(
            installs("timeout 300 env FOO=1 sudo -u cmux pnpm add zod"),
            one("pnpm", &["zod"])
        );
        assert_eq!(installs("echo $(npm i left-pad)"), one("npm", &["left-pad"]));
    }

    #[test]
    fn non_installs_are_nothing() {
        for command in [
            "npm run build",
            "npm test",
            "cargo build",
            "go build ./...",
            "pip list",
            "uv run pytest",
            "apt list",
            "ls",
            "echo 'npm install x'",
            "git commit -m 'npm i x'",
        ] {
            assert!(installs(command).is_empty(), "{command}");
        }
        assert!(installs("unclosed 'quote npm i x").is_empty());
    }
}

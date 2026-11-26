//! Whether an MCP server entry in a person's own agent config runs cmux's
//! server (`cmux mcp serve`), from any build or install: how `cmux setup
//! mcp` finds a `cmux` entry that runs it (an older cmux's, or one the
//! person added), which Settings offers to remove on the person's click
//! (`mcp.rs`).

use std::path::Path;

/// What an MCP server entry runs when it runs cmux's server (`cmux mcp
/// serve`): which entries count as cmux's own, from any build or install.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum CmuxServe<'a> {
    /// A cmux CLI (`…/cmux mcp serve`, a bare `cmux` on PATH, an npm or PyPI
    /// console script named `cmux`), or the launcher script a JavaScript
    /// runtime runs (`node …/cmux.js mcp serve`): this path.
    Path(&'a str),
    /// A package runner that fetches a published cmux each time (`npx [-y]
    /// cmux mcp serve`, `bunx`, `pnpm dlx`, `uvx`, `pipx run`).
    Published,
}

/// The names cmux's CLI is installed under (the app's `cmux`, the
/// side-by-side `cmux-next`, the binary `cmux-tui`).
const CLI_NAMES: [&str; 3] = ["cmux", "cmux-next", "cmux-tui"];
/// cmux's npm launcher script.
const LAUNCHER_SCRIPT: &str = "cmux.js";
/// The package name cmux is published under, on npm and PyPI.
const PACKAGE: &str = "cmux";

/// Whether a package runner's package argument names cmux: `cmux`, with a
/// version (`cmux@1.2`, `cmux==1.2`, `cmux>=1`) or not; never `cmux-sdk`.
fn names_cmux_package(spec: &str) -> bool {
    let name = spec.split(['@', '=', '<', '>', '~', '!', '[']).next().unwrap_or_default();
    name == PACKAGE
}

/// The arguments after a runner's own options: `takes_value` options use the
/// next argument unless written `--flag=value`; `None` when an option in
/// `refuses` turns the launch into something else (`node -e`, `npx -c`).
fn after_options<'a>(
    args: &'a [String],
    takes_value: &[&str],
    refuses: &[&str],
) -> Option<&'a [String]> {
    after_options_with(args, takes_value, refuses, &[]).map(|(rest, _)| rest)
}

/// [`after_options`], also answering the values of the options in `package`
/// (`npx -p PKG`, `uvx --from PKG`, `pipx run --spec PKG`): the package the
/// runner installs, whose command the next argument names.
fn after_options_with<'a>(
    args: &'a [String],
    takes_value: &[&str],
    refuses: &[&str],
    package: &[&str],
) -> Option<(&'a [String], Vec<&'a str>)> {
    let mut rest = args;
    let mut packages = Vec::new();
    while let Some((first, tail)) = rest.split_first() {
        if first == "--" {
            return Some((tail, packages));
        }
        if !first.starts_with('-') || first == "-" {
            return Some((rest, packages));
        }
        let (flag, attached) = match first.split_once('=') {
            Some((flag, value)) => (flag, Some(value)),
            None => (first.as_str(), None),
        };
        if refuses.contains(&flag) {
            return None;
        }
        let value = if takes_value.contains(&flag) && attached.is_none() {
            let value = tail.first().map(String::as_str);
            rest = tail.get(1..).unwrap_or_default();
            value
        } else {
            rest = tail;
            attached
        };
        if package.contains(&flag) {
            packages.push(value.unwrap_or_default());
        }
    }
    Some((rest, packages))
}

/// [`CmuxServe`] of an entry that runs `command args`, or `None` when it runs
/// no cmux server. Names match exactly: the CLI's ([`CLI_NAMES`]), the
/// launcher script's and the package's.
pub(super) fn cmux_serve<'a>(command: &'a str, args: &'a [String]) -> Option<CmuxServe<'a>> {
    let base = |path: &str| Path::new(path).file_name().and_then(|n| n.to_str()).map(str::to_owned);
    let serves = |rest: &[String]| rest.iter().map(String::as_str).take(2).eq(["mcp", "serve"]);
    let program = base(command)?;
    if CLI_NAMES.contains(&program.as_str()) {
        return serves(args).then_some(CmuxServe::Path(command));
    }
    // `bun x PKG` is bunx, `bun run SCRIPT` runs a script like `bun SCRIPT`.
    let (program, args) = match (program.as_str(), args.first().map(String::as_str)) {
        ("bun", Some("x")) => ("bunx".to_owned(), args.get(1..).unwrap_or_default()),
        ("bun", Some("run")) => ("bun".to_owned(), args.get(1..).unwrap_or_default()),
        ("uv", Some("tool")) if args.get(1).is_some_and(|a| a == "run") => {
            ("uvx".to_owned(), args.get(2..).unwrap_or_default())
        }
        ("npm", Some("exec" | "x")) => ("npx".to_owned(), args.get(1..).unwrap_or_default()),
        _ => (program, args),
    };
    // A JavaScript runtime and its script, after the runtime's own options.
    if matches!(program.as_str(), "node" | "nodejs" | "bun") {
        let rest = after_options(
            args,
            &[
                "-r",
                "--require",
                "--import",
                "--loader",
                "--experimental-loader",
                "-C",
                "--conditions",
                "--inspect-port",
                "--env-file",
                "--title",
                "--preserve-symlinks-main",
            ],
            &["-e", "--eval", "-p", "--print", "-c", "--check", "-i", "--interactive"],
        )?;
        let (script, rest) = rest.split_first()?;
        return (base(script).as_deref() == Some(LAUNCHER_SCRIPT) && serves(rest))
            .then_some(CmuxServe::Path(script.as_str()));
    }
    // A package runner: its own options, then the package (or the command of
    // a package an option names), then its args.
    let (args, takes_value, refuses): (&[String], &[&str], &[&str]) = match program.as_str() {
        "npx" | "pnpx" => {
            (args, &["-p", "--package", "--registry", "--cache", "--userconfig"], &["-c", "--call"])
        }
        "bunx" => (args, &["-p", "--package"], &[]),
        "pnpm" if args.first().is_some_and(|a| a == "dlx") => (
            args.get(1..).unwrap_or_default(),
            &["--package", "--dir", "-C"],
            &["-c", "--shell-mode"],
        ),
        "uvx" => (
            args,
            &[
                "--from",
                "--with",
                "--with-editable",
                "--with-requirements",
                "-w",
                "--python",
                "-p",
                "--index",
                "--default-index",
                "--index-url",
                "-i",
                "--extra-index-url",
                "--find-links",
                "-f",
                "--constraints",
                "--overrides",
                "--cache-dir",
                "--directory",
                "--project",
                "--config-file",
            ],
            &[],
        ),
        "pipx" if args.first().is_some_and(|a| a == "run") => (
            args.get(1..).unwrap_or_default(),
            &[
                "--spec",
                "--python",
                "--index-url",
                "-i",
                "--pip-args",
                "--backend",
                "--fetch-python",
            ],
            &[],
        ),
        _ => return None,
    };
    // `-p PKG`/`--package PKG` (npx, bunx, pnpm dlx), `--from PKG` (uvx) or
    // `--spec PKG` (pipx run) name the package; the command after is one of
    // its binaries. (uvx's `-p` is its Python.)
    let package_options: &[&str] = match program.as_str() {
        "uvx" => &["--from"],
        "pipx" => &["--spec"],
        _ => &["-p", "--package"],
    };
    let (rest, packages) = after_options_with(args, takes_value, refuses, package_options)?;
    let (command, rest) = rest.split_first()?;
    let package_is_cmux = if packages.is_empty() {
        names_cmux_package(command)
    } else {
        packages.iter().all(|package| names_cmux_package(package))
            && CLI_NAMES.contains(&command.as_str())
    };
    (package_is_cmux && serves(rest)).then_some(CmuxServe::Published)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// cmux's server is recognised however an entry runs it: the CLI, a
    /// launcher script under a JavaScript runtime, or a package runner.
    #[test]
    fn cmux_serve_knows_every_way_to_run_cmuxs_server() {
        let of = |command: &str, args: &[&str]| {
            let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
            cmux_serve(command, &args).map(|serve| match serve {
                CmuxServe::Path(path) => path.to_owned(),
                CmuxServe::Published => "published".to_owned(),
            })
        };
        let path = |p: &str| Some(p.to_owned());
        let published = Some("published".to_owned());
        assert_eq!(of("/A/cmux", &["mcp", "serve"]), path("/A/cmux"));
        assert_eq!(of("cmux", &["mcp", "serve", "--all-tools"]), path("cmux"));
        assert_eq!(
            of("/u/node", &["/n/node_modules/cmux/bin/cmux.js", "mcp", "serve"]),
            path("/n/node_modules/cmux/bin/cmux.js")
        );
        assert_eq!(of("npx", &["-y", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("npx", &["cmux@latest", "mcp", "serve"]), published);
        assert_eq!(of("bunx", &["cmux", "mcp", "serve"]), published);
        assert_eq!(of("pnpm", &["dlx", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("uvx", &["cmux", "mcp", "serve"]), published);
        assert_eq!(of("/x/uvx", &["--from", "cmux==1", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("pipx", &["run", "--spec", "cmux", "cmux", "mcp", "serve"]), published);
        // Options with values, in both forms, before the package or script.
        assert_eq!(
            of("uvx", &["--with", "rich", "--python", "3.12", "cmux==1.2", "mcp", "serve"]),
            published
        );
        assert_eq!(of("uvx", &["--python=3.12", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("pipx", &["run", "--python", "python3.12", "cmux", "mcp", "serve"]),
            published
        );
        assert_eq!(of("npx", &["--package", "cmux@1", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("npx", &["-p", "cmux", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("node", &["--require", "/x/hook.js", "/n/cmux/bin/cmux.js", "mcp", "serve"]),
            path("/n/cmux/bin/cmux.js")
        );
        assert_eq!(
            of("node", &["--max-old-space-size=512", "/n/cmux.js", "mcp", "serve"]),
            path("/n/cmux.js")
        );
        assert_eq!(of("/A/cmux-next", &["mcp", "serve"]), path("/A/cmux-next"));
        assert_eq!(of("/A/cmux-tui", &["mcp", "serve"]), path("/A/cmux-tui"));
        // The runners' long forms.
        assert_eq!(of("uv", &["tool", "run", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("uv", &["tool", "run", "--python", "3.12", "cmux", "mcp", "serve"]),
            published
        );
        assert_eq!(of("npm", &["exec", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("npm", &["exec", "--", "cmux", "mcp", "serve"]), published);
        assert_eq!(
            of("npm", &["exec", "--package", "cmux@1", "--", "cmux", "mcp", "serve"]),
            published
        );
        assert_eq!(of("bun", &["x", "cmux", "mcp", "serve"]), published);
        assert_eq!(of("bun", &["run", "/n/cmux.js", "mcp", "serve"]), path("/n/cmux.js"));
        assert_eq!(
            of("uv", &["run", "cmux", "mcp", "serve"]),
            None,
            "uv run is a project's script"
        );
        for (command, args) in [
            ("/A/cmux", &["serve"][..]),
            ("/usr/bin/my-tool", &["mcp", "serve"]),
            ("node", &["/x/other.js", "mcp", "serve"]),
            ("npx", &["-y", "other", "mcp", "serve"]),
            ("pipx", &["install", "cmux"]),
            // Names match exactly, never by prefix.
            ("/A/cmux-helper", &["mcp", "serve"]),
            ("npx", &["cmux-sdk", "mcp", "serve"]),
            ("uvx", &["cmuxtools", "mcp", "serve"]),
            ("node", &["/n/cmux-other.js", "mcp", "serve"]),
            // The value of an option is not the package.
            ("uvx", &["--from", "cmux", "other", "mcp", "serve"]),
            // A package an option names that is not cmux, whose command is
            // only called `cmux`.
            ("npx", &["-p", "evil", "cmux", "mcp", "serve"]),
            ("npx", &["--package=evil@1", "cmux", "mcp", "serve"]),
            ("uvx", &["--from", "evil", "cmux", "mcp", "serve"]),
            ("pipx", &["run", "--spec", "evil", "cmux", "mcp", "serve"]),
            ("bunx", &["-p", "evil", "cmux", "mcp", "serve"]),
            // Code that is no script: not a launch of cmux.
            ("node", &["-e", "x", "/n/cmux.js", "mcp", "serve"]),
            ("npx", &["-c", "cmux mcp serve"]),
        ] {
            assert_eq!(of(command, args), None, "{command} {args:?}");
        }
    }
}

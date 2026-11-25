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
    assert_eq!(of("pipx", &["run", "--python", "python3.12", "cmux", "mcp", "serve"]), published);
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
    assert_eq!(of("uv", &["tool", "run", "--python", "3.12", "cmux", "mcp", "serve"]), published);
    assert_eq!(of("npm", &["exec", "cmux", "mcp", "serve"]), published);
    assert_eq!(of("npm", &["exec", "--", "cmux", "mcp", "serve"]), published);
    assert_eq!(
        of("npm", &["exec", "--package", "cmux@1", "--", "cmux", "mcp", "serve"]),
        published
    );
    assert_eq!(of("bun", &["x", "cmux", "mcp", "serve"]), published);
    assert_eq!(of("bun", &["run", "/n/cmux.js", "mcp", "serve"]), path("/n/cmux.js"));
    assert_eq!(of("uv", &["run", "cmux", "mcp", "serve"]), None, "uv run is a project's script");
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

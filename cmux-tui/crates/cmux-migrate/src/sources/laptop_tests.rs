use super::*;

const TOKEN: &str = "ghp_PLANTEDsecretTOKEN0123456789";

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn repo(dir: &Path, url: Option<&str>, branch: &str) {
    let mut config = "[core]\n\tbare = false\n".to_owned();
    if let Some(url) = url {
        config.push_str(&format!("[remote \"origin\"]\n\turl = {url}\n"));
    }
    write(&dir.join(".git/config"), &config);
    write(&dir.join(".git/HEAD"), &format!("ref: refs/heads/{branch}\n"));
    write(&dir.join(".git/refs/heads").join(branch), &format!("{}\n", "a".repeat(40)));
}

fn opts(home: &Path) -> Options {
    Options { roots: Some(vec![home.join("code")]), macos: false, ..Options::new("box") }
}

fn project<'a>(plan: &'a Plan, name: &str) -> &'a Project {
    plan.projects.iter().find(|p| p.name == name).unwrap_or_else(|| panic!("no {name}: {plan:?}"))
}

#[test]
fn source_is_named_by_host() {
    let home = tempfile::tempdir().unwrap();
    let plan = plan(home.path(), &opts(home.path()), &NoGitFacts);
    assert_eq!(plan.source.id, "laptop:box");
    assert_eq!(plan.source.kind, SourceKind::Laptop);
    assert_eq!(plan.source.label, "this laptop");
    let mac = Options { macos: true, ..opts(home.path()) };
    assert_eq!(super::plan(home.path(), &mac, &NoGitFacts).source.label, "this Mac");
}

#[test]
fn reads_remote_branch_and_commit_without_login() {
    let home = tempfile::tempdir().unwrap();
    let web = home.path().join("code/web");
    repo(&web, Some(&format!("https://me:{TOKEN}@github.com/me/web.git")), "main");
    let plan = plan(home.path(), &opts(home.path()), &NoGitFacts);
    let p = project(&plan, "web");
    let r = p.repo.as_ref().unwrap();
    assert_eq!(r.url.as_deref(), Some("https://github.com/me/web.git"));
    assert_eq!(r.branch.as_deref(), Some("main"));
    assert_eq!(r.commit, Some("a".repeat(40)));
    assert_eq!(r.path.as_deref(), Some("~/code/web"));
    assert_eq!(p.key, "~/code/web");
    assert!(!serde_json::to_string(&plan).unwrap().contains(TOKEN));
}

#[test]
fn remote_prefers_origin_and_reads_packed_refs_and_detached_heads() {
    let cfg = "[remote \"up\"]\n url = git@a:x/y.git\n[remote \"origin\"]\n url = git@b:x/y.git\n";
    assert_eq!(remote_url(cfg).as_deref(), Some("git@b:x/y.git"));
    assert_eq!(
        remote_url("[remote \"up\"]\n url = git@a:x/y.git\n").as_deref(),
        Some("git@a:x/y.git")
    );
    assert_eq!(remote_url("[core]\n url = nope\n"), None);

    let dir = tempfile::tempdir().unwrap();
    let r = dir.path().join("r");
    write(&r.join(".git/config"), "");
    write(&r.join(".git/HEAD"), "ref: refs/heads/dev\n");
    write(
        &r.join(".git/packed-refs"),
        &format!("# pack-refs\n{} refs/heads/dev\n", "b".repeat(40)),
    );
    let repo = read_repo(&r);
    assert_eq!(repo.branch.as_deref(), Some("dev"));
    assert_eq!(repo.commit, Some("b".repeat(40)));
    assert_eq!(repo.url, None);

    write(&r.join(".git/HEAD"), &format!("{}\n", "c".repeat(40)));
    let repo = read_repo(&r);
    assert_eq!(repo.branch, None);
    assert_eq!(repo.commit, Some("c".repeat(40)));
}

#[test]
fn worktree_git_file_uses_the_main_checkouts_config() {
    let home = tempfile::tempdir().unwrap();
    let main = home.path().join("code/main");
    repo(&main, Some("https://github.com/me/main.git"), "main");
    let wt_git = main.join(".git/worktrees/feature");
    write(&wt_git.join("HEAD"), "ref: refs/heads/feature\n");
    write(&wt_git.join("commondir"), "../..\n");
    let wt = home.path().join("code/feature");
    write(&wt.join(".git"), &format!("gitdir: {}\n", wt_git.display()));
    let plan = plan(home.path(), &opts(home.path()), &NoGitFacts);
    let p = project(&plan, "feature");
    let r = p.repo.as_ref().unwrap();
    assert_eq!(r.url.as_deref(), Some("https://github.com/me/main.git"));
    assert_eq!(r.branch.as_deref(), Some("feature"));
    assert!(p.notes.iter().any(|n| n.contains("worktree")));
}

#[test]
fn walk_is_depth_bounded_skips_and_dedupes() {
    let home = tempfile::tempdir().unwrap();
    let code = home.path().join("code");
    repo(&code.join("a/b/c/d"), Some("git@x:d.git"), "main"); // depth 4: found
    repo(&code.join("a/b/c/d2/e"), Some("git@x:e.git"), "main"); // depth 5: not
    repo(&code.join("app/node_modules/dep"), Some("git@x:dep.git"), "main");
    repo(&code.join(".hidden/h"), Some("git@x:h.git"), "main");
    repo(&code.join("Library/l"), Some("git@x:l.git"), "main");
    repo(&code.join("outer"), Some("git@x:outer.git"), "main");
    repo(&code.join("outer/inner"), Some("git@x:inner.git"), "main"); // inside a checkout
    let roots = vec![code.clone(), code.clone(), code.join("outer")]; // the same checkouts again
    let found = find_checkouts(&roots, &[code.join("outer/src")], 4, 100);
    let names: Vec<String> = found
        .checkouts
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec!["d", "outer"], "{found:?}");
    assert!(!found.truncated);

    let bounded = find_checkouts(&[code], &[], 4, 1);
    assert_eq!(bounded.checkouts.len(), 1);
    assert!(bounded.truncated);
}

#[test]
fn bound_warns_and_names_stay_unique() {
    let home = tempfile::tempdir().unwrap();
    repo(&home.path().join("code/one/app"), Some("git@x:1.git"), "main");
    repo(&home.path().join("code/two/app"), Some("git@x:2.git"), "main");
    repo(&home.path().join("code/three/app"), Some("git@x:3.git"), "main");
    let plan = plan(home.path(), &opts(home.path()), &NoGitFacts);
    let mut names: Vec<&str> = plan.projects.iter().map(|p| p.name.as_str()).collect();
    names.sort_unstable();
    assert_eq!(names, vec!["app", "app-2", "app-3"]);

    let few = Options { max_repos: 2, ..opts(home.path()) };
    let plan = super::plan(home.path(), &few, &NoGitFacts);
    assert_eq!(plan.projects.len(), 2);
    assert!(plan.warnings.iter().any(|w| w.contains("stopped looking after 2")));
}

#[test]
fn default_roots_are_read_when_none_given() {
    let home = tempfile::tempdir().unwrap();
    for root in DEFAULT_ROOTS {
        repo(&home.path().join(root).join("r"), Some("git@x:r.git"), "main");
    }
    repo(&home.path().join("elsewhere/r"), Some("git@x:r.git"), "main");
    let options = Options { macos: false, ..Options::new("box") };
    let plan = plan(home.path(), &options, &NoGitFacts);
    assert_eq!(plan.projects.len(), DEFAULT_ROOTS.len());
}

#[test]
fn git_facts_fill_work_and_warn() {
    let home = tempfile::tempdir().unwrap();
    repo(&home.path().join("code/busy"), Some("git@x:busy.git"), "main");
    repo(&home.path().join("code/local"), None, "main");
    repo(&home.path().join("code/clean"), Some("git@x:clean.git"), "main");
    let facts = |p: &Path| {
        if p.ends_with("busy") {
            Work { dirty_files: 3, unpushed_commits: 2 }
        } else {
            Work::default()
        }
    };
    let plan = plan(home.path(), &opts(home.path()), &facts);
    let busy = project(&plan, "busy").repo.as_ref().unwrap();
    assert_eq!((busy.dirty_files, busy.unpushed_commits), (3, 2));
    assert!(plan.warnings.iter().any(|w| w.contains("~/code/busy: 3 uncommitted files and 2")));
    assert!(plan.warnings.iter().any(|w| w.contains("~/code/local: no remote")));
    assert!(!plan.warnings.iter().any(|w| w.contains("clean")));
    let steps = plan.steps();
    let carried: Vec<&str> = steps
        .iter()
        .filter_map(|s| match s {
            crate::Step::CarryWorktree { path, .. } => Some(path.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(carried.len(), 2);
}

#[test]
fn git_cli_counts_real_work() {
    let dir = tempfile::tempdir().unwrap();
    let r = dir.path();
    let git = |args: &[&str]| {
        Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
            .arg("-C")
            .arg(r)
            .args(args)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    };
    if !git(&["init", "-q"]) {
        return; // no git on this machine
    }
    write(&r.join("a.txt"), "a");
    assert!(git(&["add", "."]));
    assert!(git(&["commit", "-qm", "one"]));
    write(&r.join("b.txt"), "b");
    write(&r.join("a.txt"), "changed");
    let work = GitCli::default().work(r);
    assert_eq!(work, Work { dirty_files: 2, unpushed_commits: 1 });
}

#[test]
fn lockfiles_become_setup_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let r = dir.path();
    for f in [
        ".tool-versions",
        "bun.lock",
        "package-lock.json",
        "uv.lock",
        "Cargo.toml",
        "go.mod",
        "Gemfile.lock",
    ] {
        write(&r.join(f), "");
    }
    let (m, _) = machine_config(r);
    assert_eq!(
        m.setup,
        vec![
            "mise install",
            "bun install",
            "uv sync",
            "cargo fetch",
            "go mod download",
            "bundle install"
        ]
    );

    let cases: &[(&[&str], &[&str])] = &[
        (&["pnpm-lock.yaml"], &["pnpm install --frozen-lockfile"]),
        (&["package-lock.json"], &["npm ci"]),
        (&["yarn.lock"], &["yarn install --frozen-lockfile"]),
        (&["yarn.lock", ".yarnrc.yml"], &["yarn install --immutable"]),
        (&["bun.lockb"], &["bun install"]),
        (&["poetry.lock"], &["poetry install"]),
        (&["requirements.txt"], &["pip install -r requirements.txt"]),
        (&["mise.toml"], &["mise install"]),
        (&[".mise.toml", ".nvmrc"], &["mise install"]),
        (&[], &[]),
    ];
    for (files, setup) in cases {
        let dir = tempfile::tempdir().unwrap();
        for f in *files {
            write(&dir.path().join(f), "");
        }
        assert_eq!(machine_config(dir.path()).0.setup, *setup, "{files:?}");
    }

    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join(".nvmrc"), "v20.11.1\n");
    assert_eq!(machine_config(dir.path()).0.setup, vec!["mise use --global node@20.11.1"]);
    write(&dir.path().join(".nvmrc"), "lts/*; rm -rf ~\n");
    let (m, notes) = machine_config(dir.path());
    assert!(m.setup.is_empty());
    assert!(notes.iter().any(|n| n.contains(".nvmrc")));
}

#[test]
fn own_machine_toml_and_devcontainer_are_noted() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join(".cmux/machine.toml"), "[setup]\nrun = [\"make\"]\n");
    write(&dir.path().join(".devcontainer/devcontainer.json"), "{}");
    write(&dir.path().join("bun.lock"), "");
    write(&dir.path().join(".env.example"), "API_KEY=\n");
    let (m, notes) = machine_config(dir.path());
    assert!(m.setup.is_empty());
    assert!(m.secret_names.contains("API_KEY"));
    assert!(notes.iter().any(|n| n.contains("own .cmux/machine.toml")));
    assert!(notes.iter().any(|n| n == "devcontainer found: see the devcontainer source"));
}

#[test]
fn env_examples_give_names_and_env_values_stay_out() {
    let home = tempfile::tempdir().unwrap();
    let app = home.path().join("code/app");
    repo(&app, Some("git@x:app.git"), "main");
    write(
        &app.join(".env.example"),
        &format!(
            "# comment\nDATABASE_URL=postgres://u:{TOKEN}@db\nexport STRIPE_KEY=\nbad key=1\n1X=2\n"
        ),
    );
    write(&app.join(".env.sample"), "SAMPLE_ONE=x\n");
    write(&app.join(".env.template"), "TEMPLATE_ONE=\n");
    write(&app.join(".env"), &format!("OPENAI_API_KEY={TOKEN}\n"));
    let plan = plan(home.path(), &opts(home.path()), &NoGitFacts);
    let names: Vec<&str> =
        project(&plan, "app").machine.secret_names.iter().map(String::as_str).collect();
    assert_eq!(names, vec!["DATABASE_URL", "SAMPLE_ONE", "STRIPE_KEY", "TEMPLATE_ONE"]);
    assert!(
        plan.warnings.iter().any(|w| w.contains("~/code/app/.env: its values will be offered"))
    );
    let json = serde_json::to_string(&plan).unwrap();
    assert!(!json.contains(TOKEN));
    assert!(!json.contains("OPENAI_API_KEY"));
}

#[test]
fn chats_link_by_cwd_and_slug() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    let app = h.join("code/app");
    repo(&app, Some("git@x:app.git"), "main");
    let app_real = fs::canonicalize(&app).unwrap();
    // Claude: a transcript whose cwd is a subfolder, and a slug-only folder with no cwd.
    fs::create_dir_all(app.join("web")).unwrap();
    let sub = h.join(".claude/projects/whatever-sub");
    write(
        &sub.join("1.jsonl"),
        &format!("{{\"type\":\"summary\"}}\n{{\"cwd\":\"{}\"}}\n", app_real.join("web").display()),
    );
    let slug = h.join(".claude/projects").join(claude_slug(&app_real));
    write(&slug.join("2.jsonl"), "{\"type\":\"summary\"}\n");
    // Codex: first line's payload cwd; a later-line cwd does not count.
    write(
        &h.join(".codex/sessions/2026/11/24/rollout-1.jsonl"),
        &format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"cwd\":\"{}\"}}}}\n",
            app_real.display()
        ),
    );
    write(
        &h.join(".codex/sessions/2026/11/24/rollout-2.jsonl"),
        &format!("{{\"type\":\"x\"}}\n{{\"cwd\":\"{}\"}}\n", app_real.display()),
    );
    // Cursor (Linux path), percent-encoded.
    let spaced = h.join("code/my app");
    repo(&spaced, Some("git@x:spaced.git"), "main");
    let spaced_real = fs::canonicalize(&spaced).unwrap();
    write(
        &h.join(".config/Cursor/User/workspaceStorage/abc/workspace.json"),
        &format!(
            "{{\"folder\":\"file://{}\"}}",
            spaced_real.display().to_string().replace(' ', "%20")
        ),
    );
    let plan = plan(h, &opts(h), &NoGitFacts);
    let chats = &project(&plan, "app").chats;
    assert!(chats.contains(&ChatRef {
        agent: Agent::Claude,
        path: "~/.claude/projects/whatever-sub".into()
    }));
    assert!(
        chats.iter().any(|c| c.agent == Agent::Claude && c.path.ends_with(&claude_slug(&app_real)))
    );
    assert!(chats.contains(&ChatRef {
        agent: Agent::Codex,
        path: "~/.codex/sessions/2026/11/24/rollout-1.jsonl".into()
    }));
    assert_eq!(chats.len(), 3, "{chats:?}");
    assert_eq!(
        project(&plan, "my-app").chats,
        vec![ChatRef {
            agent: Agent::Cursor,
            path: "~/.config/Cursor/User/workspaceStorage/abc".into()
        }]
    );
}

#[test]
fn history_folders_outside_roots_become_projects() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    let far = h.join("clients/acme/site");
    repo(&far, Some("git@x:site.git"), "main");
    fs::create_dir_all(far.join("pkg")).unwrap();
    write(
        &h.join(".codex/sessions/a.jsonl"),
        &format!("{{\"cwd\":\"{}\"}}\n", far.join("pkg").display()),
    );
    // A recorded folder that no longer exists adds nothing.
    write(&h.join(".codex/sessions/b.jsonl"), "{\"cwd\":\"/nonexistent/gone\"}\n");
    let plan = plan(h, &opts(h), &NoGitFacts);
    assert_eq!(plan.projects.len(), 1);
    assert_eq!(plan.projects[0].key, "~/clients/acme/site");
    assert_eq!(plan.projects[0].chats.len(), 1);
}

#[test]
fn carry_lists_machine_wide_items_with_sizes() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    write(&h.join(".zshrc"), "alias g=git\n");
    write(&h.join(".config/starship.toml"), "");
    write(&h.join(".zsh_history"), "ls\n");
    write(&h.join(".gitconfig"), "[user]\n name = Me\n[credential]\n helper = osxkeychain\n");
    write(&h.join("Library/Application Support/Code/User/settings.json"), "{}");
    write(&h.join(".config/Cursor/User/keybindings.json"), "[]");
    write(&h.join(".vscode/extensions/extensions.json"), "[]");
    fs::create_dir_all(h.join(".vscode/extensions/rust-lang.rust-analyzer-0.3")).unwrap();
    fs::create_dir_all(h.join(".vscode/extensions/esbenp.prettier-vscode-10")).unwrap();
    write(&h.join(".config/nvim/init.lua"), "-- hi\n");
    write(&h.join(".vimrc"), "");
    write(&h.join(".config/zed/settings.json"), "{}");
    write(&h.join(".config/helix/config.toml"), "");
    write(&h.join(".claude/settings.json"), "{}");
    write(&h.join(".claude/CLAUDE.md"), "rules");
    write(&h.join(".claude/skills/x/SKILL.md"), "12345");
    write(&h.join(".codex/config.toml"), "");
    write(&h.join(".codex/AGENTS.md"), "");
    write(&h.join(".claude/projects/p/1.jsonl"), "0123456789");
    write(&h.join(".codex/sessions/2026/1.jsonl"), "01234");
    write(&h.join(".codex/auth.json"), &format!("{{\"token\":\"{TOKEN}\"}}"));
    write(&h.join(".claude/.credentials.json"), &format!("{{\"t\":\"{TOKEN}\"}}"));
    write(&h.join(".ssh/config"), "Host x\n");
    write(&h.join(".ssh/id_ed25519"), TOKEN);
    repo(&h.join(".dotfiles"), Some("git@github.com:me/dotfiles.git"), "main");
    repo(&h.join("dotfiles"), None, "main"); // no remote: not a dotfiles repo to clone

    let plan = plan(h, &Options { macos: true, ..opts(h) }, &NoGitFacts);
    let has = |kind: CarryKind, path: &str| {
        plan.carry.iter().find(|c| c.kind == kind && c.path == path).cloned()
    };
    for (kind, path) in [
        (CarryKind::Shell, "~/.zshrc"),
        (CarryKind::Shell, "~/.config/starship.toml"),
        (CarryKind::ShellHistory, "~/.zsh_history"),
        (CarryKind::GitConfig, "~/.gitconfig"),
        (CarryKind::Editor, "~/Library/Application Support/Code/User/settings.json"),
        (CarryKind::Editor, "~/.config/Cursor/User/keybindings.json"),
        (CarryKind::Editor, "~/.vscode/extensions/extensions.json"),
        (CarryKind::Editor, "~/.config/nvim"),
        (CarryKind::Editor, "~/.vimrc"),
        (CarryKind::Editor, "~/.config/zed/settings.json"),
        (CarryKind::Editor, "~/.config/helix"),
        (CarryKind::AgentSettings, "~/.claude/settings.json"),
        (CarryKind::AgentSettings, "~/.claude/CLAUDE.md"),
        (CarryKind::AgentSettings, "~/.claude/skills"),
        (CarryKind::AgentSettings, "~/.codex/config.toml"),
        (CarryKind::AgentSettings, "~/.codex/AGENTS.md"),
        (CarryKind::AgentHistory, "~/.claude/projects"),
        (CarryKind::AgentHistory, "~/.codex/sessions"),
        (CarryKind::AgentLogin, "~/.codex/auth.json"),
        (CarryKind::AgentLogin, "~/.claude/.credentials.json"),
        (CarryKind::SshConfig, "~/.ssh/config"),
        (CarryKind::DotfilesRepo, "~/.dotfiles"),
    ] {
        assert!(has(kind, path).is_some(), "{kind:?} {path}: {:?}", plan.carry);
    }
    assert_eq!(has(CarryKind::Shell, "~/.zshrc").unwrap().bytes, 12);
    // Shell history can hold typed tokens: listed, never carried unless checked.
    assert!(!has(CarryKind::ShellHistory, "~/.zsh_history").unwrap().checked);
    assert!(has(CarryKind::Shell, "~/.zshrc").unwrap().checked);
    assert!(!plan.steps().iter().any(|s| matches!(s,
        crate::Step::CarryFiles { paths } if paths.iter().any(|p| p.ends_with("_history")))));
    assert_eq!(has(CarryKind::AgentSettings, "~/.claude/skills").unwrap().bytes, 5);
    assert_eq!(has(CarryKind::AgentHistory, "~/.claude/projects").unwrap().bytes, 10);
    assert_eq!(has(CarryKind::AgentHistory, "~/.codex/sessions").unwrap().bytes, 5);
    assert_eq!(has(CarryKind::AgentLogin, "~/.codex/auth.json").unwrap().agent, Some(Agent::Codex));
    assert!(!plan.carry.iter().any(|c| c.path.contains(".ssh/id_")));
    assert!(!plan.carry.iter().any(|c| c.path == "~/dotfiles"));
    // The login is a file here, so no Keychain note.
    assert!(plan.unsupported.is_empty());
    // Logins go over the secret channel.
    assert!(plan.steps().iter().any(|s| matches!(s,
        crate::Step::CarrySecretFiles { paths } if paths.contains(&"~/.codex/auth.json".to_owned()))));
    assert!(!serde_json::to_string(&plan).unwrap().contains(TOKEN));

    assert_eq!(
        editor_extensions(h, "vscode"),
        vec!["esbenp.prettier-vscode-10", "rust-lang.rust-analyzer-0.3"]
    );
    assert!(editor_extensions(h, "cursor").is_empty());
}

#[test]
fn credential_store_gitconfig_is_skipped_with_a_warning() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    write(
        &h.join(".gitconfig"),
        "[user]\n name = Me\n[credential \"https://github.com\"]\n\thelper = store --file ~/.tok\n",
    );
    write(&h.join(".git-credentials"), &format!("https://me:{TOKEN}@github.com\n"));
    let plan = plan(h, &opts(h), &NoGitFacts);
    assert!(!plan.carry.iter().any(|c| c.kind == CarryKind::GitConfig));
    assert!(plan.warnings.iter().any(|w| w.contains("~/.gitconfig uses git's credential store")));
    assert!(plan.warnings.iter().any(|w| w.contains("~/.git-credentials")));
    assert!(!serde_json::to_string(&plan).unwrap().contains(TOKEN));

    assert!(stores_credentials("[credential]\n helper = store\n"));
    assert!(!stores_credentials("[credential]\n helper = osxkeychain\n"));
    assert!(!stores_credentials("[alias]\n helper = store\n"));
}

#[test]
fn mac_claude_login_in_keychain_is_unsupported_here() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    let mac = plan(h, &Options { macos: true, ..opts(h) }, &NoGitFacts);
    assert_eq!(mac.unsupported.len(), 1);
    assert!(mac.unsupported[0].what.contains("Keychain"));
    assert!(mac.unsupported[0].why.contains("cmux sign-in flow"));
    assert!(plan(h, &opts(h), &NoGitFacts).unsupported.is_empty());
}

#[test]
fn helpers_decode_and_shorten() {
    assert_eq!(percent_decode("/a%20b/c%2"), "/a b/c%2");
    assert_eq!(percent_decode("/caf%C3%A9"), "/café");
    assert_eq!(claude_slug(Path::new("/Users/me/my.app")), "-Users-me-my-app");
    let home = Path::new("/nonexistent-home");
    assert_eq!(tilde(home, &home.join("x/y")), "~/x/y");
    assert_eq!(tilde(home, Path::new("/opt/z")), "/opt/z");
}

//! `cmux git review start|comment` and `git.review.post` through a real
//! daemon, with a stand-in `gh` on its PATH: a pull request is checked out
//! into a review worktree whose base is its merge-base, an agent's drafts land
//! in the diff page's comment store on lines of its diff (and are refused on
//! others), and posting sends them as one review on the reviewed head, inline
//! where GitHub shows the line and in the body where it does not, then clears
//! them. Only the cmux app's own connection posts: the daemon starts with
//! `server ensure --install-key-stdin`, and a plain connection's post is
//! refused.
#![cfg(unix)]

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};

use super::*;

const KEY_HEX: &str = "5c2e1d0f3b4a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff1";
const INSTALL: &str = "inst_git_review";

/// A daemon with the app's install key, the person's HOME and a PATH whose
/// `gh` is the stand-in.
struct Owner {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    environment: Vec<(String, String)>,
}

impl Owner {
    fn start(dir: &std::path::Path, environment: &[(&str, &str)]) -> Self {
        let environment =
            environment.iter().map(|(name, value)| (name.to_string(), value.to_string())).collect();
        fs::create_dir_all(dir).unwrap();
        let owner = Self {
            dir: dir.to_path_buf(),
            socket: dir.join("mux.sock"),
            session: format!("git-review-{}", std::process::id()),
            environment,
        };
        let mut child = owner
            .server("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success(), "ensure: {}", String::from_utf8_lossy(&output.stderr));
        owner
    }

    fn server(&self, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .envs(self.environment.iter().map(|(name, value)| (name, value)));
        command
    }

    /// A connection; `app`: proven the cmux app (`client-hello`), else a
    /// plain one, as an agent's.
    fn connect(&self, app: bool) -> BufReader<UnixStream> {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut reader = BufReader::new(stream);
        if app {
            let hello =
                serde_json::json!({"cmd": "client-hello", "role": "main", "install_id": INSTALL});
            let challenge = reply(&mut reader, "hello", hello);
            let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
            let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL, &nonce);
            let proof =
                serde_json::json!({"cmd": "client-hello", "install_id": INSTALL, "proof": proof});
            let proved = reply(&mut reader, "proof", proof);
            assert_eq!(proved["data"]["verified"], true, "{proved}");
        }
        reader
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
    }
}

/// Sends `request` under `id` and answers the reply with that id.
fn reply(
    reader: &mut BufReader<UnixStream>,
    id: &str,
    mut request: serde_json::Value,
) -> serde_json::Value {
    request["id"] = serde_json::json!(id);
    writeln!(reader.get_mut(), "{request}").unwrap();
    loop {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0, "closed before {request}");
        let answer: serde_json::Value = serde_json::from_str(&line).unwrap();
        if answer["id"] == request["id"] {
            return answer;
        }
    }
}

fn git(dir: &std::path::Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn git_cli(server: &Owner, cwd: &std::path::Path, args: &[&str]) -> Output {
    Command::new(bin())
        .current_dir(cwd)
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .arg("git")
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

fn v2(
    server: &Owner,
    operation: &str,
    params: serde_json::Value,
    key: Option<&str>,
) -> serde_json::Value {
    request(server, false, operation, params, key)
}

/// `git.review.post` as the person's click sends it: on the app's connection.
fn post(server: &Owner, params: serde_json::Value, key: &str) -> serde_json::Value {
    request(server, true, "git.review.post", params, Some(key))
}

fn request(
    server: &Owner,
    app: bool,
    operation: &str,
    params: serde_json::Value,
    key: Option<&str>,
) -> serde_json::Value {
    let mut params = params;
    params["machine"] = serde_json::json!("current");
    params["session"] = serde_json::json!("current");
    let mut request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = serde_json::json!(key);
    }
    let id = format!("{operation}-{}", key.unwrap_or("read"));
    let answer = reply(&mut server.connect(app), &id, request);
    // A refusal the test expects comes back as it is.
    let expected = key.is_some_and(|key| key.ends_with("-refused"));
    assert!(answer["ok"] == true || expected, "{operation} failed: {answer}");
    answer
}

#[test]
fn git_review_checks_out_a_pull_request_drafts_on_its_diff_and_posts_one_review() {
    let root = std::env::temp_dir().join(format!(
        "cmux-git-review-{}-{:x}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    let (home, upstream, checkout, bin_dir) =
        (root.join("home"), root.join("upstream"), root.join("project"), root.join("bin"));
    for dir in [&home, &upstream, &bin_dir] {
        fs::create_dir_all(dir).unwrap();
    }

    // The pull request's repository: main, then a pull request branch from
    // its first commit (refs/pull/7/head), then main moves on.
    git(&upstream, &["init", "-q", "-b", "main"]);
    git(&upstream, &["config", "user.name", "cmux test"]);
    git(&upstream, &["config", "user.email", "cmux@example.invalid"]);
    git(&upstream, &["config", "commit.gpgsign", "false"]);
    let lines: Vec<String> = (1..=20).map(|n| format!("line {n}")).collect();
    fs::write(upstream.join("a.txt"), lines.join("\n") + "\n").unwrap();
    fs::write(upstream.join("old name.txt"), "x 1\nx 2\nx 3\nx 4\nx 5\n").unwrap();
    git(&upstream, &["add", "a.txt", "old name.txt"]);
    git(&upstream, &["commit", "-q", "-m", "first"]);
    let merge_base = git(&upstream, &["rev-parse", "HEAD"]);
    git(&upstream, &["checkout", "-q", "-b", "feature"]);
    let mut changed = lines;
    changed[9] = "line 10, fixed".to_string();
    fs::write(upstream.join("a.txt"), changed.join("\n") + "\n").unwrap();
    // A renamed file whose name has a space: its base side is under its old name.
    git(&upstream, &["mv", "old name.txt", "new name.txt"]);
    fs::write(upstream.join("new name.txt"), "x 1\nx 2\nx 3 changed\nx 4\nx 5\n").unwrap();
    git(&upstream, &["commit", "-q", "-am", "fix line 10"]);
    let head = git(&upstream, &["rev-parse", "HEAD"]);
    git(&upstream, &["update-ref", "refs/pull/7/head", &head]);
    git(&upstream, &["checkout", "-q", "main"]);
    fs::write(upstream.join("b.txt"), "later\n").unwrap();
    git(&upstream, &["add", "b.txt"]);
    git(&upstream, &["commit", "-q", "-m", "main moves on"]);
    let main = git(&upstream, &["rev-parse", "HEAD"]);

    // The person's clone names the repository by its GitHub address; git
    // fetches it from the local copy.
    git(&root, &["clone", "-q", upstream.to_str().unwrap(), checkout.to_str().unwrap()]);
    git(&checkout, &["remote", "set-url", "origin", "https://github.com/o/r.git"]);
    let rewrite = format!("url.{}.insteadOf", upstream.display());
    git(&checkout, &["config", &rewrite, "https://github.com/o/r.git"]);
    // The person's own settings: a hook that would run the checked-out code,
    // and diffs with no `a/` `b/` prefixes.
    let hook_ran = root.join("hook-ran");
    fs::create_dir_all(checkout.join(".git/hooks")).unwrap();
    let hook = checkout.join(".git/hooks/post-checkout");
    fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", hook_ran.display())).unwrap();
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
    // A hook the fetch would run when it writes the pull request's refs.
    let transaction = checkout.join(".git/hooks/reference-transaction");
    fs::write(&transaction, format!("#!/bin/sh\ntouch '{}'\n", hook_ran.display())).unwrap();
    fs::set_permissions(&transaction, fs::Permissions::from_mode(0o755)).unwrap();
    git(&checkout, &["config", "diff.noprefix", "true"]);
    // A filter driver the person set up that runs a script from the checkout:
    // the pull request could change that script.
    fs::create_dir_all(checkout.join(".git/info")).unwrap();
    let attributes = "*.txt filter=mine\na.txt filter=branchy\n";
    fs::write(checkout.join(".git/info/attributes"), attributes).unwrap();
    let smudge = format!("touch '{}'; cat", hook_ran.display());
    git(&checkout, &["config", "filter.mine.smudge", &smudge]);
    git(&checkout, &["config", "filter.mine.required", "true"]);
    // And one that only a review branch's own configuration turns on.
    let branchy = root.join("branchy.gitconfig");
    // Its fetch command too: a fetch from a review's worktree must not run it.
    let fetch_ran = root.join("fetch-ran");
    let driver = format!(
        "[filter \"branchy\"]\n\tsmudge = \"{smudge}\"\n\trequired = true\n[remote \"origin\"]\n\tuploadpack = \"touch '{}'; git-upload-pack\"\n",
        fetch_ran.display()
    );
    fs::write(&branchy, driver).unwrap();
    git(&checkout, &["config", "includeIf.onbranch:cmux/review-*.path", branchy.to_str().unwrap()]);

    // gh: `pr view` answers the pull request; a POST keeps what it was sent and
    // counts itself; a read of the reviews answers existing.txt, if any.
    let view = serde_json::json!({
        "title": "Fix line 10",
        "headRefOid": head,
        "baseRefOid": main,
        "baseRefName": "main",
    });
    fs::write(bin_dir.join("view.json"), view.to_string()).unwrap();
    let posted = bin_dir.join("posted.json");
    let (posts, existing) = (bin_dir.join("posts.log"), bin_dir.join("existing.txt"));
    let script = format!(
        "#!/bin/sh\ncase \"$1 $3\" in\n  pr*) cat '{}' ;;\n  'api POST') cat > '{}'; echo post >> '{}'; printf '%s' '{{\"html_url\":\"https://github.com/o/r/pull/7#pullrequestreview-1\"}}' ;;\n  api*) cat '{}' 2>/dev/null; true ;;\n  *) exit 2 ;;\nesac\n",
        bin_dir.join("view.json").display(),
        posted.display(),
        posts.display(),
        existing.display()
    );
    let gh = bin_dir.join("gh");
    fs::write(&gh, script).unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}", bin_dir.display(), std::env::var("PATH").unwrap_or_default());
    let server =
        Owner::start(&root.join("owner"), &[("HOME", home.to_str().unwrap()), ("PATH", &path)]);

    let url = "https://github.com/o/r/pull/7/files";
    let started =
        git_cli(&server, &checkout, &["review", "start", url, "--idempotency-key", "rv-one"]);
    assert_success(&started);
    let value = json_output(&started)["value"].clone();
    let worktree = home.join(".cmux/worktrees/project/review-7");
    let review_root = value["root"].as_str().unwrap().to_string();
    assert_eq!(
        fs::canonicalize(&review_root).unwrap(),
        fs::canonicalize(&worktree).unwrap(),
        "{value}"
    );
    assert_eq!(value["branch"], "cmux/review-7", "{value}");
    assert_eq!(value["url"], "https://github.com/o/r/pull/7", "{value}");
    assert_eq!(value["repo"], "o/r", "{value}");
    assert_eq!(value["head"], head.as_str(), "{value}");
    assert_eq!(value["base"], merge_base.as_str(), "the base is the merge-base, not main's tip");
    assert_eq!(value["reused"], false, "{value}");
    // The pull request's own setup script never runs before anyone read it,
    // and no git hook runs in its checkout either.
    assert_eq!(value["setup"]["state"], "none", "{value}");
    assert!(!hook_ran.exists(), "a hook or filter ran in the review's checkout");
    assert_eq!(git(&worktree, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&checkout, &["config", "--get", "branch.cmux/review-7.cmuxBase"]), merge_base);
    // Started again from inside the review's worktree: git runs in the main
    // checkout, so the review branch's fetch command never runs.
    let inside =
        git_cli(&server, &worktree, &["review", "start", url, "--idempotency-key", "rv-inside"]);
    assert_success(&inside);
    assert_eq!(json_output(&inside)["value"]["reused"], true);
    assert!(!fetch_ran.exists(), "a review branch's fetch command ran");
    // The person's checkout stays on its branch.
    assert_eq!(git(&checkout, &["rev-parse", "--abbrev-ref", "HEAD"]), "main");

    // The same head again: the same worktree, with its drafts.
    let again =
        git_cli(&server, &checkout, &["review", "start", url, "--idempotency-key", "rv-two"]);
    assert_success(&again);
    assert_eq!(json_output(&again)["value"]["reused"], true);
    assert_eq!(json_output(&again)["value"]["root"], review_root.as_str());

    // A line the diff does not show is refused with the lines it does.
    let outside = ["review", "comment", "--file", "a.txt", "--line", "1", "--message", "x"];
    let refused = git_cli(&server, &worktree, &outside);
    assert!(!refused.status.success(), "a line outside the diff was accepted");
    let reason = String::from_utf8_lossy(&refused.stderr).to_string();
    assert!(reason.contains("not_in_diff") && reason.contains("7-13"), "{reason}");

    let draft =
        ["review", "comment", "--file", "a.txt", "--line", "10", "--message", "Say what was fixed"];
    let saved = git_cli(&server, &worktree, &draft);
    assert_success(&saved);
    let comment = json_output(&saved)["value"]["comment"].clone();
    assert_eq!(comment["filePath"], "a.txt", "{comment}");
    assert_eq!(comment["side"], "additions", "{comment}");
    assert_eq!(comment["lineText"], "line 10, fixed", "{comment}");
    let renamed = [
        "review",
        "comment",
        "--file",
        "new name.txt",
        "--line",
        "3",
        "--side",
        "old",
        "--message",
        "Why this change?",
    ];
    let renamed = git_cli(&server, &worktree, &renamed);
    assert_success(&renamed);
    assert_eq!(json_output(&renamed)["value"]["comment"]["lineText"], "x 3");

    // The diff page lists the draft and the pull request it goes to; a
    // comment the person left on a line GitHub does not show goes too.
    let mut ids =
        vec![comment["id"].clone(), json_output(&renamed)["value"]["comment"]["id"].clone()];
    let mine = v2(
        &server,
        "diff.comments.save",
        serde_json::json!({"root": review_root, "comment": {
            "filePath": "a.txt", "side": "additions", "startLine": 2, "endLine": 2,
            "lineText": "line 2", "message": "And here",
        }}),
        Some("dc-mine"),
    );
    ids.push(mine["result"]["value"]["comment"]["id"].clone());
    let listed = v2(&server, "diff.comments.list", serde_json::json!({"root": review_root}), None);
    assert_eq!(listed["result"]["review"]["number"], 7, "{listed}");
    assert_eq!(listed["result"]["review"]["base"], merge_base.as_str(), "{listed}");
    assert_eq!(listed["result"]["comments"].as_array().unwrap().len(), 3, "{listed}");

    // A post names each draft's version as the page read it; one without is
    // refused, since its retry could not tell an edit from what it posted.
    let unversioned = post(
        &server,
        serde_json::json!({"root": review_root, "ids": ids}),
        "post-unversioned-refused",
    );
    assert_eq!(unversioned["ok"], false, "{unversioned}");
    assert!(unversioned.to_string().contains("versions"), "{unversioned}");
    let mut versions = serde_json::Map::new();
    for comment in listed["result"]["comments"].as_array().unwrap() {
        let id = comment["id"].as_str().unwrap().to_string();
        versions.insert(id, comment["updatedAt"].clone());
    }
    // Only the app's own connection posts: an agent's is refused, and gh never runs.
    let params = serde_json::json!({"root": review_root, "ids": ids, "versions": versions});
    let agent = v2(&server, "git.review.post", params.clone(), Some("post-agent-refused"));
    assert_eq!(agent["error"]["code"], "origin.forbidden", "{agent}");
    assert!(!posts.exists(), "an agent's post reached GitHub");
    let answer = post(&server, params, "post-once");
    let result = &answer["result"]["value"];
    assert_eq!(result["url"], "https://github.com/o/r/pull/7#pullrequestreview-1", "{answer}");
    assert_eq!(
        (result["posted"].clone(), result["in_body"].clone()),
        (2.into(), 1.into()),
        "{answer}"
    );
    assert_eq!(result["cleared"].as_array().unwrap().len(), 3, "{answer}");
    let sent: serde_json::Value = serde_json::from_slice(&fs::read(&posted).unwrap()).unwrap();
    assert_eq!(sent["commit_id"], head.as_str(), "{sent}");
    assert_eq!(sent["event"], "COMMENT", "{sent}");
    assert_eq!(
        sent["comments"],
        serde_json::json!([
            {"path": "a.txt", "body": "Say what was fixed", "line": 10, "side": "RIGHT"},
            {"path": "new name.txt", "body": "Why this change?", "line": 3, "side": "LEFT"},
        ]),
        "{sent}"
    );
    assert!(sent["body"].as_str().unwrap().contains("`a.txt:2`: And here"), "{sent}");
    let listed = v2(&server, "diff.comments.list", serde_json::json!({"root": review_root}), None);
    assert!(listed["result"]["comments"].as_array().unwrap().is_empty(), "{listed}");

    // A post whose answer was lost: GitHub already has its review (found by
    // the key's marker), so the retry posts nothing and clears the draft.
    let again = git_cli(&server, &worktree, &draft);
    assert_success(&again);
    let draft_again = json_output(&again)["value"]["comment"].clone();
    let (id, version) = (draft_again["id"].clone(), draft_again["updatedAt"].clone());
    fs::write(&existing, "https://github.com/o/r/pull/7#pullrequestreview-2\n").unwrap();
    let id_text = id.as_str().unwrap().to_string();
    let retried = post(
        &server,
        serde_json::json!({"root": review_root, "ids": [id], "versions": {id_text: version}}),
        "post-lost",
    );
    assert_eq!(
        retried["result"]["value"]["url"],
        "https://github.com/o/r/pull/7#pullrequestreview-2"
    );
    assert_eq!(fs::read_to_string(&posts).unwrap().lines().count(), 1, "the retry posted again");

    // A worktree on the review's branch name that no review recorded is not
    // taken over: a new one is made, and its comments stay.
    git(&checkout, &["config", "--unset", "branch.cmux/review-7.cmuxReview"]);
    let note = serde_json::json!({"root": review_root, "comment": {
        "filePath": "a.txt", "side": "additions", "startLine": 2, "endLine": 2,
        "lineText": "line 2", "message": "Mine, not the review's",
    }});
    v2(&server, "diff.comments.save", note, Some("dc-note"));
    let other =
        git_cli(&server, &checkout, &["review", "start", url, "--idempotency-key", "rv-three"]);
    assert_success(&other);
    let other = json_output(&other)["value"].clone();
    assert_eq!(other["reused"], false, "{other}");
    assert_ne!(other["root"], review_root.as_str(), "{other}");
    let listed = v2(&server, "diff.comments.list", serde_json::json!({"root": review_root}), None);
    assert_eq!(listed["result"]["comments"].as_array().unwrap().len(), 1, "{listed}");

    // Removing a review's worktree runs no teardown: the project's recipe can
    // name a script the pull request changed.
    let teardown_ran = root.join("teardown-ran");
    let recipe = format!("teardown = \"touch '{}'\"\n", teardown_ran.display());
    fs::create_dir_all(checkout.join(".cmux")).unwrap();
    fs::write(checkout.join(".cmux/worktree.toml"), recipe).unwrap();
    // Nor does an fsmonitor the review branch's own configuration names, which
    // `git worktree remove` would start in the checkout to see it is clean.
    let fsmonitor_ran = root.join("fsmonitor-ran");
    let monitor = root.join("fsmonitor.sh");
    fs::write(&monitor, format!("#!/bin/sh\ntouch '{}'\nexit 1\n", fsmonitor_ran.display()))
        .unwrap();
    fs::set_permissions(&monitor, fs::Permissions::from_mode(0o755)).unwrap();
    let mut included = fs::read_to_string(&branchy).unwrap();
    included.push_str(&format!("[core]\n\tfsmonitor = {}\n", monitor.display()));
    fs::write(&branchy, included).unwrap();
    let other_root = PathBuf::from(other["root"].as_str().unwrap());
    // Another branch keeps the pull request's commits, so no `--discard`: the
    // removal checks the checkout is clean.
    git(&checkout, &["branch", "kept", &head]);
    // On its review branch the fsmonitor is live (a plain status starts it),
    // and the removal's checks and `git worktree remove` still never do.
    let attached = PathBuf::from(review_root.as_str());
    git(&attached, &["status", "--porcelain"]);
    assert!(fsmonitor_ran.exists(), "the branch's fsmonitor is not configured");
    fs::remove_file(&fsmonitor_ran).unwrap();
    let removed = git_cli(&server, &attached, &["worktree", "remove", "--idempotency-key", "rm-on"]);
    assert_success(&removed);
    assert!(!attached.exists(), "the review's worktree was not removed");
    assert!(!fsmonitor_ran.exists(), "an fsmonitor ran removing a review's checkout");
    // The other's HEAD detached since: it is still a review's checkout.
    git(&other_root, &["update-ref", "--no-deref", "HEAD", &head]);
    let remove = ["worktree", "remove", "--idempotency-key", "rm"];
    let removed = git_cli(&server, &other_root, &remove);
    assert_success(&removed);
    assert!(!other_root.exists(), "the review's worktree was not removed");
    assert!(!teardown_ran.exists(), "the project's teardown ran in a review's checkout");
    assert!(!fsmonitor_ran.exists(), "an fsmonitor ran in a review's checkout");

    // A comment outside a review worktree is refused.
    let plain = git_cli(&server, &checkout, &draft);
    assert!(!plain.status.success());
    assert!(String::from_utf8_lossy(&plain.stderr).contains("not_a_review"));
    drop(server);
    let _ = fs::remove_dir_all(root);
}

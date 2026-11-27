//! Table tests: each class, each wrapper form, compound commands, quoting,
//! and unknown commands falling to Machine.

use cmux_command_class::{Classifier, CommandClass, classify};

use CommandClass::{FileRead, FileWrite, GitHooks, GitLocal, Machine, Network};

fn check(rows: &[(&str, CommandClass, &str)]) {
    let mut failures = Vec::new();
    for &(command, class, reason) in rows {
        let got = classify(command);
        if got.class != class || got.reason != reason {
            failures.push(format!(
                "{command:?}: want {class:?} {reason:?}, got {:?} {:?}",
                got.class, got.reason
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn file_read() {
    check(&[
        ("cat README.md", FileRead, "cat"),
        ("grep -rn 'fn main' src", FileRead, "grep"),
        ("rg --files -g '*.rs'", FileRead, "rg"),
        ("sed -n '1,40p' src/lib.rs", FileRead, "sed"),
        ("sed 's/a/b/' file", FileRead, "sed"),
        ("head -50 Cargo.toml", FileRead, "head"),
        ("tail -n 20 log.txt", FileRead, "tail"),
        ("ls -la", FileRead, "ls"),
        ("find . -name '*.rs' -type f", FileRead, "find"),
        ("wc -l src/*.rs", FileRead, "wc"),
        ("jq '.dependencies' package.json", FileRead, "jq"),
        ("diff a.txt b.txt", FileRead, "diff"),
        ("stat Cargo.lock", FileRead, "stat"),
        ("tree -L 2", FileRead, "tree"),
        ("awk '{print $1}' file", FileRead, "awk"),
        ("awk -F: '$3 > 100 {print $1 \"|\" $2}' /etc/passwd", FileRead, "awk"),
        ("/usr/bin/grep x y", FileRead, "grep"),
        ("tee", FileRead, "tee"),
        ("echo hi > /dev/null", FileRead, "echo"),
        ("ls 2>/dev/null", FileRead, "ls"),
        ("cat file 2>&1", FileRead, "cat"),
        ("cat < input.txt", FileRead, "cat"),
        ("cat <<EOF\nhello $USER\nEOF", FileRead, "cat"),
        ("command -v cargo", FileRead, "command"),
        ("", FileRead, ""),
        ("# just a comment", FileRead, ""),
    ]);
}

#[test]
fn file_write() {
    check(&[
        ("sed -i 's/a/b/' file", FileWrite, "sed -i"),
        ("sed -i.bak -e 's/a/b/' file", FileWrite, "sed -i"),
        ("sed --in-place 's/a/b/' file", FileWrite, "sed -i"),
        ("mkdir -p out", FileWrite, "mkdir"),
        ("cp a b", FileWrite, "cp"),
        ("mv a b", FileWrite, "mv"),
        ("rm -rf target", FileWrite, "rm"),
        ("touch x", FileWrite, "touch"),
        ("tee out.log", FileWrite, "tee"),
        ("echo hi > out.txt", FileWrite, ">"),
        ("echo hi >> out.txt", FileWrite, ">>"),
        ("echo hi>out.txt", FileWrite, ">"),
        ("ls &> listing.txt", FileWrite, "&>"),
        ("chmod +x script.sh", FileWrite, "chmod"),
        ("cat > notes.md <<'EOF'\n# Notes\n$(not run)\nEOF", FileWrite, ">"),
        ("cat <<EOF > notes.md\nbody\nEOF", FileWrite, ">"),
        ("find . -name '*.orig' -delete", FileWrite, "find -delete"),
        ("sort -o sorted.txt input.txt", FileWrite, "sort -o"),
        ("sort -u names.txt", FileRead, "sort"),
        ("awk '{print > \"out.txt\"}' in", FileWrite, "awk >"),
        ("curl -sSLo out.tar.gz https://example.com/x", FileWrite, "curl -o"),
        ("curl -L -O https://example.com/x.tar.gz", FileWrite, "curl -o"),
        ("wget https://example.com/x.tar.gz", FileWrite, "wget"),
        ("git clone https://github.com/a/b", FileWrite, "git clone"),
        ("gh run download 123", FileWrite, "gh run download"),
        ("scp host:file.txt .", FileWrite, "scp"),
    ]);
}

#[test]
fn network() {
    check(&[
        ("gh pr view 123 --json body", Network, "gh"),
        ("gh api repos/o/r/pulls", Network, "gh"),
        ("curl -s https://example.com", Network, "curl"),
        ("curl -o /dev/null -w '%{http_code}' https://example.com", Network, "curl"),
        ("wget -qO- https://example.com", Network, "wget"),
        ("ssh host uptime", Network, "ssh"),
        ("scp file.txt host:/tmp/", Network, "scp"),
        ("git push origin HEAD", Network, "git push"),
        ("git fetch origin main", Network, "git fetch"),
        ("git ls-remote origin", Network, "git ls-remote"),
        ("git remote update", Network, "git remote"),
    ]);
}

#[test]
fn git_local() {
    check(&[
        ("git status --short", GitLocal, "git status"),
        ("git diff HEAD~1", GitLocal, "git diff"),
        ("git log --oneline -5", GitLocal, "git log"),
        ("git show HEAD:README.md", GitLocal, "git show"),
        ("git branch -a", GitLocal, "git branch"),
        ("git rev-parse HEAD", GitLocal, "git rev-parse"),
        ("git grep -n TODO", GitLocal, "git grep"),
        ("git blame src/lib.rs", GitLocal, "git blame"),
        ("git ls-files", GitLocal, "git ls-files"),
        ("git cat-file -p HEAD", GitLocal, "git cat-file"),
        ("git -C ../other --no-pager log", GitLocal, "git log"),
        ("git -c color.ui=always diff", GitLocal, "git diff"),
        ("git stash list", GitLocal, "git stash"),
        ("git worktree list", GitLocal, "git worktree"),
        ("git --version", GitLocal, "git"),
    ]);
}

#[test]
fn git_hooks() {
    check(&[
        ("git commit -m 'fix: thing'", GitHooks, "git commit"),
        ("git checkout -b feature", GitHooks, "git checkout"),
        ("git switch main", GitHooks, "git switch"),
        ("git merge origin/main", GitHooks, "git merge"),
        ("git rebase origin/main", GitHooks, "git rebase"),
        ("git am < patch.mbox", GitHooks, "git am"),
        ("git cherry-pick abc123", GitHooks, "git cherry-pick"),
        ("git worktree add ../wt branch", GitHooks, "git worktree"),
        ("git pull --rebase", GitHooks, "git pull"),
        ("git add -A", GitHooks, "git add"),
        ("git stash", GitHooks, "git stash"),
        ("gh pr checkout 123", GitHooks, "gh pr checkout"),
    ]);
}

#[test]
fn machine() {
    check(&[
        ("cargo test -p foo", Machine, "cargo"),
        ("npm install", Machine, "npm"),
        ("bun run dev", Machine, "bun"),
        ("make -j8", Machine, "make"),
        ("python3 scripts/gen.py", Machine, "python3"),
        ("./scripts/setup.sh", Machine, "./scripts/setup.sh"),
        ("node_modules/.bin/tsc --noEmit", Machine, "node_modules/.bin/tsc"),
        ("sleep 30", Machine, "sleep"),
        ("kill 1234", Machine, "kill"),
        ("docker ps", Machine, "docker"),
        ("npm run dev &", Machine, "npm"),
        ("cat file &", Machine, "&"),
        ("frobnicate --all", Machine, "frobnicate"),
        ("$EDITOR file", Machine, "$EDITOR"),
        ("source .env", Machine, "source"),
        ("bash script.sh", Machine, "bash"),
        ("sudo ls", Machine, "sudo"),
        ("git lfs pull", Machine, "git lfs"),
        ("git rebase -x 'cargo test' main", Machine, "git rebase"),
        ("gh my-extension", Machine, "gh my-extension"),
        ("awk -f prog.awk file", Machine, "awk -f"),
        ("awk '{system(\"rm \" $1)}' list", Machine, "awk system"),
        ("find . -name '*.sh' -exec bash {} \\;", Machine, "bash"),
        ("case $x in a) echo a;; esac", Machine, "case"),
    ]);
}

#[test]
fn wrappers() {
    check(&[
        ("cd src && cargo build", Machine, "cargo"),
        ("cd src && ls", FileRead, "cd"),
        ("RUST_LOG=debug cargo run", Machine, "cargo"),
        ("FOO=1 BAR=2 grep x y", FileRead, "grep"),
        ("FOO=1", FileRead, ""),
        ("timeout 60 cargo test", Machine, "cargo"),
        ("timeout -k 5 30s cat file", FileRead, "cat"),
        ("env", FileRead, "env"),
        ("env FOO=1 git status", GitLocal, "git status"),
        ("env -u HOME -i make", Machine, "make"),
        ("env -S 'git diff'", GitLocal, "git diff"),
        ("nice -n 10 rg foo", FileRead, "rg"),
        ("nice -5 cargo build", Machine, "cargo"),
        ("nohup ./server", Machine, "./server"),
        ("time git log", GitLocal, "git log"),
        ("command git status", GitLocal, "git status"),
        ("bash -c 'cat a | grep b'", FileRead, "cat"),
        ("sh -c \"mkdir -p out && cp a out/\"", FileWrite, "mkdir"),
        ("bash -lc 'cargo test'", Machine, "cargo"),
        ("bash -euo pipefail -c 'git status'", GitLocal, "git status"),
        ("bash -c 'bash -c \"git commit -m x\"'", GitHooks, "git commit"),
        ("timeout 10 bash -c 'curl -s https://x'", Network, "curl"),
        ("env FOO=1 timeout 5 nice -n 1 bash -c 'rm x'", FileWrite, "rm"),
        ("ls | xargs rm", FileWrite, "rm"),
        ("xargs -n 1 -I{} wc -l {}", FileRead, "wc"),
        ("xargs", FileRead, "xargs"),
        ("find . -name '*.rs' -exec grep -l foo {} +", FileRead, "find"),
        ("eval 'git push'", Network, "git push"),
    ]);
}

#[test]
fn compound_takes_most_demanding_part() {
    check(&[
        ("git status && git diff | head", GitLocal, "git status"),
        ("cat a | grep b | sort | uniq -c", FileRead, "cat"),
        ("gh pr view 1 --json body | jq .body", Network, "gh"),
        ("git diff | gh pr comment 1 --body-file -", GitLocal, "git diff"),
        ("git add -A && git commit -m x && git push", GitHooks, "git add"),
        ("rg foo; cargo test", Machine, "cargo"),
        ("test -f x || touch x", FileWrite, "touch"),
        ("(cd sub && make)", Machine, "make"),
        ("{ ls; cat a; } > out.txt", FileWrite, ">"),
        ("echo \"$(git rev-parse HEAD)\"", GitLocal, "git rev-parse"),
        ("echo `cargo --version`", Machine, "cargo"),
        ("diff <(sort a) <(sort b)", FileRead, "diff"),
        ("cat <<EOF\n$(cargo metadata)\nEOF", Machine, "cargo"),
        ("x=$(curl -s https://x) && echo $x", Network, "curl"),
        ("echo $((1 + 2))", FileRead, "echo"),
        ("echo ${HOME:-$(whoami)}", Machine, "whoami"),
        ("for f in *.rs; do wc -l \"$f\"; done", FileRead, "for"),
        ("for f in *.rs; do rustfmt \"$f\"; done", Machine, "rustfmt"),
        ("if [ -f x ]; then cat x; else echo no; fi", FileRead, "["),
        ("while read l; do echo $l; done < list.txt", FileRead, "read"),
        ("ls\ncargo build", Machine, "cargo"),
        ("cargo build 2>&1 | tail -20", Machine, "cargo"),
        ("cat a && npm test &", Machine, "npm"),
        ("sleep 1 & wait", Machine, "sleep"),
    ]);
}

#[test]
fn quoting() {
    check(&[
        ("echo 'cargo build && rm -rf /'", FileRead, "echo"),
        ("echo \"a > b\"", FileRead, "echo"),
        ("echo a\\>b", FileRead, "echo"),
        ("grep -n '$(not a sub)' file", FileRead, "grep"),
        ("echo $'it\\'s'", FileRead, "echo"),
        ("'git' status", GitLocal, "git status"),
        ("g\"i\"t log", GitLocal, "git log"),
        ("echo \"$(echo \")\")\"", FileRead, "echo"),
        ("echo \"unterminated", Machine, "unparsed"),
        ("echo 'unterminated", Machine, "unparsed"),
        ("echo $(cat x", Machine, "unparsed"),
        ("(ls", Machine, "unparsed"),
        ("ls )", Machine, "unparsed"),
        ("echo >", Machine, "unparsed"),
        ("rg 'a|b' && grep \"x;y\" f", FileRead, "rg"),
        ("echo a \\\n  b", FileRead, "echo"),
    ]);
}

#[test]
fn home_tools_are_network_only_when_configured() {
    assert_eq!(classify("glaeda-gh wait pr 12").class, Machine);
    let classifier = Classifier::with_home_tools(["glaeda-gh", "lane-gh"]);
    let got = classifier.classify("glaeda-gh wait pr 12 | tail -1");
    assert_eq!((got.class, got.reason.as_str()), (Network, "glaeda-gh"));
    // A configured name does not override a known class.
    let classifier = Classifier::with_home_tools(["cat"]);
    assert_eq!(classifier.classify("cat x").class, FileRead);
}

#[test]
fn nesting_has_a_bound() {
    let mut script = String::from("ls");
    for _ in 0..40 {
        script = format!("echo $({script})");
    }
    let got = classify(&script);
    assert_eq!((got.class, got.reason.as_str()), (Machine, "nesting"));
}

#[test]
fn order_is_documented_order() {
    let names: Vec<&str> = CommandClass::ALL.iter().map(|c| c.as_str()).collect();
    assert_eq!(names, ["file_read", "network", "git_local", "file_write", "git_hooks", "machine"]);
    assert!(CommandClass::ALL.windows(2).all(|w| w[0] < w[1]));
    assert!(!FileWrite.needs_machine());
    assert!(GitHooks.needs_machine() && Machine.needs_machine());
}

/// Review of #37800: each of these reached the home when it needs the
/// machine (or writes); the rows after each finding check its everyday
/// form still classifies low.
#[test]
fn substitutions_and_heredocs_fail_closed() {
    check(&[
        // F1: `$((` that is two subshells, not arithmetic.
        ("echo $((echo inner); (uname))", Machine, "uname"),
        ("echo $((i + 1))", FileRead, "echo"),
        ("echo $(( $(uname -r | wc -c) + 1 ))", Machine, "uname"),
        // F2: a heredoc inside `$(...)` whose body holds a `)`.
        ("echo \"$(cat <<EOF\n)\nEOF\nuname\n)\"", Machine, "uname"),
        ("gh pr create --body \"$(cat <<'EOF'\nFixes a) and b)\nEOF\n)\"", Network, "gh"),
        ("git commit -m \"$(cat <<'EOF'\nfix: x)\nEOF\n)\"", GitHooks, "git commit"),
        ("echo \"$(cat <<EOF\nno end\n)\"", Machine, "unparsed"),
        // F10: wrappers share the depth bound.
        ("nice nice nice cat input", FileRead, "cat"),
    ]);
    let chain = format!("{}cat input", "nice ".repeat(200));
    let got = classify(&chain);
    assert_eq!((got.class, got.reason.as_str()), (Machine, "nesting"));
}

#[test]
fn programs_that_run_or_write_fail_closed() {
    check(&[
        // F3: sed commands that run a process or write a file.
        ("sed -n '1e uname' input", Machine, "sed e"),
        ("sed 's/x/date/e' input", Machine, "sed s///e"),
        ("sed 's/x/y/w changed.txt' input", FileWrite, "sed s///w"),
        ("sed '/x/w changed.txt' input", FileWrite, "sed w"),
        ("sed -e 'p' -e '$W out.txt' input", FileWrite, "sed w"),
        ("sed -f prog.sed input", Machine, "sed -f"),
        ("sed 'Q nonsense' input", Machine, "sed program"),
        ("sed 's/hello/world/g; /we/d' input", FileRead, "sed"),
        ("sed -n '/^fn /,/^}/p' src/lib.rs", FileRead, "sed"),
        ("sed -E 's|a/(b)|\\1|' input", FileRead, "sed"),
        // F4: awk destinations that are expressions.
        ("awk 'BEGIN{cmd=\"uname\";print \"\"|cmd}'", Machine, "awk |"),
        ("awk 'BEGIN{f=\"out\";print \"x\">f}'", FileWrite, "awk >"),
        ("awk '{ \"date\" | getline d; print d }'", Machine, "awk |"),
        ("awk '{printf(\"%s\", $1) >> $2}' list", FileWrite, "awk >"),
        ("awk '{print $1 > \"/dev/stderr\"}' f", FileRead, "awk"),
        ("awk '/a|b/ {print}' f", FileRead, "awk"),
        ("awk '$1 > 3 || $2 < 1 {print ($1 > $2)}' f", FileRead, "awk"),
        ("awk '{print \"unterminated}' f", Machine, "awk program"),
        // F5: execution and output modes of name-based utilities.
        ("rg --pre ./filter needle input", Machine, "rg --pre"),
        ("rg --pre=./filter needle", Machine, "rg --pre"),
        ("rg --pre-glob '*.gz' needle", FileRead, "rg"),
        ("tar --checkpoint-action=exec=./hook -cf a.tar .", Machine, "tar program"),
        ("tar -xIzstd -f a.tar.zst", Machine, "tar program"),
        ("xxd input output", FileWrite, "xxd OUTPUT"),
        ("xxd -l 64 input", FileRead, "xxd"),
        ("uniq in.txt out.txt", FileWrite, "uniq OUTPUT"),
        ("bat --pager=./pager file", Machine, "bat --pager"),
        ("fd -e rs -x rustfmt", Machine, "rustfmt"),
        ("fd -e rs -x wc -l", FileRead, "fd"),
        ("tree -o tree.txt", FileWrite, "tree -o"),
        ("yq -i '.a = 1' f.yaml", FileWrite, "yq -i"),
        ("date -s '2026-01-01'", Machine, "date -s"),
        // F12: attached and clustered sort outputs.
        ("sort -osorted input", FileWrite, "sort -o"),
        ("sort -uo out input", FileWrite, "sort -o"),
        ("sort --output=out input", FileWrite, "sort -o"),
        ("sort --compress-program=./z input", Machine, "sort --compress-program"),
        ("sort -k2 -t, -n input", FileRead, "sort"),
    ]);
}

#[test]
fn git_and_gh_forms_fail_closed() {
    check(&[
        // F6: git settings and options that run a program.
        ("git -c core.fsmonitor=./monitor status", Machine, "git -c"),
        ("git -c core.pager=./pager log", Machine, "git -c"),
        ("git -c diff.external=./d diff", Machine, "git -c"),
        ("git -c core.fsmonitor=false status", GitLocal, "git status"),
        ("git -c color.ui=always status", GitLocal, "git status"),
        ("git --config-env=core.pager=PAGER log", Machine, "git --config-env"),
        ("git clone --upload-pack=./x ../repo", Machine, "git clone"),
        ("git clone -c core.hooksPath=h https://x/r", Machine, "git clone"),
        ("git fetch --upload-pack ./x origin", Machine, "git fetch"),
        ("git grep -Ovim TODO", Machine, "git grep"),
        ("git diff --ext-diff", Machine, "git diff"),
        ("git diff --output=change.patch", FileWrite, "git diff"),
        ("git push ../mirror main", GitHooks, "git push"),
        ("git push -u origin HEAD", Network, "git push"),
        ("git rebase -i HEAD~3", Machine, "git rebase"),
        ("git config user.name Leo", FileWrite, "git config"),
        ("git config --unset user.name", FileWrite, "git config"),
        ("git config --get user.name", GitLocal, "git config"),
        ("git config user.name", GitLocal, "git config"),
        ("git config --edit", Machine, "git config"),
        ("git branch feature", FileWrite, "git branch"),
        ("git branch -D old", FileWrite, "git branch"),
        ("git branch --contains abc123", GitLocal, "git branch"),
        ("git tag v1.0", FileWrite, "git tag"),
        ("git tag -l 'v*'", GitLocal, "git tag"),
        ("git remote add up https://x/r", FileWrite, "git remote"),
        ("git remote -v", GitLocal, "git remote"),
        // F8: gh's valued options before the action.
        ("gh pr --repo owner/repo checkout 123", GitHooks, "gh pr checkout"),
        ("gh -R owner/repo pr checkout 123", GitHooks, "gh pr checkout"),
        ("gh pr --repo owner/repo view 123", Network, "gh"),
        // F9: gh forms that create or change a local checkout.
        ("gh gist clone abc123", FileWrite, "gh gist clone"),
        ("gh repo create demo --public --clone", FileWrite, "gh repo create"),
        ("gh repo fork owner/repo --clone", FileWrite, "gh repo fork"),
        ("gh repo sync", GitHooks, "gh repo sync"),
        ("gh repo sync -b main", GitHooks, "gh repo sync"),
        ("gh repo sync owner/fork", Network, "gh"),
        ("gh pr merge 1 --squash --delete-branch", GitHooks, "gh pr merge"),
        ("gh pr merge 1 --squash", Network, "gh"),
        ("gh issue develop 7 --checkout", GitHooks, "gh issue develop"),
        ("gh repo create demo --public", Network, "gh"),
    ]);
}

#[test]
fn network_forms_fail_closed() {
    check(&[
        // F7: the machine's own loopback and local sockets.
        ("curl http://localhost:3000/health", Machine, "curl localhost"),
        ("curl -s 127.0.0.1:8080/metrics", Machine, "curl localhost"),
        ("curl http://[::1]:3000/", Machine, "curl localhost"),
        ("curl http://app.localhost/", Machine, "curl localhost"),
        ("curl --unix-socket /var/run/docker.sock http://x/v1/info", Machine, "curl --unix-socket"),
        ("curl -x localhost:8080 https://example.com", Machine, "curl localhost"),
        ("curl --resolve example.com:443:127.0.0.1 https://example.com", Machine, "curl localhost"),
        ("curl -H 'Host: localhost' https://example.com", Network, "curl"),
        ("wget -qO- localhost:3000", Machine, "wget localhost"),
        ("ssh localhost uptime", Machine, "ssh localhost"),
        ("ssh -L 3000:localhost:3000 host", Machine, "ssh -L"),
        ("ssh -o ProxyCommand=./proxy host", Machine, "ssh -o"),
        ("ssh -p 2222 host uptime", Network, "ssh"),
        ("scp file.txt user@localhost:/tmp/", Machine, "scp localhost"),
        ("rsync -a src/ localhost:/srv/", Machine, "rsync localhost"),
        ("rsync -e ./tunnel -a src/ host:/srv/", Machine, "rsync -e"),
        ("rsync -a -e 'ssh -p 22' src/ host:/srv/", FileWrite, "rsync"),
        // F11: `-` is a file to the shell and to tee.
        ("echo hello > -", FileWrite, ">"),
        ("tee -", FileWrite, "tee"),
        ("ls >&-", FileRead, "ls"),
        ("curl -o - https://example.com", Network, "curl"),
        // F13: curl's other file outputs.
        ("curl -D headers.txt https://example.com", FileWrite, "curl -o"),
        ("curl -c cookies.txt https://example.com", FileWrite, "curl -o"),
        ("curl --trace trace.log https://example.com", FileWrite, "curl -o"),
        ("curl --stderr err.log https://example.com", FileWrite, "curl -o"),
        ("curl -w '%output{out.txt}%{http_code}' https://example.com", FileWrite, "curl -o"),
        ("curl -D - https://example.com", Network, "curl"),
        ("curl -K curl.cfg", Machine, "curl -K"),
        ("wget -o wget.log -O - https://example.com", FileWrite, "wget -o"),
    ]);
}

/// Each cursor and index in the lexer and the sed, awk, git, env and shell
/// readers moves past its last word or char here, so a step is never taken
/// from the end of the input in a way that could wrap.
#[test]
fn ends_of_input_stay_in_bounds() {
    check(&[
        // The lexer: a trailing backslash, an empty `$(())`, a redirect with no target.
        ("echo \\", FileRead, "echo"),
        ("echo $(())", FileRead, "echo"),
        ("echo hi 2>", Machine, "unparsed"),
        // sed: `-e` with no value, a text command and a substitution that end in `\`.
        ("sed -n -e", FileRead, "sed"),
        ("sed 'a\\' input", FileRead, "sed"),
        ("sed 's/x\\' input", Machine, "sed program"),
        // awk: a flag with no value, a string and a regex that end in `\`.
        ("awk -F", FileRead, "awk"),
        ("awk '{print \"a\\\"}' input", Machine, "awk program"),
        ("awk '/a\\' input", Machine, "awk program"),
        // Option readers whose valued flag is the last word.
        ("git -C", GitLocal, "git"),
        ("git -c", Machine, "git -c"),
        ("env -u", FileRead, "env"),
        ("bash -o", Machine, "bash"),
        ("bash -c", Machine, "bash"),
        // The shortest host that ends in `.localhost`.
        ("curl http://a.localhost/", Machine, "curl localhost"),
    ]);
}

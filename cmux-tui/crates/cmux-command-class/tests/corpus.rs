//! A hand-written corpus of the command shapes coding agents run, with the
//! class each must get, plus the share of each class and the time per command.
//!
//! The commands are written for this test, not taken from transcripts; they
//! cover the common first words and wrapper forms. Run with `--nocapture` to
//! see the table.

use std::time::Instant;

use cmux_command_class::{Classifier, CommandClass};

use CommandClass::{FileRead, FileWrite, GitHooks, GitLocal, Machine, Network};

const CORPUS: &[(CommandClass, &str)] = &[
    // Reading the workspace.
    (FileRead, "cat src/main.rs"),
    (FileRead, "rg -n 'TODO|FIXME' src"),
    (FileRead, "grep -rn 'fn classify' crates/ --include='*.rs'"),
    (FileRead, "sed -n '120,180p' src/daemon.rs"),
    (FileRead, "head -40 README.md"),
    (FileRead, "tail -n 100 logs/app.log"),
    (FileRead, "ls -la crates/"),
    (FileRead, "find . -name '*.toml' -not -path './target/*'"),
    (FileRead, "wc -l src/*.rs | sort -n | tail -5"),
    (FileRead, "jq '.scripts' package.json"),
    (FileRead, "cd webviews && rg --files -g '*.tsx' | head -50"),
    (FileRead, "diff -u old.txt new.txt"),
    (FileRead, "awk -F, '{print $2}' data.csv | sort | uniq -c"),
    (FileRead, "tree -L 2 -I node_modules"),
    (FileRead, "stat -c %s build.log 2>/dev/null"),
    // Writing the workspace.
    (FileWrite, "mkdir -p crates/new/src"),
    (FileWrite, "sed -i 's/old_name/new_name/g' src/lib.rs"),
    (FileWrite, "cat > /tmp/body.md <<'EOF'\n## Summary\nText.\nEOF"),
    (FileWrite, "cp config.example.json config.json"),
    (FileWrite, "mv draft.md notes/final.md"),
    (FileWrite, "rm -f out/*.tmp"),
    (FileWrite, "echo 'export FOO=1' >> .envrc"),
    (FileWrite, "git diff > change.patch"),
    (FileWrite, "chmod +x scripts/run.sh"),
    (FileWrite, "printf '%s\\n' a b c | tee list.txt"),
    // Network and API.
    (Network, "gh pr view 123 --json title,body,headRefOid"),
    (Network, "gh pr create --title 'x' --body-file /tmp/body.md --draft"),
    (Network, "gh api repos/owner/repo/pulls/1/comments | jq '.[].body'"),
    (Network, "curl -sS https://api.example.com/v1/status"),
    (Network, "git push -u origin HEAD:lane/feature"),
    (Network, "git fetch origin feat-cmux-next"),
    (Network, "ssh build-host 'uptime'"),
    (Network, "glaeda-gh wait run 123 --timeout 30m"),
    (Network, "timeout 60 gh run view 456 --log-failed | tail -50"),
    // Reading the repository.
    (GitLocal, "git status --short"),
    (GitLocal, "git diff --stat origin/main...HEAD"),
    (GitLocal, "git log --oneline -20"),
    (GitLocal, "git show HEAD --stat"),
    (GitLocal, "git rev-parse --abbrev-ref HEAD"),
    (GitLocal, "git -C ../other blame -L 10,20 src/lib.rs"),
    (GitLocal, "git ls-files | wc -l"),
    (GitLocal, "git branch --show-current && git log -1 --format=%H"),
    // Hooks and tree rewrites.
    (GitHooks, "git add -A && git commit -m 'feat: thing'"),
    (GitHooks, "git checkout -b lane/feature origin/main"),
    (GitHooks, "git rebase origin/feat-cmux-next"),
    (GitHooks, "git worktree add ../wt lane/x"),
    (GitHooks, "git cherry-pick abc1234"),
    (GitHooks, "git pull --ff-only"),
    // The machine.
    (Machine, "cargo test -p cmux-command-class"),
    (Machine, "cd cmux-tui && cargo build --release 2>&1 | tail -20"),
    (Machine, "npm install"),
    (Machine, "bun run check"),
    (Machine, "python3 scripts/gen-settings-sources.py"),
    (Machine, "./scripts/reload.sh --tag dev"),
    (Machine, "make -j8 all"),
    (Machine, "RUST_LOG=debug timeout 300 cargo run -- serve"),
    (Machine, "npm run dev > dev.log 2>&1 &"),
    (Machine, "sleep 5 && curl -s localhost:3000/health"),
    (Machine, "kill -TERM 4242"),
    (Machine, "docker compose up -d"),
    (Machine, "bash -c 'cd web && bun test'"),
    (Machine, "pytest tests/test_api.py -k smoke"),
    (Machine, "uv run scripts/check.py"),
    (Machine, "node -e 'console.log(process.version)'"),
];

/// Classifications per corpus pass, so the per-command time is stable.
const PASSES: u32 = 200;

#[test]
fn corpus_classes_and_cost() {
    let classifier = Classifier::with_home_tools(["glaeda-gh"]);
    let mut failures = Vec::new();
    let mut counts = [0usize; CommandClass::ALL.len()];
    for &(want, command) in CORPUS {
        let got = classifier.classify(command);
        counts[got.class as usize] += 1;
        if got.class != want {
            failures
                .push(format!("{command:?}: want {want:?}, got {:?} ({})", got.class, got.reason));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));

    let started = Instant::now();
    for _ in 0..PASSES {
        for &(_, command) in CORPUS {
            std::hint::black_box(classifier.classify(std::hint::black_box(command)));
        }
    }
    let total = CORPUS.len() as u32 * PASSES;
    let per_command = started.elapsed() / total;

    println!("corpus: {} commands, all classified as expected", CORPUS.len());
    for class in CommandClass::ALL {
        let n = counts[class as usize];
        println!(
            "  {:<10} {n:>3}  {:>5.1}%",
            class.as_str(),
            100.0 * n as f64 / CORPUS.len() as f64
        );
    }
    let machine = counts[GitHooks as usize] + counts[Machine as usize];
    println!(
        "  needs the machine: {machine} of {} ({:.1}%)",
        CORPUS.len(),
        100.0 * machine as f64 / CORPUS.len() as f64
    );
    println!("  cost: {per_command:?} per command over {total} classifications");

    // A generous bound for an unoptimized test build: the classifier runs
    // once per tool call, so anything near a millisecond would be a bug.
    assert!(per_command.as_micros() < 500, "classify took {per_command:?} per command");
}

#[test]
fn corpus_covers_every_class() {
    for class in CommandClass::ALL {
        assert!(CORPUS.iter().any(|&(want, _)| want == class), "no corpus command for {class:?}");
    }
}

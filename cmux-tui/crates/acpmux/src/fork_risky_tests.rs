use super::*;

fn shell(cmd: &str) -> Value {
    json!({"toolCall": {"kind": "execute", "rawInput": {"command": cmd}}})
}

#[test]
fn the_steps_hard_to_undo_are_risky() {
    for cmd in [
        "git push --force origin main",
        "git push -f",
        "git push --force-with-lease origin HEAD:lane/x",
        "git push origin +main",
        "git push origin --delete old",
        "cd repo && git -C sub push -f",
        "git reset --hard origin/main",
        "git clean -fdx",
        "git checkout .",
        "git branch -D topic",
        "git stash drop",
        "git rebase -i main",
        "rm -rf .",
        "rm -rf ./*",
        "sudo rm -fr .git",
        "rm -rf /",
        "npx prisma migrate deploy",
        "bunx drizzle-kit push",
        "bin/rails db:migrate",
        "alembic upgrade head",
        "sqlx migrate run",
        "DATABASE_URL=x diesel migration run",
        "python manage.py migrate",
        "psql -c 'DROP TABLE users'",
        "terraform apply -auto-approve",
        "kubectl delete ns prod",
        "pnpm run db:push",
    ] {
        assert!(risky(&shell(cmd)).is_some(), "{cmd}");
    }
}

#[test]
fn everyday_steps_are_not() {
    for cmd in [
        "git push origin HEAD:lane/x",
        "git status",
        "git reset HEAD~1",
        "git checkout -b topic",
        "rm -rf target",
        "rm -rf node_modules dist",
        "rm file.txt",
        "cargo test",
        "bun test",
        "prisma generate",
        "terraform plan",
        "kubectl get pods",
    ] {
        assert_eq!(risky(&shell(cmd)), None, "{cmd}");
    }
}

#[test]
fn only_a_shell_call_is_judged() {
    let edit = json!({"toolCall": {"kind": "edit", "rawInput": {"command": "git push -f"}}});
    assert_eq!(risky(&edit), None);
    assert_eq!(risky(&json!({"toolCall": {"kind": "execute"}})), None);
    assert_eq!(risky(&json!({})), None);
    // An argv, `bash -lc SCRIPT`, is its script.
    let argv = json!({"toolCall": {"kind": "execute", "rawInput": {"command": ["bash", "-lc", "git reset --hard"]}}});
    assert!(risky(&argv).is_some());
}

#[test]
fn the_offer_needs_the_setting_a_cloud_machine_and_a_risky_step() {
    let step = shell("git push --force");
    let offer = offer(true, Some("vm_abc"), &step, "p1").unwrap();
    assert_eq!(offer["machine"], "vm_abc");
    assert_eq!(offer["clientKey"], "risky-p1");
    assert!(offer["reason"].as_str().unwrap().contains("git push"));
    assert_eq!(super::offer(false, Some("vm_abc"), &step, "p1"), None);
    assert_eq!(super::offer(true, None, &step, "p1"), None);
    assert_eq!(super::offer(true, Some("  "), &step, "p1"), None);
    assert_eq!(super::offer(true, Some("../v1/teams"), &step, "p1"), None);
    assert_eq!(super::offer(true, Some("vm_abc"), &shell("ls"), "p1"), None);
    let long = super::offer(true, Some("vm_abc"), &step, &"k".repeat(300)).unwrap();
    assert_eq!(long["clientKey"].as_str().unwrap().chars().count(), MAX_CLIENT_KEY);
}

struct Fake(Result<String, String>);

impl crate::placement::sub_fork::Machines for Fake {
    async fn fork(&self, machine: &str, client_key: &str) -> Result<String, String> {
        assert_eq!((machine, client_key), ("vm_abc", "risky-p1"));
        self.0.clone()
    }
    async fn delete(&self, _machine: &str) -> Result<(), String> {
        panic!("a checkpoint is never deleted here")
    }
}

#[tokio::test]
async fn fork_first_names_the_copy_and_the_time_or_the_failure() {
    let offer = offer(true, Some("vm_abc"), &shell("git reset --hard"), "p1").unwrap();
    let rec = fork_first(&Fake(Ok("vm_copy".into())), &offer, "p1").await.unwrap();
    assert_eq!(rec["fork"], "vm_copy");
    assert_eq!(rec["machine"], "vm_abc");
    assert_eq!(rec["permissionId"], "p1");
    assert!(rec["forkMs"].is_u64());
    let err = fork_first(&Fake(Err("quota".into())), &offer, "p1").await.unwrap_err();
    assert_eq!(err, "quota");
}

//! Gemini's `exit_plan_mode` carries its plan file's Markdown (`gemini_plan.rs`).

use super::*;

/// A Gemini home with one project (`slug`) whose root is `project`, and a plan in it.
struct Fixture {
    _dir: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
    plan: PathBuf,
}

const PLAN: &str = "# Add dark mode\n\n1. Read the theme tokens\n2. Add a `dark` palette\n3. Test the toggle\n";

fn fixture(session_folder: bool) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join(".gemini");
    let project = dir.path().join("work").join("app");
    std::fs::create_dir_all(&project).unwrap();
    let slug = home.join("tmp").join("app");
    std::fs::create_dir_all(&slug).unwrap();
    std::fs::write(slug.join(PROJECT_ROOT_FILE), project.to_str().unwrap()).unwrap();
    let plans = if session_folder { slug.join("4f1c-session").join("plans") } else { slug.join("plans") };
    std::fs::create_dir_all(&plans).unwrap();
    let plan = plans.join("dark-mode.md");
    std::fs::write(&plan, PLAN).unwrap();
    Fixture { _dir: dir, home, project, plan }
}

/// The tool call Gemini 0.66 sends for `exit_plan_mode` (acpClient.ts `runTool`).
fn gemini_call(path: &Path, status: &str) -> Value {
    json!({
        "sessionUpdate": "tool_call",
        "toolCallId": "exit_plan_mode-1",
        "status": status,
        "title": format!("Requesting plan approval for: {}", path.display()),
        "content": [],
        "locations": [],
        "kind": "other",
    })
}

#[test]
fn a_plan_approval_carries_its_plan_markdown() {
    let f = fixture(false);
    let mut tool = gemini_call(&f.plan, "pending");
    assert!(with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)));
    assert_eq!(tool["content"][0]["type"], "content");
    assert_eq!(tool["content"][0]["content"]["text"], PLAN.trim());
    assert_eq!(tool["rawInput"]["plan"], PLAN.trim());
    assert_eq!(tool["_meta"]["acpmux"]["plan"]["markdown"], PLAN.trim());
    assert_eq!(tool["_meta"]["acpmux"]["plan"]["path"], f.plan.to_str().unwrap());
}

#[test]
fn a_session_plans_folder_counts_too() {
    let f = fixture(true);
    let mut tool = gemini_call(&f.plan, "pending");
    assert!(with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)));
    assert_eq!(tool["_meta"]["acpmux"]["plan"]["markdown"], PLAN.trim());
}

#[test]
fn the_end_keeps_geminis_own_line_after_the_plan() {
    let f = fixture(false);
    let mut params = json!({"sessionId": "s", "update": gemini_call(&f.plan, "completed")});
    params["update"]["sessionUpdate"] = json!("tool_call_update");
    params["update"]["content"] = json!([{"type": "content", "content": {"type": "text", "text": "Plan approved"}}]);
    assert!(with_plan_update(&mut params, &f.project, std::slice::from_ref(&f.home)));
    let content = params["update"]["content"].as_array().unwrap();
    assert_eq!(content.len(), 2);
    assert_eq!(content[0]["content"]["text"], PLAN.trim());
    assert_eq!(content[1]["content"]["text"], "Plan approved");
}

#[test]
fn a_permission_request_tool_call_carries_it() {
    let f = fixture(false);
    let mut request = json!({"sessionId": "s", "toolCall": gemini_call(&f.plan, "pending"), "options": []});
    assert!(with_plan(&mut request["toolCall"], &f.project, std::slice::from_ref(&f.home)));
    assert_eq!(request["toolCall"]["_meta"]["acpmux"]["plan"]["markdown"], PLAN.trim());
}

#[test]
fn another_projects_plan_is_not_read() {
    let f = fixture(false);
    let other = f.project.parent().unwrap().join("other");
    std::fs::create_dir_all(&other).unwrap();
    let mut tool = gemini_call(&f.plan, "pending");
    let before = tool.clone();
    assert!(!with_plan(&mut tool, &other, std::slice::from_ref(&f.home)));
    assert_eq!(tool, before);
}

#[test]
fn a_path_outside_the_plans_folder_is_not_read() {
    let f = fixture(false);
    // A Markdown file in the project itself, and one in the project's temp folder but not plans.
    let readme = f.project.join("README.md");
    std::fs::write(&readme, "secret").unwrap();
    let beside = f.home.join("tmp").join("app").join("notes.md");
    std::fs::write(&beside, "secret").unwrap();
    for path in [readme, beside] {
        let mut tool = gemini_call(&path, "pending");
        assert!(!with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)), "{path:?}");
        assert_eq!(tool["content"], json!([]));
    }
}

#[test]
fn a_dotdot_or_symlink_out_of_the_plans_folder_is_not_read() {
    let f = fixture(false);
    let secret = f.project.join("secret.md");
    std::fs::write(&secret, "secret").unwrap();
    let plans = f.plan.parent().unwrap();
    let dotdot = plans.join("..").join("..").join("..").join("..").join("work/app/secret.md");
    let mut tool = gemini_call(&dotdot, "pending");
    assert!(!with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)));
    #[cfg(unix)]
    {
        let link = plans.join("link.md");
        std::os::unix::fs::symlink(&secret, &link).unwrap();
        let mut tool = gemini_call(&link, "pending");
        assert!(!with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)));
    }
}

#[test]
fn a_missing_file_a_folder_or_another_kind_leaves_the_call() {
    let f = fixture(false);
    let plans = f.plan.parent().unwrap();
    std::fs::create_dir_all(plans.join("dir.md")).unwrap();
    std::fs::write(plans.join("plan.txt"), "steps").unwrap();
    for path in [plans.join("gone.md"), plans.join("dir.md"), plans.join("plan.txt")] {
        let mut tool = gemini_call(&path, "pending");
        let before = tool.clone();
        assert!(!with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)), "{path:?}");
        assert_eq!(tool, before);
    }
}

#[test]
fn other_tool_calls_and_relative_paths_are_left_alone() {
    let f = fixture(false);
    let mut shell = json!({"sessionUpdate": "tool_call", "title": "ls -la", "kind": "execute"});
    assert!(!with_plan(&mut shell, &f.project, std::slice::from_ref(&f.home)));
    let mut relative = gemini_call(Path::new("plans/dark-mode.md"), "pending");
    assert!(!with_plan(&mut relative, &f.project, std::slice::from_ref(&f.home)));
    let mut message = json!({"update": {"sessionUpdate": "agent_message_chunk", "title": format!("{TITLE}{}", f.plan.display())}});
    assert!(!with_plan_update(&mut message, &f.project, std::slice::from_ref(&f.home)));
}

#[test]
fn a_call_that_has_its_plan_is_not_given_it_twice() {
    let f = fixture(false);
    let mut tool = gemini_call(&f.plan, "pending");
    assert!(with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)));
    assert!(!with_plan(&mut tool, &f.project, std::slice::from_ref(&f.home)));
    assert_eq!(tool["content"].as_array().unwrap().len(), 1);
}

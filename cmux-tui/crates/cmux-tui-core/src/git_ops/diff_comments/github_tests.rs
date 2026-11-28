use serde_json::{Value, json};

use super::super::{File, save, thread};
use super::*;

const NOW: &str = "2026-11-28T20:00:00.000Z";

fn top(id: u64, body: &str) -> Value {
    json!({
        "id": id,
        "html_url": format!("https://github.com/o/r/pull/7#discussion_r{id}"),
        "user": {"login": "octo"},
        "path": "src/a.rs",
        "line": 12,
        "start_line": 10,
        "side": "RIGHT",
        "diff_hunk": "@@ -1,3 +1,4 @@\n fn a() {\n+    let x = 1;",
        "body": body,
        "created_at": "2026-11-28T19:00:00Z",
    })
}

fn answer(id: u64, parent: u64, body: &str) -> Value {
    json!({
        "id": id,
        "in_reply_to_id": parent,
        "html_url": format!("https://github.com/o/r/pull/7#discussion_r{id}"),
        "user": {"login": "hubot"},
        "path": "src/a.rs",
        "line": 12,
        "body": body,
        "created_at": "2026-11-28T19:05:00Z",
    })
}

#[test]
fn github_comments_become_threads_with_their_answers() {
    let mut file = File::default();
    // An answer listed before its thread still lands in it.
    let comments = [answer(102, 101, "agreed"), top(101, "rename this"), top(103, "  ")];
    let imported = import(&mut file, &comments, NOW);
    assert_eq!(imported, Imported { threads: 1, replies: 1 });
    let thread = &file.comments[0];
    assert_eq!(thread["id"], "gh_101");
    assert_eq!(thread["filePath"], "src/a.rs");
    assert_eq!(thread["side"], "additions");
    assert_eq!((thread["startLine"].as_u64(), thread["endLine"].as_u64()), (Some(10), Some(12)));
    assert_eq!(thread["lineText"], "    let x = 1;");
    assert_eq!(thread["message"], "rename this");
    assert_eq!(thread["github"]["id"], 101);
    assert_eq!(thread["github"]["author"], "octo");
    let replies = thread["replies"].as_array().unwrap();
    assert_eq!(replies.len(), 1);
    assert_eq!(replies[0]["author"], "reviewer");
    assert_eq!(replies[0]["text"], "agreed");
    assert_eq!(replies[0]["github"]["id"], 102);
    // Never sent: the agent reads it as a new thread.
    assert!(thread::unread(thread).comment);
}

#[test]
fn a_reimport_adds_only_what_is_new() {
    let mut file = File::default();
    import(&mut file, &[top(101, "rename this")], NOW);
    let again = [top(101, "rename this"), answer(102, 101, "and the test")];
    assert_eq!(import(&mut file, &again, NOW), Imported { threads: 0, replies: 1 });
    assert_eq!(import(&mut file, &again, NOW), Imported::default());
    assert_eq!(file.comments.len(), 1);
    assert_eq!(file.comments[0]["replies"].as_array().unwrap().len(), 1);
}

#[test]
fn an_outdated_or_old_side_comment_keeps_its_place() {
    let mut file = File::default();
    let mut old = top(201, "why remove this");
    old["line"] = Value::Null;
    old["start_line"] = Value::Null;
    old["original_line"] = json!(4);
    old["side"] = json!("LEFT");
    import(&mut file, &[old], NOW);
    let thread = &file.comments[0];
    assert_eq!(thread["side"], "deletions");
    assert_eq!((thread["startLine"].as_u64(), thread["endLine"].as_u64()), (Some(4), Some(4)));
}

#[test]
fn a_page_save_keeps_where_the_thread_came_from() {
    let mut file = File::default();
    import(&mut file, &[top(101, "rename this")], NOW);
    let page = json!({"id": "gh_101", "filePath": "src/a.rs", "message": "rename this", "github": {"id": 9}});
    save(&mut file, "/r", "k1", page.as_object().unwrap().clone()).unwrap();
    assert_eq!(file.comments[0]["github"]["id"], 101);
}

#[test]
fn agent_answers_go_back_once() {
    let mut file = File::default();
    import(&mut file, &[top(101, "rename this"), answer(102, 101, "agreed")], NOW);
    file.comments.push(json!({"id": "dc_page", "message": "mine"}).as_object().unwrap().clone());
    let replies = file.comments[0]["replies"].as_array_mut().unwrap();
    replies.push(json!({"id": "dr_a", "author": "agent", "text": "renamed", "createdAt": NOW}));
    let ids = vec!["gh_101".to_owned(), "dc_page".to_owned()];
    let outgoing = agent_replies(&file, &ids);
    assert_eq!(
        outgoing,
        vec![Outgoing {
            github_id: 101,
            thread: "gh_101".into(),
            reply: "dr_a".into(),
            text: "renamed".into(),
        }]
    );
    // Not named: nothing goes.
    assert!(agent_replies(&file, &["dc_page".to_owned()]).is_empty());
    let posted = json!({"id": 150, "html_url": "https://github.com/o/r/pull/7#discussion_r150", "user": {"login": "me"}});
    assert!(mark_posted(&mut file, "gh_101", "dr_a", &posted));
    assert!(agent_replies(&file, &ids).is_empty());
    // GitHub listing the posted answer back is not a new reply.
    assert_eq!(import(&mut file, &[answer(150, 101, "renamed")], NOW), Imported::default());
}

#[test]
fn gh_jq_lines_parse_one_object_each() {
    let text = "{\"id\":1}\n\nnot json\n[1]\n{\"id\":2}\n";
    assert_eq!(comment_lines(text), vec![json!({"id": 1}), json!({"id": 2})]);
}

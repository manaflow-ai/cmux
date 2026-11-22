use super::*;

fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-trust-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// A no-folder start on the owner's own Cloud VM, and a prewarm of the same tab, both run in the
/// chat's own `~/chats/<id>`: the prewarm makes it, and the start that follows gets the same path,
/// so acpmux's pooled agent (keyed by its folder) is the start's.
#[test]
fn a_no_folder_owner_start_and_its_prewarm_share_the_chats_own_folder() {
    let home = temp("chat-cwd");
    let warmed = owner_cloud_cwd_in(Some(&home), true, None, false, 7).expect("the chat's folder");
    assert_eq!(warmed, home.join("chats/7").to_string_lossy());
    assert!(super::super::agent_session_folders::private_owned_dir(&home.join("chats/7")));
    let started = owner_cloud_cwd_in(Some(&home), true, None, false, 7);
    assert_eq!(started.as_deref(), Some(warmed.as_str()), "the start reuses the warmed folder");
    // An older caller's unconfirmed home folder is the same no-folder choice.
    let home_text = home.to_string_lossy().into_owned();
    assert_eq!(owner_cloud_cwd_in(Some(&home), true, Some(&home_text), false, 7), started);
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn a_picked_folder_a_confirmed_home_or_another_caller_keeps_its_own_folder() {
    let home = temp("chat-cwd-kept");
    let work = home.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let home_text = home.to_string_lossy().into_owned();
    let work_text = work.to_string_lossy().into_owned();
    assert_eq!(owner_cloud_cwd_in(Some(&home), true, Some(&work_text), false, 8), None);
    assert_eq!(owner_cloud_cwd_in(Some(&home), true, Some(&home_text), true, 8), None);
    assert_eq!(owner_cloud_cwd_in(Some(&home), false, None, false, 8), None);
    assert_eq!(owner_cloud_cwd_in(None, true, None, false, 8), None);
    assert!(!home.join("chats").exists(), "nothing is made for them");
    let _ = std::fs::remove_dir_all(home);
}

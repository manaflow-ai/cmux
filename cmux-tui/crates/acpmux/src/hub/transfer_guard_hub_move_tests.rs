use super::*;

#[tokio::test]
async fn a_hub_move_takes_home_only_on_a_vm_host_and_nothing_outside_it() {
    let home = dirs::home_dir().unwrap();
    let home = spelled(&home).await.unwrap_or(home);
    // No webRoots and not a VM host: no root at all.
    assert!(Guard::hub_move(&[], false).await.is_err());
    // A VM host with no webRoots: the home folder, as the person's own (owner) chat.
    let g = Guard::hub_move(&[], true).await.unwrap();
    assert_eq!(g.roots, [home.clone()]);
    assert!(g.owner && g.control == Control::Peer);
    assert_eq!(g.folder(&home.to_string_lossy()).await, Some(home.clone()));
    // Outside home stays refused, even with home as a root.
    let tmp = std::env::temp_dir();
    if !spelled(&tmp).await.is_some_and(|t| t.starts_with(&home)) {
        assert_eq!(g.folder(&tmp.to_string_lossy()).await, None);
    }
    assert_eq!(g.folder("/").await, None);
    assert_eq!(g.folder("relative").await, None);
    // A hidden folder of home (a chat under `~/.local/state`) is inside the home root.
    let hidden = home.join(format!(".acpmux-hub-move-test-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(hidden.join("state")).unwrap();
    let inner = hidden.join("state");
    assert!(g.folder(&inner.to_string_lossy()).await.is_some());
    // Not a VM host: the same folder is refused, as `parse` refuses home's hidden folders.
    let plain = home.join(format!("acpmux-hub-move-test-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&plain).unwrap();
    let roots = [plain.to_string_lossy().into_owned()];
    let g = Guard::hub_move(&roots, false).await.unwrap();
    assert_eq!(g.folder(&inner.to_string_lossy()).await, None);
    assert_eq!(g.folder(&home.to_string_lossy()).await, None);
    assert!(g.owner);
    // webRoots and a VM host: both, home once.
    let g = Guard::hub_move(&roots, true).await.unwrap();
    assert_eq!(g.roots.len(), 2);
    // A bad webRoot still refuses, VM host or not.
    assert!(Guard::hub_move(&["/".into()], true).await.is_err());
    let _ = std::fs::remove_dir_all(&hidden);
    let _ = std::fs::remove_dir_all(&plain);
}

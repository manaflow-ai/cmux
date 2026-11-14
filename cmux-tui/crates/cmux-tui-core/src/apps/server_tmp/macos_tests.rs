#[test]
fn this_macs_temp_dir_gives_a_socket_folder_that_fits() {
    let root =
        super::darwin_user_temp().expect("this Mac's confstr temp dir has the system's shape");
    let dir = super::server_tmp_dir(std::path::Path::new("/tmp/state"), "cmux.linked")
        .expect("this Mac's app socket folder fits");
    assert!(dir.starts_with(&root), "{}", dir.display());
    assert!(dir.as_os_str().len() <= super::MAX_SOCKET_DIR, "{}", dir.display());
    println!("socket folder {} ({} bytes)", dir.display(), dir.as_os_str().len());
}

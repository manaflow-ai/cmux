use super::*;

fn scratch(tag: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-callreg-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    dir.join(FILE)
}

fn token(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

mod caller_identity {
    use super::*;

    /// What one run accepted, the next run (a new registry from the same file) accepts, and
    /// the file holds no token, only owner-only digests.
    #[test]
    fn a_token_counts_in_the_next_run_and_the_file_holds_no_token() {
        use std::os::unix::fs::PermissionsExt;
        let path = scratch("next");
        let first = CallerRegistry::load(Some(path.clone()));
        first.host_started("s1", &token(1), "inc-1");
        assert!(first.proves("s1", &token(1)));
        let next = CallerRegistry::load(Some(path.clone()));
        assert!(next.proves("s1", &token(1)), "the next run lost the token");
        assert!(next.knows_host("s1", "inc-1"));
        assert!(!next.knows_host("s1", "inc-2"), "another host of the session");
        assert!(!next.proves("s2", &token(1)), "one session's token proved another");
        assert!(!next.proves("s1", &token(2)), "a token it never gave proved the session");
        assert!(!next.proves("s1", "not hex"), "a malformed token");
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains(&token(1)), "the file holds the token itself");
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the file is not owner-only");
    }

    /// A new host of the session starts with this run's token alone; another process's copy
    /// of this run's token counts beside it.
    #[test]
    fn a_new_host_replaces_earlier_tokens_and_an_issued_one_is_added() {
        let registry = CallerRegistry::load(Some(scratch("replace")));
        registry.host_started("s1", &token(1), "inc-1");
        registry.issued("s1", &token(2));
        assert!(registry.proves("s1", &token(1)) && registry.proves("s1", &token(2)));
        registry.host_started("s1", &token(3), "inc-2");
        assert!(!registry.proves("s1", &token(1)), "the replaced host's token still counts");
        assert!(!registry.proves("s1", &token(2)));
        assert!(registry.proves("s1", &token(3)));
        for n in 4..12 {
            registry.issued("s1", &token(n));
        }
        assert!(registry.proves("s1", &token(11)));
        assert!(!registry.proves("s1", &token(4)), "more than {MAX_ISSUED} issued kept");
        assert!(registry.proves("s1", &token(3)), "issued tokens pushed out the host's own");
        assert!(registry.knows_host("s1", "inc-2"));
        registry.forget("s1");
        assert!(!registry.proves("s1", &token(3)), "a forgotten session's token still counts");
        assert!(!registry.knows_host("s1", "inc-2"));
    }

    /// A file another user could have written proves nothing: it is not read.
    #[test]
    fn a_file_others_may_write_is_not_read() {
        use std::os::unix::fs::PermissionsExt;
        let path = scratch("open");
        CallerRegistry::load(Some(path.clone())).host_started("s1", &token(1), "inc-1");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
        assert!(!CallerRegistry::load(Some(path)).proves("s1", &token(1)));
        let memory = CallerRegistry::load(None);
        memory.host_started("s1", &token(1), "inc-1");
        assert!(memory.proves("s1", &token(1)), "a daemon with no config file");
    }
}

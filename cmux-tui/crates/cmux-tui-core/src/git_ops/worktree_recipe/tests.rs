use super::*;

#[test]
fn reads_the_repository_files() {
    let mut bytes = [0_u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    let root = std::env::temp_dir().join(format!("cmux-recipe-{hex}"));
    std::fs::create_dir_all(root.join(PROJECT_FILE).parent().unwrap()).unwrap();
    std::fs::write(root.join(".worktreeinclude"), ".env\n").unwrap();
    std::fs::write(
            root.join(PROJECT_FILE),
            "setup = \"npm ci\"\nrun = \"npm run dev\"\nteardown = \"make down\"\ninclude = [\"config/local.json\"]\nports = 3\n",
        )
        .unwrap();
    let mut resolved = Resolved {
        recipe: Recipe::default(),
        repository: Recipe::default(),
        saved: None,
        files: Vec::new(),
        problems: Vec::new(),
    };
    read_repository(&root, &mut resolved);
    assert_eq!(resolved.repository.setup.as_deref(), Some("npm ci"));
    assert_eq!(resolved.repository.teardown.as_deref(), Some("make down"));
    assert_eq!(resolved.repository.include, [".env", "config/local.json"]);
    assert_eq!(resolved.files, [".worktreeinclude", PROJECT_FILE]);
    assert_eq!(resolved.repository.run.as_deref(), Some("npm run dev"));
    assert_eq!(resolved.problems, [format!("{PROJECT_FILE}: ports is not read")]);
    std::fs::remove_dir_all(root).unwrap();
}

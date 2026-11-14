//! [`Repository::open`] and [`Checkout::open`] open a folder as a part of its
//! own work tree only: the folder is in the work tree that git gives for it,
//! and that work tree and its git folder name each other. Each test builds
//! one layout with the real git and opens it.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, Once, PoisonError};

use cmux_git::head::Checkout;
use cmux_git::run::GitFailure;
use cmux_git::{OpenError, Repository};

/// How the problem text of each refusal of the open starts.
const REFUSED: &str = "this folder is not opened: ";

/// A fresh folder for one test, removed when dropped.
struct Scratch(PathBuf);

/// How many scratch folders are there now. The test home is there while one is.
static LIVE: Mutex<usize> = Mutex::new(0);

/// The folder that HOME names for the whole test process.
fn test_home() -> PathBuf {
    std::env::temp_dir().join(format!("cmux-git-own-tree-home-{}", std::process::id()))
}

impl Scratch {
    fn new(name: &str) -> Self {
        isolate_home();
        {
            let mut live = LIVE.lock().unwrap_or_else(PoisonError::into_inner);
            std::fs::create_dir_all(test_home()).expect("create the test home");
            *live = live.saturating_add(1);
        }
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let unique = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-git-own-tree-{}-{name}-{unique}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create scratch folder");
        Self(std::fs::canonicalize(&path).expect("canonical scratch folder"))
    }

    /// A new folder `name` in the scratch folder.
    fn folder(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir_all(&path).expect("create a folder");
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
        let mut live = LIVE.lock().unwrap_or_else(PoisonError::into_inner);
        *live = live.saturating_sub(1);
    }
}

/// Points HOME and XDG_CONFIG_HOME at an empty folder for the whole test
/// process, so the developer's own git config never changes what the opens
/// under test do.
fn isolate_home() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let home = test_home();
        // SAFETY: every test calls this before it spawns anything or reads
        // the environment, and `Once` blocks them until it has run.
        unsafe {
            std::env::set_var("HOME", &home);
            std::env::set_var("XDG_CONFIG_HOME", home.join(".config"));
        }
    });
}

/// Runs setup git in `directory`, isolated from the machine's git config,
/// and returns its trimmed output.
fn git(directory: &Path, arguments: &[&str]) -> String {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args(arguments)
        .current_dir(directory)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "cmux tests")
        .env("GIT_AUTHOR_EMAIL", "cmux@example.invalid")
        .env("GIT_COMMITTER_NAME", "cmux tests")
        .env("GIT_COMMITTER_EMAIL", "cmux@example.invalid")
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {arguments:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn text(path: &Path) -> &str {
    path.to_str().expect("a UTF-8 test path")
}

/// A repository at `path` with one commit of one file.
fn new_repository(path: &Path) {
    std::fs::create_dir_all(path).expect("create repository folder");
    git(path, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(path.join("file.txt"), "one\n").expect("write a file");
    git(path, &["add", "file.txt"]);
    git(path, &["commit", "--quiet", "-m", "one"]);
}

/// A linked work tree `name` of the repository at `main`, beside it.
fn linked_work_tree(main: &Path, name: &str) -> PathBuf {
    let path = main.parent().expect("a parent folder").join(name);
    git(main, &["worktree", "add", "--quiet", "-b", name, text(&path)]);
    path
}

/// The problem text of the open of `directory`: each of the two opens must
/// refuse it, in the same words.
fn refusal(directory: &Path) -> String {
    let checkout = match Checkout::open(directory) {
        Err(OpenError::Git(GitFailure::Exit(problem))) => problem,
        other => panic!("the checkout's open of {} gave {other:?}", directory.display()),
    };
    let repository = match Repository::open(directory) {
        Err(OpenError::Git(GitFailure::Exit(problem))) => problem,
        other => panic!("the repository's open of {} gave {other:?}", directory.display()),
    };
    assert_eq!(checkout, repository, "the two opens refuse in the same words");
    assert!(checkout.starts_with(REFUSED), "the problem text is the open's own: {checkout}");
    checkout
}

/// The top folder that each of the two opens gives for `directory`.
fn top_folder(directory: &Path) -> PathBuf {
    let checkout = Checkout::open(directory).expect("the checkout opens");
    let repository = Repository::open(directory).expect("the repository opens");
    assert_eq!(checkout.root(), repository.root.as_path());
    repository.root
}

#[test]
fn own_tree_tests_leave_no_folder_when_they_end() {
    let scratch = Scratch::new("left");
    let folder = scratch.0.clone();
    std::fs::write(folder.join("file"), "one\n").expect("write a file");
    assert!(test_home().is_dir(), "the test home is there while a test's folder is");

    drop(scratch);

    assert!(!folder.exists(), "the folder {} stays", folder.display());
    // The count is read and the test home is looked at in one lock, as the guard does.
    let live = LIVE.lock().unwrap_or_else(PoisonError::into_inner);
    assert_eq!(test_home().exists(), *live > 0, "the test home is there only while a folder is");
}

#[test]
fn own_tree_open_refuses_a_folder_that_is_not_in_the_work_tree_that_git_gives_for_it() {
    let scratch = Scratch::new("outside");
    let (folder, other) = (scratch.0.join("folder"), scratch.folder("other"));
    new_repository(&folder);
    git(&folder, &["config", "core.worktree", text(&other)]);

    let problem = refusal(&folder);

    assert!(problem.contains("is not in the work tree that git gives for it"), "{problem}");
}

#[test]
fn own_tree_open_refuses_a_work_tree_that_its_git_folder_records_at_another_place() {
    let scratch = Scratch::new("record");
    let main = scratch.0.join("main");
    new_repository(&main);
    let linked = linked_work_tree(&main, "linked");
    let second = scratch.folder("second");
    std::fs::copy(linked.join(".git"), second.join(".git")).expect("copy the git file");

    let problem = refusal(&second);

    assert!(problem.contains("do not name each other"), "{problem}");
    assert_eq!(top_folder(&linked), linked, "the recorded work tree still opens");
}

#[test]
fn own_tree_open_refuses_a_work_tree_whose_top_folder_has_another_git_folder_or_none() {
    let scratch = Scratch::new("above");
    // The folder above has no git folder of its own.
    let inner = scratch.folder("plain/inner");
    let store = scratch.0.join("store");
    git(&inner, &["init", "--quiet", "--initial-branch=main", "--separate-git-dir", text(&store)]);
    git(&inner, &["config", "core.worktree", text(&scratch.0.join("plain"))]);
    // The folder above is a repository with another git folder.
    let outer = scratch.0.join("outer");
    new_repository(&outer);
    let nested = scratch.folder("outer/nested");
    let second_store = scratch.0.join("second-store");
    let arguments =
        ["init", "--quiet", "--initial-branch=main", "--separate-git-dir", text(&second_store)];
    git(&nested, &arguments);
    git(&nested, &["config", "core.worktree", text(&outer)]);

    let problem = refusal(&inner);
    assert!(problem.contains("do not name each other"), "{problem}");
    let problem = refusal(&nested);
    assert!(problem.contains("do not name each other"), "{problem}");
    assert_eq!(top_folder(&outer), outer, "the repository above still opens");
}

/// Why the open refuses a `.git` file that names a git folder with the name `.git` and no
/// record of a work tree.
const NAME_IS_GIT: &str = ": the `.git` file names a git folder whose own name is `.git`";

/// Whether a problem text names no command to run, and says to ask the person. A problem
/// text says what is refused and why.
fn names_no_command(problem: &str) -> bool {
    let command = ["git config", "git worktree", "run `", "$("];
    !command.iter().any(|part| problem.contains(part)) && problem.contains("ask the person")
}

/// git makes this layout with `git init --separate-git-dir`: the `.git` file names the git
/// folder, and the git folder names no work tree.
#[test]
fn own_tree_open_opens_a_work_tree_whose_git_folder_is_apart_and_names_no_work_tree() {
    let scratch = Scratch::new("separate");
    let (folder, store) = (scratch.folder("folder"), scratch.0.join("store"));
    new_repository_with_its_git_folder_at(&folder, &store);
    let below = scratch.folder("folder/below");

    assert_eq!(top_folder(&folder), folder);
    assert_eq!(top_folder(&below), folder, "a folder below the top folder");
}

#[test]
fn own_tree_open_refuses_a_git_file_that_names_the_git_folder_in_another_work_tree() {
    let scratch = Scratch::new("file-other");
    let other = scratch.0.join("other");
    new_repository(&other);
    let folder = scratch.folder("folder");
    let git_file = format!("gitdir: {}\n", text(&other.join(".git")));
    std::fs::write(folder.join(".git"), git_file).expect("write a file");

    let problem = refusal(&folder);

    assert!(problem.contains("do not name each other"), "{problem}");
    assert!(problem.contains(NAME_IS_GIT), "{problem}");
    assert!(names_no_command(&problem), "{problem}");
    assert_eq!(top_folder(&other), other, "the other work tree still opens");
}

/// The open reads the name of the git folder only. It does not know if a work tree is around
/// a git folder with the name `.git`, so the problem text says the name and no more.
#[test]
fn own_tree_open_says_no_more_than_the_name_of_a_git_folder_apart_with_the_name_dot_git() {
    let scratch = Scratch::new("file-name");
    let (folder, apart) = (scratch.folder("folder"), scratch.folder("apart"));
    new_repository_with_its_git_folder_at(&folder, &apart.join(".git"));

    let problem = refusal(&folder);

    assert!(problem.contains("do not name each other"), "{problem}");
    assert!(problem.contains(NAME_IS_GIT), "{problem}");
    assert!(!problem.contains("another work tree"), "{problem}");
    assert!(names_no_command(&problem), "{problem}");
}

#[test]
fn own_tree_open_says_what_is_wrong_and_no_command_for_a_linked_work_tree_moved_with_no_git() {
    let scratch = Scratch::new("moved");
    let main = scratch.0.join("main");
    new_repository(&main);
    let linked = linked_work_tree(&main, "linked");
    let moved = scratch.0.join("moved");
    std::fs::rename(&linked, &moved).expect("move the work tree");

    let problem = refusal(&moved);

    assert!(problem.contains("do not name each other"), "{problem}");
    assert!(problem.contains(": the git folder has the record of a work tree at"), "{problem}");
    assert!(names_no_command(&problem), "{problem}");
    git(&moved, &["worktree", "repair"]);
    assert_eq!(top_folder(&moved), moved, "the work tree opens after git repaired its record");
}

/// git prints two folders on a line each, and a name can have a line break. An answer that
/// two pairs of folders that are there can have made is the answer of no pair.
#[test]
fn own_tree_two_folders_of_an_answer_that_two_pairs_can_have_made_are_not_taken() {
    let scratch = Scratch::new("pairs");
    let top = text(&scratch.0).to_string();
    let (first, second, third) = (format!("{top}/a"), format!("{top}/b"), format!("{top}/c"));
    let answer = format!("{first}\n{second}\n{third}\n");
    // One pair: `a`, then a folder whose name has the line break.
    std::fs::create_dir_all(&first).expect("create a folder");
    std::fs::create_dir_all(format!("{second}\n{third}")).expect("create a folder");

    let pair = cmux_git::two_folders(answer.as_bytes());

    let with_break = PathBuf::from(format!("{second}\n{third}"));
    assert_eq!(pair, Some((PathBuf::from(&first), with_break)), "one pair is there");
    // The other pair: a folder whose name has the line break, then `c`.
    std::fs::create_dir_all(format!("{first}\n{second}")).expect("create a folder");
    std::fs::create_dir_all(&third).expect("create a folder");
    assert_eq!(cmux_git::two_folders(answer.as_bytes()), None, "two pairs are there");
}

#[test]
fn own_tree_open_keeps_the_kind_of_an_error_of_git_that_is_not_its_no_repository_error() {
    let scratch = Scratch::new("kind");
    // git's error for this file names the file's path.
    let folder = scratch.folder("not a git repository/folder");
    std::fs::write(folder.join(".git"), "no git file\n").expect("write a file");
    let plain = scratch.folder("plain");

    match Repository::open(&folder) {
        Err(OpenError::Git(GitFailure::Exit(problem))) => {
            assert!(!problem.starts_with(REFUSED), "the error is git's own: {problem}");
        }
        other => panic!("the open gave {other:?}"),
    }
    assert!(matches!(Checkout::open(&folder), Err(OpenError::Git(GitFailure::Exit(_)))));
    assert!(matches!(Repository::open(&plain), Err(OpenError::NotARepository)));
    assert!(matches!(Checkout::open(&plain), Err(OpenError::NotARepository)));
}

#[test]
fn own_tree_main_checkout_is_right_for_a_main_checkout_whose_name_has_a_line_break() {
    let scratch = Scratch::new("line-break");
    let main = scratch.0.join("main\ncheckout");
    new_repository(&main);
    let linked = linked_work_tree(&main, "linked");

    let repository = Repository::open(&linked).expect("the linked work tree opens");

    assert_eq!(repository.main_checkout(), Some(main.clone()));
    let own = Repository::open(&main).expect("the main checkout opens");
    assert_eq!(own.main_checkout(), None, "a main checkout has no other main checkout");
}

#[test]
fn own_tree_open_opens_each_layout_that_git_makes_for_a_work_tree() {
    let scratch = Scratch::new("layouts");
    let main = scratch.0.join("main");
    new_repository(&main);
    let below = scratch.folder("main/below/deep");
    assert_eq!(top_folder(&main), main);
    assert_eq!(top_folder(&below), main, "a folder below the top folder");

    let link = scratch.0.join("link");
    std::os::unix::fs::symlink(&below, &link).expect("make a link");
    assert_eq!(top_folder(&link), main, "a link to a folder below the top folder");

    let linked = linked_work_tree(&main, "linked");
    assert_eq!(top_folder(&linked), linked, "a linked work tree");
    let moved = scratch.0.join("moved");
    git(&main, &["worktree", "move", text(&linked), text(&moved)]);
    assert_eq!(top_folder(&moved), moved, "a linked work tree that git moved");

    let bare = scratch.0.join("bare.git");
    git(&scratch.0, &["clone", "--quiet", "--bare", text(&main), text(&bare)]);
    let of_bare = scratch.0.join("of-bare");
    git(&bare, &["worktree", "add", "--quiet", "-b", "of-bare", text(&of_bare)]);
    assert_eq!(top_folder(&of_bare), of_bare, "a linked work tree of a bare repository");

    let parent = scratch.0.join("parent");
    new_repository(&parent);
    let arguments =
        ["-c", "protocol.file.allow=always", "submodule", "--quiet", "add", text(&main), "module"];
    git(&parent, &arguments);
    let module = parent.join("module");
    assert_eq!(top_folder(&module), module, "a submodule");
    assert_eq!(top_folder(&parent), parent, "the repository of a submodule");
}

/// Replaces the `.git` file that git made in `folder` by a link to `git_folder`.
fn link_as_git_entry(folder: &Path, git_folder: &Path) {
    let entry = folder.join(".git");
    let _ = std::fs::remove_file(&entry);
    std::os::unix::fs::symlink(git_folder, entry).expect("make a link");
}

/// A new repository in `folder` whose git folder is `store`, apart from the work tree.
fn new_repository_with_its_git_folder_at(folder: &Path, store: &Path) {
    let arguments = ["init", "--quiet", "--initial-branch=main", "--separate-git-dir", text(store)];
    git(folder, &arguments);
}

/// A new repository whose git folder is `store`, apart from its work tree, and a new folder
/// `name` in the scratch folder whose `.git` entry is a link to that git folder.
fn folder_with_a_link_to_a_git_folder(scratch: &Scratch, name: &str, store: &Path) -> PathBuf {
    let first = scratch.folder(&format!("{name}-first"));
    new_repository_with_its_git_folder_at(&first, store);
    let folder = scratch.folder(name);
    link_as_git_entry(&folder, store);
    folder
}

#[test]
fn own_tree_open_refuses_a_git_folder_that_uses_the_common_folder_of_another_repository() {
    let scratch = Scratch::new("common");
    let other = scratch.0.join("other");
    new_repository(&other);
    let common = format!("{}\n", text(&other.join(".git")));
    // A git folder in the work tree.
    let folder = scratch.folder("folder");
    let inside = scratch.folder("folder/.git");
    std::fs::write(inside.join("HEAD"), "ref: refs/heads/main\n").expect("write a file");
    std::fs::write(inside.join("commondir"), &common).expect("write a file");
    // A git folder apart from the work tree, and each of the two names the other.
    let (second, apart) = (scratch.folder("second"), scratch.folder("apart"));
    std::fs::write(apart.join("HEAD"), "ref: refs/heads/main\n").expect("write a file");
    std::fs::write(apart.join("commondir"), &common).expect("write a file");
    let record = format!("{}\n", text(&second.join(".git")));
    std::fs::write(apart.join("gitdir"), record).expect("write a file");
    let git_file = format!("gitdir: {}\n", text(&apart));
    std::fs::write(second.join(".git"), git_file).expect("write a file");

    let problem = refusal(&folder);
    assert!(problem.contains("common folder"), "{problem}");
    let problem = refusal(&second);
    assert!(problem.contains("common folder"), "{problem}");

    assert_eq!(top_folder(&other), other, "the other repository still opens");
    let linked = linked_work_tree(&other, "linked");
    assert_eq!(top_folder(&linked), linked, "a linked work tree uses its own repository's");
}

#[test]
fn own_tree_open_opens_a_work_tree_whose_git_entry_is_a_link_to_its_own_git_folder() {
    let scratch = Scratch::new("entry-link");
    let project = scratch.folder("tree/project");
    let store = scratch.folder("store").join("project.git");
    new_repository_with_its_git_folder_at(&project, &store);
    // The link is relative, as a tool for many repositories makes it.
    link_as_git_entry(&project, Path::new("../../store/project.git"));
    let below = scratch.folder("tree/project/below");

    assert_eq!(top_folder(&project), project);
    assert_eq!(top_folder(&below), project, "a folder below the top folder");
}

#[test]
fn own_tree_open_refuses_a_git_entry_that_is_a_link_to_the_git_folder_of_another_work_tree() {
    let scratch = Scratch::new("link-other");
    let other = scratch.0.join("other");
    new_repository(&other);
    let folder = scratch.folder("folder");
    link_as_git_entry(&folder, &other.join(".git"));

    let problem = refusal(&folder);

    assert!(problem.contains("is a link"), "{problem}");
    assert!(names_no_command(&problem), "{problem}");
    assert_eq!(top_folder(&other), other, "the other work tree still opens");
}

#[test]
fn own_tree_open_refuses_a_git_entry_that_is_a_link_to_a_git_folder_that_names_a_work_tree() {
    let scratch = Scratch::new("link-names");
    // The git folder has the record of a linked work tree.
    let main = scratch.0.join("main");
    new_repository(&main);
    let linked = linked_work_tree(&main, "linked");
    let by_record = scratch.folder("by-record");
    link_as_git_entry(&by_record, &main.join(".git/worktrees/linked"));
    // The git folder has the `core.worktree` setting.
    let store = scratch.0.join("store");
    let by_setting = folder_with_a_link_to_a_git_folder(&scratch, "by-setting", &store);
    git(&by_setting, &["config", "core.worktree", text(&by_setting)]);

    let problem = refusal(&by_record);
    assert!(problem.contains("is a link"), "{problem}");
    assert!(names_no_command(&problem), "{problem}");
    let problem = refusal(&by_setting);
    assert!(problem.contains("is a link"), "{problem}");
    assert!(names_no_command(&problem), "{problem}");

    assert_eq!(top_folder(&linked), linked, "the recorded work tree still opens");
}

/// A limit of the open. A git folder that names no work tree does not say which folder it is
/// for, so the open takes each folder whose `.git` entry is a link to it.
#[test]
fn own_tree_open_opens_each_folder_whose_git_entry_is_a_link_to_a_git_folder_of_no_work_tree() {
    let scratch = Scratch::new("link-limit");
    let store = scratch.0.join("store");
    let first = folder_with_a_link_to_a_git_folder(&scratch, "first", &store);
    let second = scratch.folder("second");
    link_as_git_entry(&second, &store);

    assert_eq!(top_folder(&first), first);
    assert_eq!(top_folder(&second), second);
}

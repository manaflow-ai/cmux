use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::fs::FileExt as _;
use std::os::unix::net::UnixListener;
use std::process::Command;

use super::*;

#[test]
fn the_manifest_holds_what_a_copy_sends_and_never_a_secret() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(root.join("README.md"), "# hi\n").unwrap();
    std::fs::write(root.join(".env"), "TOKEN=secret\n").unwrap();
    std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
    std::fs::write(root.join("node_modules/x/index.js"), "x\n").unwrap();

    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let manifest = &listed.manifest;
    let main = manifest.resolve("src/main.rs").expect("src/main.rs is in the manifest");
    assert_eq!(manifest.entry(main).unwrap().size, 13);
    assert!(manifest.resolve("README.md").is_some());
    assert_eq!(manifest.resolve(".env"), None, "a secret never reaches the manifest");
    assert_eq!(manifest.resolve("node_modules"), None, "a heavy folder stays here");

    // Reads are answered from the file the manifest named; an edit since is `changed`.
    assert_eq!(Source::whole(&listed, main), Part::ok(b"fn main() {}\n".to_vec()));
    assert_eq!(Source::read(&listed, main, 3, 4), Part::ok(b"main".to_vec()));
    std::fs::write(root.join("src/main.rs"), "fn main() { edited(); }\n").unwrap();
    assert_eq!(Source::whole(&listed, main).status, wire::CHANGED);
    // Anything that is not a file of the manifest is refused.
    assert_eq!(Source::whole(&listed, 0).status, wire::REFUSED);
    assert_eq!(Source::whole(&listed, 9999).status, wire::REFUSED);
}

#[test]
fn each_chat_folder_has_its_own_projection_name() {
    assert_eq!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/a"));
    assert_ne!(name_of("/home/cmux/work/a"), name_of("/home/cmux/work/b"));
    assert!(name_of("/x").bytes().all(|byte| byte.is_ascii_alphanumeric()));
}

#[test]
fn each_chat_has_its_own_projection_and_its_name_is_one_the_machine_takes() {
    let one = chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10");
    let two = chat_name("5b0a9d7e-2f43-4c1b-8e6d-3a9c7f1e2d40");
    assert_ne!(one, two);
    assert_eq!(one, chat_name("0c6f2c1e-6a4e-4d8e-9a59-1f7d3c2b9e10"));
    // The daemon's rule (cmux-tui-core projection.rs): 1-64 letters, digits, - or _.
    assert!(one.len() <= 64);
    assert!(one.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)));
}

#[test]
fn a_removed_source_is_reported_and_never_falls_back_to_bytes() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    std::fs::write(root.join("gone.txt"), "before").unwrap();
    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let entry = listed.manifest.resolve("gone.txt").unwrap();
    std::fs::remove_file(root.join("gone.txt")).unwrap();
    assert_eq!(Source::read(&listed, entry, 0, 16).status, wire::FAILED);
}

#[test]
fn a_huge_single_file_uses_ranged_reads_instead_of_whole() {
    let folder = tempfile::tempdir().unwrap();
    let root = folder.path();
    let path = root.join("huge.bin");
    let file = std::fs::File::create(&path).unwrap();
    let size: u64 = 64 * 1024 * 1024 * 1024 + 17;
    file.set_len(size).unwrap();
    let offset = u64::from(u32::MAX) + 4096;
    let sentinel = b"past u32 range";
    file.write_at(sentinel, offset).unwrap();
    drop(file);

    let listed = list(&std::fs::canonicalize(root).unwrap()).unwrap();
    let entry = listed.manifest.resolve("huge.bin").unwrap();
    assert_eq!(listed.manifest.entry(entry).unwrap().size, size);
    assert_eq!(
        Source::read(&listed, entry, offset, sentinel.len() as u32),
        Part::ok(sentinel.to_vec())
    );
    assert_eq!(Source::read(&listed, entry, size - 2, 64), Part::ok(vec![0, 0]));
    assert_eq!(Source::read(&listed, entry, size, 1), Part::ok(Vec::new()));
    assert_eq!(Source::whole(&listed, entry).status, wire::FAILED);
}

#[test]
fn line_carrier_preserves_manifest_bytes_including_newlines_and_nuls() {
    let bytes = b"before\n\0middle\r\nafter\0\n";
    let mut framed = Vec::new();
    cmux_tui_core::projection::LineWriter::new(&mut framed).write_all(bytes).unwrap();
    assert!(framed.starts_with(b"~"));
    assert!(framed.ends_with(b"\n"));

    let mut decoded = Vec::new();
    cmux_tui_core::projection::LineReader::new(BufReader::new(std::io::Cursor::new(framed)))
        .read_to_end(&mut decoded)
        .unwrap();
    assert_eq!(decoded, bytes);
}

#[test]
fn dial_uses_the_line_carrier_for_manifest_bytes() {
    let folder = tempfile::tempdir().unwrap();
    let socket = folder.path().join("carrier.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let manifest = b"manifest\nwith\0bytes\n".to_vec();
    let expected = manifest.clone();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut first = String::new();
        reader.read_line(&mut first).unwrap();
        let first: Value = serde_json::from_str(first.trim()).unwrap();
        assert_eq!(first["lines"], true);
        assert_eq!(first["manifest_bytes"], expected.len());

        let mut decoded = vec![0; expected.len()];
        cmux_tui_core::projection::LineReader::new(&mut reader).read_exact(&mut decoded).unwrap();
        assert_eq!(decoded, expected);

        let mut writer = stream;
        writer.write_all(b"{\"id\":1,\"ok\":true,\"data\":{}}\n").unwrap();
        writer.flush().unwrap();
    });

    let (reader, answer) = dial(&socket, "chat-test", "/workspace", &manifest).unwrap();
    assert!(ok(&answer));
    drop(reader);
    server.join().unwrap();
}

#[test]
fn env_zero_disables_projection_without_mutating_machine_state() {
    const CHILD: &str = "CMUX_PROJECTED_FOLDERS_TEST_CHILD";
    if std::env::var_os(CHILD).is_some() {
        assert!(!enabled());
        return;
    }

    let status = Command::new(std::env::current_exe().unwrap())
        .arg("env_zero_disables_projection_without_mutating_machine_state")
        .env(ENV, "0")
        .env(CHILD, "1")
        .status()
        .unwrap();
    assert!(status.success());
}

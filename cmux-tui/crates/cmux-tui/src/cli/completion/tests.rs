use super::{candidates, options, rows, verbs};

const ROOT: &str = "USAGE\n  cmux attach\n\nYOU\n  chat          Start a chat\n  vm            Your VMs\n  --json        Print JSON\n";
const VM: &str = "QUICK START\n  cmux vm ls | status | pause [NAME]\n  cmux vm exec dev -- uname -a\nMACHINES\n  list-machines   List them\n";

fn help(args: &[&str]) -> Option<String> {
    match args {
        [] => Some(ROOT.to_owned()),
        ["vm"] => Some(VM.to_owned()),
        ["vm", "exec"] => Some("usage: cmux vm exec [--json] [--timeout-ms MS]".to_owned()),
        _ => None,
    }
}

fn complete(words: &[&str]) -> Vec<String> {
    let words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    candidates(&words, &help)
}

#[test]
fn scopes_verbs_and_options_complete_from_the_help() {
    assert_eq!(complete(&["v"]), ["vm"]);
    assert!(complete(&[""]).contains(&"chat".to_owned()));
    assert!(complete(&[""]).contains(&"completion".to_owned()));
    assert_eq!(complete(&["vm", "l"]), ["list-machines", "ls"]);
    assert_eq!(complete(&["vm", "ex"]), ["exec"]);
    assert_eq!(complete(&["vm", "exec", "--t"]), ["--timeout-ms"]);
    assert_eq!(complete(&["--socket", "/tmp/s", "vm", "p"]), ["pause"]);
    assert_eq!(complete(&["completion", ""]), ["bash", "fish", "zsh"]);
    // Bash's words for `cmux --session=dev vm p`.
    assert_eq!(complete(&["--session", "=", "dev", "vm", "p"]), ["pause"]);
    assert_eq!(complete(&["--session=dev", "vm", "p"]), ["pause"]);
    assert!(complete(&["nope", ""]).is_empty());
}

#[test]
fn the_readers_take_rows_usage_lines_and_options() {
    assert_eq!(rows(ROOT), ["chat", "vm"]);
    assert!(verbs("vm", VM).contains(&"pause".to_owned()));
    assert_eq!(options("[--json] --timeout-ms MS, --Bad x--y --a-"), ["--json", "--timeout-ms"]);
}

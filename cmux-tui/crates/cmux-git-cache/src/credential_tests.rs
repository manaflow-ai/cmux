use super::*;

#[test]
fn maps_proxy_path_to_github() {
    let req = "protocol=http\nhost=127.0.0.1:47380\npath=github.com/o/r.git\nusername=x\n\n";
    assert_eq!(
        map_request(req).unwrap(),
        "protocol=https\nhost=github.com\npath=o/r.git\nusername=x\n"
    );
    assert!(map_request("protocol=http\nhost=127.0.0.1:1\npath=gitlab.com/o/r\n").is_none());
    assert!(map_request("protocol=http\nhost=127.0.0.1:1\n").is_none());
}

#[test]
fn no_credential_answers_anonymous() {
    assert_eq!(fill_answer(None), "username=cmux-git-cache-anon\npassword=x\n");
    assert_eq!(fill_answer(Some(String::new())), "username=cmux-git-cache-anon\npassword=x\n");
    assert_eq!(fill_answer(Some("username=u\npassword=p\n".into())), "username=u\npassword=p\n");
}

#[test]
fn answer_keeps_only_credentials() {
    let a = "protocol=https\nhost=github.com\npath=o/r.git\nusername=u\npassword=p\nquit=1\n";
    assert_eq!(filter_answer(a), "username=u\npassword=p\n");
}

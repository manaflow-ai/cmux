use super::*;

fn tab(dir: &str) -> Tab {
    Tab {
        working_directory: Some(dir.into()),
        title: None,
        url: None,
        agent: None,
        scrollback: None,
    }
}

#[test]
fn an_ssh_destination_brackets_ipv6_and_leaves_out_port_22() {
    let remote = |destination: &str, port| Remote { destination: destination.into(), port };
    assert_eq!(remote("me@host", Some(22)).ssh_destination(), "me@host");
    assert_eq!(remote("me@host", Some(2222)).ssh_destination(), "me@host:2222");
    assert_eq!(remote("::1", None).ssh_destination(), "[::1]");
    assert_eq!(remote("a@b@fe80::1", Some(23)).ssh_destination(), "a@b@[fe80::1]:23");
}

#[test]
fn a_side_with_no_tab_kept_closes_up_and_the_selection_follows_its_tab() {
    let layout = Layout::Split {
        orientation: Orientation::Vertical,
        ratio: 0.3,
        first: Box::new(Layout::Pane(Pane { tabs: vec![tab("/drop")], selected_tab: 0 })),
        second: Box::new(Layout::Pane(Pane {
            tabs: vec![tab("/drop"), tab("/a"), tab("/b")],
            selected_tab: 2,
        })),
    };
    let kept = layout.keeping(&|tab| tab.working_directory.as_deref() != Some("/drop")).unwrap();
    assert_eq!(kept, Layout::Pane(Pane { tabs: vec![tab("/a"), tab("/b")], selected_tab: 1 }));
    assert_eq!(layout.keeping(&|_| false), None);
}

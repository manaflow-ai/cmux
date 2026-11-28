use super::*;

#[test]
fn each_client_is_counted_by_name_with_its_largest_reply() {
    let lists = ListBytes::new();
    lists.observe("cmux-next-turn-states (local)", 31 << 20);
    lists.observe("cmux-next-turn-states (local)", 1 << 20);
    lists.observe("cmux-react-agent-pane (app)", 2048);
    let status = lists.status();
    assert_eq!(status["cmux-next-turn-states (local)"]["replies"], 2);
    assert_eq!(status["cmux-next-turn-states (local)"]["bytes"], (32u64 << 20));
    assert_eq!(status["cmux-next-turn-states (local)"]["largest"], (31u64 << 20));
    assert_eq!(status["cmux-react-agent-pane (app)"]["replies"], 1);
}

#[test]
fn past_its_client_cap_the_rest_count_as_other() {
    let lists = ListBytes::new();
    for i in 0..CLIENTS + 5 {
        lists.observe(&format!("c{i}"), 10);
    }
    let status = lists.status();
    assert_eq!(status.as_object().map(|o| o.len()), Some(CLIENTS + 1));
    assert_eq!(status["(other)"]["replies"], 5);
}

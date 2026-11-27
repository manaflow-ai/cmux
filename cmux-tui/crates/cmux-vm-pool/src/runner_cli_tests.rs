use super::wait_news;

#[test]
fn wait_news_names_each_change_once() {
    assert_eq!(wait_news(false, false, true, false), Some("online, waiting for a job"));
    assert_eq!(wait_news(true, false, true, true), Some("took a job"));
    assert_eq!(wait_news(false, false, true, true), Some("took a job"));
    assert_eq!(wait_news(true, true, true, false), Some("job finished"));
    assert_eq!(wait_news(true, false, true, false), None);
    assert_eq!(wait_news(true, true, true, true), None);
    assert_eq!(wait_news(false, false, false, false), None);
}

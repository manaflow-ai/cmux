use super::*;

#[test]
fn settings_list_human_table_keeps_values_and_defaults() {
    let rows =
        json!([{"key":"sidebar.side", "value":"right", "default":"left", "customized":true}]);
    assert_eq!(
        human_rows(&rows),
        json!([{"key":"sidebar.side", "value":"right", "default":"left"}])
    );
}

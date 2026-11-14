use super::*;

#[test]
fn long_path_lists_split_inside_the_argument_limit() {
    let paths: Vec<String> = (0..10_000).map(|i| format!("some/longer/path/{i:05}")).collect();
    let groups = chunks(&paths);
    assert!(groups.len() > 1);
    assert_eq!(groups.iter().map(|g| g.len()).sum::<usize>(), paths.len());
    assert!(
        groups.iter().all(|g| g.iter().map(|p| p.len() + 1).sum::<usize>() <= MAX_ARGUMENT_BYTES)
    );
    assert!(chunks(&[]).is_empty());
}

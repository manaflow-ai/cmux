//! Closest-match suggestions for mistyped CLI words.

pub(super) fn suggestion<'a>(value: &str, candidates: &'a [&str]) -> Option<&'a str> {
    candidates
        .iter()
        .copied()
        .map(|candidate| (edit_distance(value, candidate), candidate))
        .min_by_key(|(distance, _)| *distance)
        .filter(|(distance, candidate)| {
            *distance <= 2 || (*distance == 3 && candidate.len().max(value.len()) >= 8)
        })
        .map(|(_, candidate)| candidate)
}

fn edit_distance(left: &str, right: &str) -> usize {
    let right = right.chars().collect::<Vec<_>>();
    let mut previous = (0..=right.len()).collect::<Vec<_>>();
    for (row, left) in left.chars().enumerate() {
        let mut current = vec![row + 1];
        for (column, right) in right.iter().enumerate() {
            current.push(
                (current[column] + 1)
                    .min(previous[column + 1] + 1)
                    .min(previous[column] + usize::from(left != *right)),
            );
        }
        previous = current;
    }
    previous[right.len()]
}

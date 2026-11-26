use super::*;

fn opts() -> Options {
    Options::parse(&["--socket".into(), "/x".into()]).unwrap()
}

/// A wrapped line's rows fill the width exactly, so each row starts with its own marker.
#[test]
fn every_row_of_a_wrapped_line_but_the_last_fills_the_width() {
    let cols = 120;
    for n in 1..400u64 {
        let segs = segments(n);
        for k in 0..segs {
            let row = expected_row(n, k, cols);
            assert!(row.len() as u64 <= cols, "{n}/{k}");
            if k + 1 < segs {
                assert_eq!(row.len() as u64, cols, "{n}/{k}");
            }
            assert_eq!(parse_row(&row, cols), Row::Numbered { n, k, intact: true });
        }
    }
}

#[test]
fn a_blank_or_missing_row_inside_the_viewport_is_counted() {
    let o = opts();
    let ordinals = Ordinals::new(last_line(&o));
    let cols = u64::from(o.cols);
    let mut rows: Vec<String> = (0..20).map(|i| row_at(&ordinals, i, cols)).collect();
    assert_eq!(check_viewport(&rows, false, cols, &ordinals).0.blank, 0);
    rows[5] = String::new();
    rows[9] = row_at(&ordinals, 30, cols);
    let (defects, top) = check_viewport(&rows, false, cols, &ordinals);
    assert_eq!((defects.blank, defects.missing, top), (1, 2, Some(0)));
    // At the live bottom, blank rows below the last numbered row are the screen's own.
    let mut bottom: Vec<String> = (0..10).map(|i| row_at(&ordinals, i, cols)).collect();
    bottom.extend(["STATUS 1/3".to_string(), String::new()]);
    assert_eq!(check_viewport(&bottom, true, cols, &ordinals).0.missing, 0);
    assert_eq!(check_viewport(&bottom, false, cols, &ordinals).0.missing, 1);
}

fn row_at(ordinals: &Ordinals, index: u64, cols: u64) -> String {
    let n = ordinals.0.iter().rposition(|start| *start <= index).unwrap() as u64;
    let n = (1..=n).rev().find(|n| ordinals.of(*n, 0).unwrap() <= index).unwrap();
    expected_row(n, index - ordinals.of(n, 0).unwrap(), cols)
}

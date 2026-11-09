//! The C ABI of the keyboard resize rules (`cmux_shown_resize_*`): every corpus case answers through the C calls as
//! the Swift rules did (`cmux-layout-reducer/tests/data/shown_resize_corpus.txt`), the structs have the header's sizes,
//! and a null pointer writes nothing.

use cmux_layout_reducer_ffi::shown_resize::{
    CmuxShownResizeBounds, CmuxShownResizeDock, CmuxShownResizeRows, CmuxShownResizeTrade,
    CmuxShownResizeTradeAnswer, cmux_shown_resize_column_width, cmux_shown_resize_dock_width,
    cmux_shown_resize_ratio, cmux_shown_resize_row_heights, cmux_shown_resize_trade,
};
use cmux_layout_reducer_ffi::{ERR_NULL, OK};
use std::ptr;

const CORPUS: &str = include_str!("../../cmux-layout-reducer/tests/data/shown_resize_corpus.txt");

struct Fields<'a>(std::str::SplitWhitespace<'a>);

impl<'a> Fields<'a> {
    fn word(&mut self) -> &'a str {
        self.0.next().expect("short line")
    }
    fn float(&mut self) -> f64 {
        f64::from_bits(u64::from_str_radix(self.word(), 16).expect("float bits"))
    }
    fn int(&mut self) -> i64 {
        self.word().parse().expect("int")
    }
    fn flag(&mut self) -> u8 {
        u8::from(self.word() == "1")
    }
}

fn hex(value: f64) -> String {
    format!("{:x}", value.to_bits())
}

fn bounds(code: i32, out: CmuxShownResizeBounds) -> String {
    match code {
        1 => format!("{} {}", hex(out.lower), hex(out.upper)),
        0 => "-".to_owned(),
        other => panic!("code {other}"),
    }
}

fn answer(kind: &str, f: &mut Fields<'_>) -> String {
    let mut out = CmuxShownResizeBounds::default();
    match kind {
        "ratio" => {
            let (c, d, a, b) = (f.float(), f.float(), f.float(), f.float());
            bounds(unsafe { cmux_shown_resize_ratio(c, d, a, b, &mut out) }, out)
        }
        "width" => {
            let (columns, docked, strip, minimum, gap) =
                (f.flag(), f.flag(), f.float(), f.float(), f.float());
            bounds(
                unsafe {
                    cmux_shown_resize_column_width(columns, docked, strip, minimum, gap, &mut out)
                },
                out,
            )
        }
        "dock" => {
            let (viewport, gap, minimum) = (f.float(), f.float(), f.float());
            let count = f.int();
            let docks: Vec<CmuxShownResizeDock> = (0..count)
                .map(|_| CmuxShownResizeDock {
                    is_target: f.flag(),
                    is_band: f.flag(),
                    is_docked: f.flag(),
                    width: f.float(),
                    reserved: [0; 5],
                })
                .collect();
            let code = unsafe {
                cmux_shown_resize_dock_width(
                    docks.as_ptr(),
                    docks.len(),
                    viewport,
                    gap,
                    minimum,
                    &mut out,
                )
            };
            bounds(code, out)
        }
        "trade" => {
            let mut input =
                CmuxShownResizeTrade { is_columns: f.flag(), ..CmuxShownResizeTrade::default() };
            for field in [
                &mut input.strip_width,
                &mut input.gap,
                &mut input.scale,
                &mut input.delta,
                &mut input.left_min_x,
                &mut input.left_max_x,
                &mut input.left_width,
                &mut input.right_min_x,
                &mut input.right_max_x,
                &mut input.right_width,
                &mut input.left_minimum_width,
                &mut input.right_minimum_width,
                &mut input.left_fraction,
                &mut input.right_fraction,
            ] {
                *field = f.float();
            }
            let offset = f.word();
            if offset != "-" {
                input.has_strip_offset = 1;
                input.strip_offset =
                    f64::from_bits(u64::from_str_radix(offset, 16).expect("offset"));
            }
            input.uncovered_min_x = f.float();
            input.uncovered_max_x = f.float();
            input.strip_min_x = f.float();
            let mut out = CmuxShownResizeTradeAnswer::default();
            match unsafe { cmux_shown_resize_trade(&input, &mut out) } {
                1 => [
                    out.move_points,
                    out.first_left,
                    out.first_right,
                    out.second_left,
                    out.second_right,
                ]
                .map(hex)
                .join(" "),
                0 => "-".to_owned(),
                other => panic!("code {other}"),
            }
        }
        "rows" => {
            let count = usize::try_from(f.int()).expect("count");
            let heights: Vec<i64> = (0..count).map(|_| f.int()).collect();
            let minimums: Vec<f64> = (0..count).map(|_| f.float()).collect();
            let pane_row = usize::try_from(f.int()).expect("row");
            let rows_enabled = f.flag();
            let input = CmuxShownResizeRows {
                heights: heights.as_ptr(),
                minimum_heights: minimums.as_ptr(),
                count,
                pane_row,
                column_height: f.float(),
                gap: f.float(),
                scale: f.float(),
                delta: f.float(),
                rows_enabled,
                reserved: [0; 7],
            };
            let mut out = vec![0_i64; count];
            match unsafe { cmux_shown_resize_row_heights(&input, out.as_mut_ptr(), out.len()) } {
                1 => out.iter().map(i64::to_string).collect::<Vec<_>>().join(" "),
                0 => "-".to_owned(),
                other => panic!("code {other}"),
            }
        }
        other => panic!("unknown kind {other}"),
    }
}

#[test]
fn shown_resize_c_calls_answer_the_corpus_as_the_swift_rules_did() {
    let mut cases = 0;
    for line in CORPUS.lines().filter(|line| !line.starts_with('#') && !line.is_empty()) {
        let (inputs, expected) = line.split_once(" => ").expect("=>");
        let mut fields = Fields(inputs.split_whitespace());
        let kind = fields.word();
        assert_eq!(answer(kind, &mut fields), expected, "{line}");
        cases += 1;
    }
    assert!(cases >= 2000, "{cases}");
}

#[test]
fn shown_resize_structs_have_the_header_layout() {
    use std::mem::{align_of, size_of};
    assert_eq!((size_of::<CmuxShownResizeBounds>(), align_of::<CmuxShownResizeBounds>()), (16, 8));
    assert_eq!((size_of::<CmuxShownResizeDock>(), align_of::<CmuxShownResizeDock>()), (16, 8));
    assert_eq!(
        (size_of::<CmuxShownResizeTrade>(), align_of::<CmuxShownResizeTrade>()),
        (18 * 8 + 8, 8)
    );
    assert_eq!(
        (size_of::<CmuxShownResizeTradeAnswer>(), align_of::<CmuxShownResizeTradeAnswer>()),
        (40, 8)
    );
    assert_eq!(
        (size_of::<CmuxShownResizeRows>(), align_of::<CmuxShownResizeRows>()),
        (8 * 8 + 8, 8)
    );
}

#[test]
fn shown_resize_null_pointers_write_nothing() {
    let before = CmuxShownResizeBounds { lower: 7.0, upper: 9.0 };
    let mut out = before;
    assert_eq!(unsafe { cmux_shown_resize_ratio(1.0, 0.0, 0.0, 0.0, ptr::null_mut()) }, ERR_NULL);
    assert_eq!(
        unsafe { cmux_shown_resize_dock_width(ptr::null(), 2, 100.0, 0.0, 0.0, &mut out) },
        ERR_NULL
    );
    assert_eq!(out, before);
    assert_eq!(unsafe { cmux_shown_resize_trade(ptr::null(), ptr::null_mut()) }, ERR_NULL);
    let heights = [500_i64, 500];
    let rows = CmuxShownResizeRows {
        heights: heights.as_ptr(),
        minimum_heights: ptr::null(),
        count: 2,
        pane_row: 0,
        column_height: 992.0,
        gap: 8.0,
        scale: 2.0,
        delta: 0.1,
        rows_enabled: 1,
        reserved: [0; 7],
    };
    let mut written = [0_i64; 2];
    assert_eq!(unsafe { cmux_shown_resize_row_heights(&rows, written.as_mut_ptr(), 2) }, ERR_NULL);
    assert_eq!(written, [0, 0]);
    // An empty dock list is no dock: 0, not an error.
    assert_eq!(
        unsafe { cmux_shown_resize_dock_width(ptr::null(), 0, 100.0, 0.0, 0.0, &mut out) },
        OK
    );
}

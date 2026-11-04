//! The C ABI of the springing-close rules (`cmux_closing_panes_*`): every call of the corpus answers through the C
//! calls as the Swift rules did (`cmux-layout-reducer/tests/data/closing_panes_corpus.txt`; the reducer's own test
//! checks the state after each call too), the structs have the header's sizes and field offsets, and a null pointer
//! or an unknown handle kind writes nothing.

use cmux_layout_reducer_ffi::closing_panes::{
    CmuxClosingEdges, CmuxClosingFrame, CmuxClosingHandle, CmuxClosingIds, CmuxClosingPane,
    CmuxClosingPanes, CmuxClosingPlaced, CmuxClosingPlacedList, CmuxClosingRect, CmuxClosingRow,
    CmuxClosingTaken, cmux_closing_panes_begin, cmux_closing_panes_carry, cmux_closing_panes_drop,
    cmux_closing_panes_free, cmux_closing_panes_has_awaiting, cmux_closing_panes_new,
    cmux_closing_panes_rects, cmux_closing_panes_remove, cmux_closing_panes_settle,
    cmux_closing_panes_settle_carried, cmux_closing_panes_shift_y, cmux_closing_panes_state_hash,
};
use cmux_layout_reducer_ffi::{ERR_INVALID, ERR_NULL, OK};
use std::mem::{offset_of, size_of};
use std::ptr;

const CORPUS: &str = include_str!("../../cmux-layout-reducer/tests/data/closing_panes_corpus.txt");

struct Fields<'a>(std::str::SplitWhitespace<'a>);

impl<'a> Fields<'a> {
    fn word(&mut self) -> &'a str {
        self.0.next().expect("short line")
    }
    fn float(&mut self) -> f64 {
        self.word().parse().expect("number")
    }
    fn optional(&mut self) -> (u8, f64) {
        match self.word() {
            "-" => (0, 0.0),
            text => (1, text.parse().expect("number")),
        }
    }
    fn id(&mut self) -> u64 {
        self.word().parse().expect("id")
    }
    fn flag(&mut self) -> u8 {
        u8::from(self.word() == "1")
    }
    fn edges(&mut self) -> CmuxClosingEdges {
        CmuxClosingEdges {
            min_x: self.float(),
            max_x: self.float(),
            min_y: self.float(),
            max_y: self.float(),
        }
    }
    fn frames(&mut self) -> Vec<CmuxClosingFrame> {
        (0..self.id())
            .map(|_| {
                let (id, now, target, moving) =
                    (self.id(), self.edges(), self.edges(), self.flag());
                CmuxClosingFrame {
                    id,
                    now,
                    target,
                    moving,
                    vx: self.float(),
                    vy: self.float(),
                    vw: self.float(),
                    vh: self.float(),
                    reserved: [0; 7],
                }
            })
            .collect()
    }
    fn rows(&mut self) -> Vec<CmuxClosingRow> {
        (0..self.id())
            .map(|_| CmuxClosingRow { column: self.id(), now: self.float(), target: self.float() })
            .collect()
    }
}

fn hex(value: f64) -> String {
    format!("{:x}", value.to_bits())
}

fn rect(r: CmuxClosingRect) -> String {
    [r.x, r.y, r.width, r.height].map(hex).join(",")
}

/// One call of the corpus through the C ABI: its answer (the part of the line before the state hash).
fn call(line: &str, closing: *mut CmuxClosingPanes) -> String {
    let mut f = Fields(line.split_whitespace());
    let answer = match f.word() {
        "B" => {
            let pane = f.id();
            let shown = f.edges();
            let max_gap = f.float();
            let (has_shift, shift) = f.optional();
            let panes: Vec<CmuxClosingPane> = (0..f.id())
                .map(|_| {
                    let (id, edges, scrolls) = (f.id(), f.edges(), f.flag());
                    CmuxClosingPane {
                        id,
                        area: f.id(),
                        row_column: f.id(),
                        edges,
                        scrolls,
                        reserved: [0; 7],
                    }
                })
                .collect();
            let handles: Vec<CmuxClosingHandle> = (0..f.id())
                .map(|_| {
                    let (kind, horizontal, hit, mid_x, mid_y) =
                        (f.id(), f.flag(), f.edges(), f.float(), f.float());
                    let (kept, fixed_split, area, docked, column) =
                        (f.flag(), f.flag(), f.id(), f.flag(), f.id());
                    CmuxClosingHandle {
                        hit,
                        mid_x,
                        mid_y,
                        area,
                        column,
                        kind: u8::try_from(kind).expect("kind"),
                        horizontal,
                        kept,
                        fixed_split,
                        docked,
                        reserved: [0; 3],
                    }
                })
                .collect();
            // SAFETY: a live handle; the arrays hold their counts.
            let code = unsafe {
                cmux_closing_panes_begin(
                    closing,
                    pane,
                    &shown,
                    panes.as_ptr(),
                    panes.len(),
                    handles.as_ptr(),
                    handles.len(),
                    max_gap,
                    has_shift,
                    shift,
                )
            };
            assert!(code == 0 || code == 1, "begin {code}");
            code.to_string()
        }
        "T" => {
            let (frames, rows) = (f.frames(), f.rows());
            let mut out = CmuxClosingIds { ids: ptr::null(), count: 0 };
            // SAFETY: as above; `out` is a separate local.
            let code = unsafe {
                cmux_closing_panes_settle(
                    closing,
                    frames.as_ptr(),
                    frames.len(),
                    rows.as_ptr(),
                    rows.len(),
                    &mut out,
                )
            };
            assert_eq!(code, OK);
            // SAFETY: the list borrows the handle's buffer until the next call.
            let ids = if out.count == 0 {
                &[][..]
            } else {
                unsafe { std::slice::from_raw_parts(out.ids, out.count) }
            };
            if ids.is_empty() {
                "-".to_owned()
            } else {
                ids.iter().map(u64::to_string).collect::<Vec<_>>().join(",")
            }
        }
        "R" => {
            let (frames, rows) = (f.frames(), f.rows());
            let mut out = CmuxClosingPlacedList { placed: ptr::null(), count: 0 };
            // SAFETY: as above.
            let code = unsafe {
                cmux_closing_panes_rects(
                    closing,
                    frames.as_ptr(),
                    frames.len(),
                    rows.as_ptr(),
                    rows.len(),
                    &mut out,
                )
            };
            assert_eq!(code, OK);
            let placed: &[CmuxClosingPlaced] =
                // SAFETY: the list borrows the handle's buffer until the next call.
                if out.count == 0 { &[] } else { unsafe { std::slice::from_raw_parts(out.placed, out.count) } };
            if placed.is_empty() {
                "-".to_owned()
            } else {
                placed
                    .iter()
                    .map(|p| format!("{}:{}", p.pane, rect(p.rect)))
                    .collect::<Vec<_>>()
                    .join(";")
            }
        }
        "C" => {
            let drift = f.float();
            let (has_shift, shift) = f.optional();
            // SAFETY: a live handle.
            assert_eq!(unsafe { cmux_closing_panes_carry(closing, drift, has_shift, shift) }, OK);
            "-".to_owned()
        }
        "K" => {
            // SAFETY: a live handle.
            assert_eq!(unsafe { cmux_closing_panes_settle_carried(closing, f.float()) }, OK);
            "-".to_owned()
        }
        "Y" => {
            let column = f.id();
            // SAFETY: a live handle.
            assert_eq!(unsafe { cmux_closing_panes_shift_y(closing, column, f.float()) }, OK);
            "-".to_owned()
        }
        "X" => {
            let pane = f.id();
            let frames = f.frames();
            let mut out = CmuxClosingTaken::default();
            // SAFETY: as above.
            match unsafe {
                cmux_closing_panes_remove(closing, pane, frames.as_ptr(), frames.len(), &mut out)
            } {
                1 => format!(
                    "{},{}",
                    rect(out.rect),
                    [out.vx, out.vw, out.vy, out.vh].map(hex).join(",")
                ),
                0 => {
                    assert_eq!(out, CmuxClosingTaken::default(), "nothing written");
                    "-".to_owned()
                }
                code => panic!("remove {code}"),
            }
        }
        "D" => {
            // SAFETY: a live handle.
            assert_eq!(unsafe { cmux_closing_panes_drop(closing, f.id()) }, OK);
            "-".to_owned()
        }
        other => panic!("unknown call {other}"),
    };
    assert!(f.0.next().is_none(), "unread words: {line}");
    answer
}

#[test]
fn every_call_of_the_corpus_answers_through_the_c_abi_as_the_swift_rules_did() {
    let mut closing = cmux_closing_panes_new();
    let mut calls = 0;
    for raw in CORPUS.lines().filter(|l| !l.is_empty() && !l.starts_with('#')) {
        if raw == "S" {
            // SAFETY: the handle came from cmux_closing_panes_new and is freed once.
            unsafe { cmux_closing_panes_free(closing) };
            closing = cmux_closing_panes_new();
            continue;
        }
        let (inputs, expected) = raw.split_once(" => ").expect("bad line");
        let (answer, state) = expected.rsplit_once(' ').expect("answer and state");
        assert_eq!(call(inputs, closing), answer, "{}", &inputs[..inputs.len().min(120)]);
        // SAFETY: a live handle.
        assert_eq!(
            format!("{:x}", unsafe { cmux_closing_panes_state_hash(closing) }),
            state,
            "state after {}",
            &inputs[..1]
        );
        calls += 1;
    }
    // SAFETY: freed once.
    unsafe { cmux_closing_panes_free(closing) };
    assert!(calls >= 1000, "{calls} calls");
}

#[test]
fn the_structs_have_the_header_s_sizes_and_field_offsets() {
    assert_eq!(size_of::<CmuxClosingEdges>(), 32);
    assert_eq!(size_of::<CmuxClosingRect>(), 32);
    assert_eq!(
        (
            offset_of!(CmuxClosingEdges, max_x),
            offset_of!(CmuxClosingEdges, min_y),
            offset_of!(CmuxClosingEdges, max_y)
        ),
        (8, 16, 24)
    );
    assert_eq!(
        (
            offset_of!(CmuxClosingRect, y),
            offset_of!(CmuxClosingRect, width),
            offset_of!(CmuxClosingRect, height)
        ),
        (8, 16, 24)
    );
    assert_eq!(size_of::<CmuxClosingPane>(), 64);
    assert_eq!(
        [
            offset_of!(CmuxClosingPane, area),
            offset_of!(CmuxClosingPane, row_column),
            offset_of!(CmuxClosingPane, edges),
            offset_of!(CmuxClosingPane, scrolls)
        ],
        [8, 16, 24, 56]
    );
    assert_eq!(size_of::<CmuxClosingHandle>(), 72);
    assert_eq!(
        [
            offset_of!(CmuxClosingHandle, mid_x),
            offset_of!(CmuxClosingHandle, mid_y),
            offset_of!(CmuxClosingHandle, area),
            offset_of!(CmuxClosingHandle, column),
            offset_of!(CmuxClosingHandle, kind),
            offset_of!(CmuxClosingHandle, horizontal),
            offset_of!(CmuxClosingHandle, kept),
            offset_of!(CmuxClosingHandle, fixed_split),
            offset_of!(CmuxClosingHandle, docked),
        ],
        [32, 40, 48, 56, 64, 65, 66, 67, 68]
    );
    assert_eq!(size_of::<CmuxClosingFrame>(), 112);
    assert_eq!(
        [
            offset_of!(CmuxClosingFrame, now),
            offset_of!(CmuxClosingFrame, target),
            offset_of!(CmuxClosingFrame, vx),
            offset_of!(CmuxClosingFrame, vy),
            offset_of!(CmuxClosingFrame, vw),
            offset_of!(CmuxClosingFrame, vh),
            offset_of!(CmuxClosingFrame, moving),
        ],
        [8, 40, 72, 80, 88, 96, 104]
    );
    assert_eq!(size_of::<CmuxClosingRow>(), 24);
    assert_eq!((offset_of!(CmuxClosingRow, now), offset_of!(CmuxClosingRow, target)), (8, 16));
    assert_eq!(size_of::<CmuxClosingPlaced>(), 40);
    assert_eq!(offset_of!(CmuxClosingPlaced, rect), 8);
    assert_eq!(size_of::<CmuxClosingTaken>(), 64);
    assert_eq!(
        [
            offset_of!(CmuxClosingTaken, vx),
            offset_of!(CmuxClosingTaken, vw),
            offset_of!(CmuxClosingTaken, vy),
            offset_of!(CmuxClosingTaken, vh)
        ],
        [32, 40, 48, 56]
    );
    assert_eq!(size_of::<CmuxClosingIds>(), 16);
    assert_eq!(size_of::<CmuxClosingPlacedList>(), 16);
}

#[test]
fn a_null_pointer_or_an_unknown_kind_writes_nothing() {
    let closing = cmux_closing_panes_new();
    let shown = CmuxClosingEdges { min_x: 0.0, max_x: 10.0, min_y: 0.0, max_y: 10.0 };
    let pane = CmuxClosingPane { id: 1, edges: shown, scrolls: 1, ..CmuxClosingPane::default() };
    let bad = CmuxClosingHandle { kind: 9, ..CmuxClosingHandle::default() };
    // SAFETY: live handle, arrays of their counts, null where the test says.
    unsafe {
        assert_eq!(
            cmux_closing_panes_begin(
                ptr::null_mut(),
                1,
                &shown,
                &pane,
                1,
                ptr::null(),
                0,
                9.0,
                0,
                0.0
            ),
            ERR_NULL
        );
        assert_eq!(
            cmux_closing_panes_begin(
                closing,
                1,
                ptr::null(),
                &pane,
                1,
                ptr::null(),
                0,
                9.0,
                0,
                0.0
            ),
            ERR_NULL
        );
        assert_eq!(
            cmux_closing_panes_begin(
                closing,
                1,
                &shown,
                ptr::null(),
                1,
                ptr::null(),
                0,
                9.0,
                0,
                0.0
            ),
            ERR_NULL
        );
        assert_eq!(
            cmux_closing_panes_begin(closing, 1, &shown, &pane, 1, &bad, 1, 9.0, 0, 0.0),
            ERR_INVALID
        );
        assert_eq!(cmux_closing_panes_has_awaiting(closing), 0, "a refused begin starts nothing");
        assert_eq!(
            cmux_closing_panes_begin(closing, 2, &shown, &pane, 1, ptr::null(), 0, 9.0, 0, 0.0),
            0,
            "not in the layout"
        );
        assert_eq!(
            cmux_closing_panes_begin(closing, 1, &shown, &pane, 1, ptr::null(), 0, 9.0, 0, 0.0),
            1
        );
        assert_eq!(cmux_closing_panes_has_awaiting(closing), 1);
        assert_eq!(cmux_closing_panes_has_awaiting(ptr::null()), 0);
        let mut ids = CmuxClosingIds { ids: ptr::null(), count: 7 };
        assert_eq!(
            cmux_closing_panes_settle(closing, ptr::null(), 1, ptr::null(), 0, &mut ids),
            ERR_NULL
        );
        assert_eq!((ids.ids, ids.count), (ptr::null(), 7), "nothing written");
        assert_eq!(
            cmux_closing_panes_settle(closing, ptr::null(), 0, ptr::null(), 0, ptr::null_mut()),
            ERR_NULL
        );
        let mut list = CmuxClosingPlacedList { placed: ptr::null(), count: 7 };
        assert_eq!(
            cmux_closing_panes_rects(ptr::null_mut(), ptr::null(), 0, ptr::null(), 0, &mut list),
            ERR_NULL
        );
        assert_eq!(list.count, 7, "nothing written");
        let mut taken = CmuxClosingTaken::default();
        assert_eq!(
            cmux_closing_panes_remove(closing, 1, ptr::null(), 0, ptr::null_mut()),
            ERR_NULL
        );
        assert_eq!(cmux_closing_panes_remove(closing, 5, ptr::null(), 0, &mut taken), 0);
        assert_eq!(taken, CmuxClosingTaken::default(), "nothing written");
        assert_eq!(cmux_closing_panes_remove(closing, 1, ptr::null(), 0, &mut taken), 1);
        assert_eq!(taken.rect, CmuxClosingRect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 });
        assert_eq!(cmux_closing_panes_carry(ptr::null_mut(), 1.0, 0, 0.0), ERR_NULL);
        assert_eq!(cmux_closing_panes_settle_carried(ptr::null_mut(), 1.0), ERR_NULL);
        assert_eq!(cmux_closing_panes_shift_y(ptr::null_mut(), 1, 1.0), ERR_NULL);
        assert_eq!(cmux_closing_panes_drop(ptr::null_mut(), 1), ERR_NULL);
        cmux_closing_panes_free(closing);
        cmux_closing_panes_free(ptr::null_mut());
    }
}

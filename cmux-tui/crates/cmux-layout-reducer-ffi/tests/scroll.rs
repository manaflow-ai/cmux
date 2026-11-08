//! The column scroll reducer through its C ABI (`cmux_scroll_*`): the same
//! strips as cmux-layout-reducer's scroll tests, sent as typed C structs,
//! with string ids, the caller's spring, the reply's focus string, and the
//! refusals of a malformed request.

/// In a `scroll` module so the fleet filter `scroll::` selects these with the core tests.
mod scroll {
    use cmux_layout_reducer_ffi::scroll::*;

    /// A strip request built like the app builds it: one byte buffer of ids.
    #[derive(Default)]
    struct Request {
        bytes: Vec<u8>,
        columns: Vec<CmuxScrollColumn>,
        panes: Vec<CmuxScrollPane>,
    }

    fn rect(x: f64, y: f64, width: f64, height: f64) -> CmuxScrollRect {
        CmuxScrollRect { x, y, width, height }
    }

    impl Request {
        fn text(&mut self, name: &str) -> CmuxScrollStr {
            let offset = self.bytes.len() as u32;
            self.bytes.extend_from_slice(name.as_bytes());
            CmuxScrollStr { offset, len: name.len() as u32 }
        }

        fn column(
            &mut self,
            id: &str,
            frame: CmuxScrollRect,
            panes: &[(&str, Option<CmuxScrollRect>)],
        ) {
            let id = self.text(id);
            let pane_start = self.panes.len() as u32;
            for (pane, pane_frame) in panes {
                let id = self.text(pane);
                self.panes.push(CmuxScrollPane {
                    id,
                    frame: pane_frame.unwrap_or_default(),
                    has_frame: u8::from(pane_frame.is_some()),
                    listed: 1,
                    reserved: [0; 6],
                });
            }
            self.columns.push(CmuxScrollColumn {
                id,
                frame,
                pane_start,
                pane_count: panes.len() as u32,
            });
        }

        fn strip(&self, viewport: f64, content: f64, gap: f64) -> CmuxScrollStrip {
            CmuxScrollStrip {
                bytes: self.bytes.as_ptr(),
                columns: self.columns.as_ptr(),
                panes: self.panes.as_ptr(),
                bytes_len: self.bytes.len() as u32,
                column_count: self.columns.len() as u32,
                pane_count: self.panes.len() as u32,
                axis: 0,
                reserved: [0; 3],
                viewport_width: viewport,
                content_width: content,
                gap,
                leading_cover: 0.,
                trailing_cover: 0.,
                origin: 0.,
            }
        }
    }

    fn sync_of(focused: CmuxScrollStr, source: u8, animated: bool) -> CmuxScrollSync {
        CmuxScrollSync {
            focused,
            anchor: CmuxScrollStr::ABSENT,
            source,
            animated: u8::from(animated),
            reveals: 1,
            reserved: [0; 5],
        }
    }

    /// Four 400 pt columns c0...c3 (panes p0...p3) on a 1000 pt viewport, gap 8.
    fn four(focused: &str) -> (Request, CmuxScrollStr) {
        let mut request = Request::default();
        for index in 0..4 {
            let frame = rect(8. + index as f64 * 408., 0., 400., 600.);
            request.column(
                format!("c{index}").as_str(),
                frame,
                &[(format!("p{index}").as_str(), Some(frame))],
            );
        }
        let focused = request.text(focused);
        (request, focused)
    }

    fn sync_four(
        scroll: *mut Scroll,
        spring: &mut CmuxScrollSpring,
        focused: &str,
    ) -> CmuxScrollEffects {
        let (request, focused) = four(focused);
        let strip = request.strip(1000., 1640., 8.);
        let sync = sync_of(focused, 0, false);
        unsafe { cmux_scroll_sync(scroll, spring, &strip, &sync) }
    }

    fn bytes<'a>(pointer: *const u8, len: usize) -> &'a [u8] {
        if pointer.is_null() { &[] } else { unsafe { std::slice::from_raw_parts(pointer, len) } }
    }

    #[test]
    fn a_wheel_notch_scrolls_and_names_the_pane_it_focuses() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        assert_eq!(sync_four(scroll, &mut spring, "p0").ok, 1);
        assert_eq!(spring.value, 0.);
        let effects = unsafe { cmux_scroll_wheel(scroll, &mut spring, 1, 0) };
        assert_eq!(effects.ok, 1);
        assert_eq!(spring.value, 232.);
        assert_eq!(effects.has_focus, 1);
        assert_eq!(bytes(effects.focus, effects.focus_len), b"p2");
        assert_eq!(effects.report_on_settle, 1);
        let status = unsafe { cmux_scroll_status(scroll) };
        assert_eq!(bytes(status.focused_pane, status.focused_pane_len), b"p2");
        // The model's echo of that focus does not scroll.
        sync_four(scroll, &mut spring, "p2");
        assert_eq!(spring.target, 232.);
        unsafe { cmux_scroll_free(scroll) };
    }

    #[test]
    fn a_keyboard_focus_reveals_the_least_and_reads_the_callers_spring() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        sync_four(scroll, &mut spring, "p0");
        let (request, focused) = four("p2");
        let strip = request.strip(1000., 1640., 8.);
        let sync = sync_of(focused, 0, true);
        let effects = unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync) };
        assert_eq!((effects.ok, effects.needs_frames, effects.snapped), (1, 1, 0));
        assert_eq!((spring.value, spring.target), (0., 232.));
        // The caller stepped the spring; the next event starts from there.
        spring.value = 100.;
        spring.velocity = 500.;
        unsafe { cmux_scroll_gesture_began(scroll, &mut spring) };
        assert_eq!((spring.value, spring.velocity, spring.target), (100., 0., 100.));
        let status = unsafe { cmux_scroll_status(scroll) };
        assert_eq!((status.gesture_active, status.gesture_raw), (1, 100.));
        unsafe { cmux_scroll_free(scroll) };
    }

    #[test]
    fn a_gesture_flings_to_the_end_and_focuses_the_farthest_visible_column() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        sync_four(scroll, &mut spring, "p0");
        unsafe { cmux_scroll_gesture_began(scroll, &mut spring) };
        let mut time = 0.;
        for _ in 0..20 {
            time += 0.008;
            unsafe { cmux_scroll_gesture_changed(scroll, &mut spring, -32., time) };
        }
        assert_eq!(spring.value, 640.);
        let effects = unsafe { cmux_scroll_gesture_ended(scroll, &mut spring, time + 0.2, 0) };
        assert_eq!(spring.value, 640.);
        assert_eq!(bytes(effects.focus, effects.focus_len), b"p3");
        unsafe { cmux_scroll_free(scroll) };
    }

    #[test]
    fn a_reveal_beside_a_chat_keeps_the_chat_focused() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        let mut request = Request::default();
        for index in 0..3 {
            let frame = rect(index as f64 * 616., 0., 600., 800.);
            request.column(
                format!("c{index}").as_str(),
                frame,
                &[(format!("p{index}").as_str(), None)],
            );
        }
        let chat = request.text("chat");
        let mut strip = request.strip(1000., 3. * 616. - 16., 16.);
        strip.leading_cover = 400.;
        unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(chat, 2, false)) };
        let effects = unsafe { cmux_scroll_reveal(scroll, &mut spring, b"p2".as_ptr(), 2, 0) };
        assert_eq!(effects.ok, 1);
        assert!(spring.target + 400. <= 1232. + 0.5 && 1832. <= spring.target + 1000. + 0.5);
        let status = unsafe { cmux_scroll_status(scroll) };
        assert_eq!(bytes(status.focused_pane, status.focused_pane_len), b"chat");
        // An unknown pane is in no column: nothing changes.
        let before = spring;
        let effects = unsafe { cmux_scroll_center(scroll, &mut spring, b"nope".as_ptr(), 4, 0) };
        assert_eq!((effects.ok, effects.needs_frames), (1, 0));
        assert_eq!(spring, before);
        unsafe { cmux_scroll_free(scroll) };
    }

    #[test]
    fn a_rows_handle_transposes_the_stack() {
        let scroll = cmux_scroll_new(1);
        let mut spring = CmuxScrollSpring::default();
        let mut request = Request::default();
        for index in 0..3 {
            let frame = rect(0., 100. + index as f64 * 308., 500., 300.);
            request.column(
                format!("r{index}").as_str(),
                frame,
                &[(format!("p{index}").as_str(), Some(frame))],
            );
        }
        let focused = request.text("p2");
        let mut strip = request.strip(400., 916., 8.);
        strip.origin = 100.;
        let effects =
            unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(focused, 0, false)) };
        assert_eq!(effects.ok, 1);
        // r2 at 616...916 with its 8 pt padding, clamped to the 516 pt end.
        assert_eq!(spring.value, 516.);
        unsafe { cmux_scroll_free(scroll) };
    }

    #[test]
    fn an_area_handle_measures_from_the_window() {
        let scroll = cmux_scroll_new(2);
        let mut spring = CmuxScrollSpring::default();
        let mut request = Request::default();
        for index in 0..3 {
            let frame = rect(200. + index as f64 * 300., 0., 300., 800.);
            request.column("", frame, &[(format!("p{index}").as_str(), Some(frame))]);
        }
        let focused = request.text("p2");
        let mut strip = request.strip(400., 900., 0.);
        strip.origin = 200.;
        unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(focused, 0, false)) };
        assert_eq!(spring.value, 500.);
        unsafe { cmux_scroll_free(scroll) };
    }

    #[test]
    fn a_malformed_request_is_refused_and_changes_nothing() {
        assert!(cmux_scroll_new(9).is_null());
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring { value: 7., velocity: 1., target: 9. };
        let (mut request, focused) = four("p0");
        request.columns[1].id.len = 9_999;
        let strip = request.strip(1000., 1640., 8.);
        let effects =
            unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(focused, 0, false)) };
        assert_eq!(effects.ok, 0);
        let (mut request, focused) = four("p0");
        request.columns[3].pane_count = 5;
        let strip = request.strip(1000., 1640., 8.);
        assert_eq!(
            unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(focused, 0, false)) }
                .ok,
            0
        );
        let (request, focused) = four("p0");
        let strip = request.strip(1000., 1640., 8.);
        assert_eq!(
            unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(focused, 7, false)) }
                .ok,
            0
        );
        assert_eq!(spring, CmuxScrollSpring { value: 7., velocity: 1., target: 9. });
        assert_eq!(unsafe { cmux_scroll_status(scroll) }.has_strip, 0);
        assert_eq!(unsafe { cmux_scroll_wheel(std::ptr::null_mut(), &mut spring, 1, 0) }.ok, 0);
        assert_eq!(unsafe { cmux_scroll_wheel(scroll, std::ptr::null_mut(), 1, 0) }.ok, 0);
        assert_eq!(unsafe { cmux_scroll_status(std::ptr::null()) }.ok, 0);
        unsafe { cmux_scroll_free(scroll) };
    }

    /// Ids of panes long gone are forgotten, so a long session does not grow the table.
    #[test]
    fn the_id_table_forgets_ids_no_state_refers_to() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        for round in 0..400 {
            let mut request = Request::default();
            let frame = rect(8., 0., 400., 600.);
            request.column(
                format!("c{round}").as_str(),
                frame,
                &[(format!("p{round}").as_str(), Some(frame))],
            );
            let focused = request.text(&format!("p{round}"));
            let strip = request.strip(1000., 1000., 8.);
            assert_eq!(
                unsafe {
                    cmux_scroll_sync(scroll, &mut spring, &strip, &sync_of(focused, 2, false))
                }
                .ok,
                1
            );
        }
        let count = unsafe { &*scroll }.id_count();
        assert!(count <= 64 + 4 * 16, "the table keeps {count} ids");
        let status = unsafe { cmux_scroll_status(scroll) };
        assert_eq!(bytes(status.focused_pane, status.focused_pane_len), b"p399");
        unsafe { cmux_scroll_free(scroll) };
    }

    /// A clone is independent: events on one leave the other where it was.
    #[test]
    fn a_clone_is_an_independent_copy() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        sync_four(scroll, &mut spring, "p0");
        let copy = unsafe { cmux_scroll_clone(scroll) };
        assert!(!copy.is_null());
        let mut copy_spring = spring;
        unsafe { cmux_scroll_wheel(copy, &mut copy_spring, 1, 0) };
        let original = unsafe { cmux_scroll_status(scroll) };
        assert_eq!(bytes(original.focused_pane, original.focused_pane_len), b"p0");
        let copied = unsafe { cmux_scroll_status(copy) };
        assert_eq!(bytes(copied.focused_pane, copied.focused_pane_len), b"p2");
        assert!(unsafe { cmux_scroll_clone(std::ptr::null()) }.is_null());
        unsafe {
            cmux_scroll_free(copy);
            cmux_scroll_free(scroll);
        }
    }

    /// A named drag anchor the strip does not hold (a docked column) keeps the camera, as
    /// Swift's `anchor ?? focused` does: it never falls back to the focused column.
    #[test]
    fn an_anchor_outside_the_strip_never_falls_back_to_the_focused_column() {
        let scroll = cmux_scroll_new(0);
        let mut spring = CmuxScrollSpring::default();
        sync_four(scroll, &mut spring, "p3");
        let before = spring.value;
        assert_eq!(before, 640.);
        // A 300 pt column opens left of the focused c3; the anchor names a docked column.
        let mut request = Request::default();
        let widths = [400., 400., 300., 400., 400.];
        let mut x = 8.;
        for (index, width) in widths.iter().enumerate() {
            let frame = rect(x, 0., *width, 600.);
            let (column, pane) = if index == 2 {
                ("cn".to_owned(), "pn".to_owned())
            } else {
                let i = if index < 2 { index } else { index - 1 };
                (format!("c{i}"), format!("p{i}"))
            };
            request.column(column.as_str(), frame, &[(pane.as_str(), Some(frame))]);
            x += width + 8.;
        }
        let focused = request.text("p3");
        let anchor = request.text("dock-left");
        let strip = request.strip(1000., x, 8.);
        let mut sync = sync_of(focused, 2, false);
        sync.anchor = anchor;
        sync.reveals = 0;
        assert_eq!(unsafe { cmux_scroll_sync(scroll, &mut spring, &strip, &sync) }.ok, 1);
        assert_eq!(spring.value, before, "the camera followed the focused column");
        assert_eq!(unsafe { cmux_scroll_gesture_active(scroll) }, 0);
        unsafe { cmux_scroll_gesture_began(scroll, &mut spring) };
        assert_eq!(unsafe { cmux_scroll_gesture_active(scroll) }, 1);
        assert_eq!(unsafe { cmux_scroll_gesture_active(std::ptr::null()) }, 0);
        unsafe { cmux_scroll_free(scroll) };
    }
}

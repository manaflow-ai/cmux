//! The C ABI of the focus rules that moved from the macOS app's Swift
//! (rust-migration backlog A12): the close successors over the caller's u32
//! ids (`cmux_close_focus_*`), the window handle's Close Tab aim and address
//! bar memory, the typing tab in the reply, and the input invariant JSON
//! operations. The rules themselves are tested in cmux-focus-core
//! (tests/focus_rules); these prove the calls carry them.

/// Under `ported::` with the crate's ported rule tests, so one filter runs both.
mod ported {
    use cmux_focus_core::event::{FocusEvent, Source};
    use cmux_focus_core::state::{ExpectationKey, Target};
    use cmux_focus_core::topology::{Kind, Pane, Tab, Topology};
    use cmux_layout_reducer_ffi::close_focus::{
        cmux_close_focus_live_openers, cmux_close_focus_tab, cmux_close_focus_workspace,
    };
    use cmux_layout_reducer_ffi::focus::{
        CmuxFocusReply, CmuxFocusStr, Focus, NONE, cmux_focus_aims_at_emptied_pane,
        cmux_focus_frame_presented, cmux_focus_free, cmux_focus_new, cmux_focus_pane_emptied,
        cmux_focus_pane_moved,
    };
    use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
    use serde_json::{Value, json};

    fn tab(
        selected: u32,
        old: &[u32],
        surviving: &[u32],
        shown: &[u32],
        opener: &[(u32, u32)],
    ) -> u32 {
        let children: Vec<u32> = opener.iter().map(|(c, _)| *c).collect();
        let parents: Vec<u32> = opener.iter().map(|(_, p)| *p).collect();
        unsafe {
            cmux_close_focus_tab(
                selected,
                old.as_ptr(),
                old.len(),
                surviving.as_ptr(),
                surviving.len(),
                shown.as_ptr(),
                shown.len(),
                children.as_ptr(),
                parents.as_ptr(),
                opener.len(),
            )
        }
    }

    #[test]
    fn the_tab_successor_goes_back_to_the_opener_family() {
        // A=0 B=1 C=2: B opened by A closes; back to A, not the right neighbor.
        assert_eq!(tab(1, &[0, 1, 2], &[0, 2], &[0, 2], &[(1, 0)]), 0);
        // No relations: the next shown tab, else the previous one.
        assert_eq!(tab(1, &[0, 1, 2], &[0, 2], &[0, 2], &[]), 2);
        assert_eq!(tab(2, &[0, 1, 2], &[0, 1], &[0, 1], &[]), 1);
        // A hidden neighbor is skipped while a shown tab survives.
        assert_eq!(tab(1, &[0, 1, 2], &[0, 2], &[0], &[]), 0);
        // A surviving selection stays; none survives: none.
        assert_eq!(tab(0, &[0, 1], &[0], &[0], &[]), 0);
        assert_eq!(tab(0, &[0], &[], &[], &[]), NONE);
        // No selection: the first shown survivor.
        assert_eq!(tab(NONE, &[0, 1], &[0, 1], &[1], &[]), 1);
        // A null array with a count is refused.
        let refused = unsafe {
            cmux_close_focus_tab(
                0,
                std::ptr::null(),
                3,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                0,
            )
        };
        assert_eq!(refused, NONE);
    }

    fn workspace(shown: u32, old: &[u32], surviving: &[u32], orders: &[&[u32]]) -> u32 {
        let flat: Vec<u32> = orders.iter().flat_map(|o| o.iter().copied()).collect();
        let lengths: Vec<u32> = orders.iter().map(|o| o.len() as u32).collect();
        unsafe {
            cmux_close_focus_workspace(
                shown,
                old.as_ptr(),
                old.len(),
                surviving.as_ptr(),
                surviving.len(),
                flat.as_ptr(),
                lengths.as_ptr(),
                lengths.len(),
            )
        }
    }

    #[test]
    fn the_workspace_successor_follows_the_drawn_rows_first() {
        assert_eq!(workspace(2, &[0, 1, 2, 3], &[0, 1, 3], &[]), 3);
        assert_eq!(workspace(2, &[0, 1, 2, 3], &[0, 1, 3], &[&[2, 0, 1, 3]]), 0);
        assert_eq!(workspace(2, &[0, 1, 2, 3], &[0, 1, 3], &[&[0, 1], &[2, 9, 1]]), 1);
        assert_eq!(workspace(3, &[0, 1, 2, 3], &[0, 1, 2], &[]), 2);
        assert_eq!(workspace(0, &[0], &[], &[]), NONE);
    }

    #[test]
    fn live_openers_skip_tabs_that_left() {
        // B=1 opened by A=0, C=2 opened by B; B left: C takes A.
        let (children, parents, order) = ([1u32, 2], [0u32, 1], [0u32, 2]);
        let mut out = [7u32; 2];
        let code = unsafe {
            cmux_close_focus_live_openers(
                children.as_ptr(),
                parents.as_ptr(),
                2,
                order.as_ptr(),
                2,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(code, OK);
        assert_eq!(out, [NONE, 0]);
    }

    fn topology() -> Topology {
        Topology::new(
            Some("w".into()),
            vec![
                Pane {
                    id: "left".into(),
                    tabs: vec![Tab {
                        id: "t1".into(),
                        surface: None,
                        kind: Kind::Terminal,
                        terminal: None,
                    }],
                    selected: Some("t1".into()),
                },
                Pane {
                    id: "right".into(),
                    tabs: vec![
                        Tab { id: "a".into(), surface: None, kind: Kind::Browser, terminal: None },
                        Tab { id: "b".into(), surface: None, kind: Kind::Browser, terminal: None },
                    ],
                    selected: Some("a".into()),
                },
            ],
            Vec::new(),
        )
    }

    fn string(reply: &CmuxFocusReply, text: CmuxFocusStr) -> Option<String> {
        if text.offset == NONE {
            return None;
        }
        let bytes =
            unsafe { std::slice::from_raw_parts(reply.strings, reply.strings_len as usize) };
        let range = text.offset as usize..(text.offset + text.len) as usize;
        Some(String::from_utf8(bytes[range].to_vec()).unwrap())
    }

    #[test]
    fn the_handle_restores_a_tabs_address_bar_on_return() {
        let mut focus = Focus::new();
        focus.set_topology(topology());
        let select = |tab: &str, source| FocusEvent::SelectTab {
            pane: "right".into(),
            tab: tab.into(),
            workspace: None,
            source,
        };
        focus.send(&FocusEvent::FocusPane {
            pane: "right".into(),
            workspace: None,
            source: Source::Mouse,
        });
        focus.send(&FocusEvent::FocusTarget {
            target: Target::AddressBar {},
            source: Source::Keyboard,
        });
        // Leave tab a while its address bar has the keyboard, then come back.
        let reply = focus.send(&select("b", Source::Keyboard));
        assert_eq!((reply.omnibar_return, reply.returns_to_omnibar), (0, 0));
        let reply = focus.send(&select("a", Source::Mouse));
        assert_eq!(reply.omnibar_return, 1, "queue the return");
        let back =
            FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Programmatic };
        let reply = focus.send(&back);
        assert_eq!((reply.omnibar_return, reply.returns_to_omnibar), (0, 1));
        // A second identical request (Cmd-L) is no return.
        let reply = focus.send(&back);
        assert_eq!(reply.returns_to_omnibar, 0);
    }

    #[test]
    fn the_reply_names_the_typing_tab() {
        let mut focus = Focus::new();
        let reply = focus.set_topology(topology());
        // The first pane takes the focus: its terminal.
        assert_eq!(string(reply, reply.typing_tab).as_deref(), Some("t1"));
        focus.send(&FocusEvent::BeginIntent {});
        let generation = focus.state().generation;
        let reply = focus.send(&FocusEvent::Expect {
            key: ExpectationKey::Tab { id: "new".into() },
            target: Target::Content {},
            away_from: None,
            generation,
        });
        // A creation's new tab, on its way: keys typed now are for it.
        assert_eq!(string(reply, reply.typing_tab).as_deref(), Some("new"));
    }

    #[test]
    fn the_handle_aims_a_press_at_the_pane_on_screen() {
        let focus = cmux_focus_new();
        unsafe {
            (*focus).set_topology(topology());
            (*focus).send(&FocusEvent::FocusPane {
                pane: "right".into(),
                workspace: None,
                source: Source::Mouse,
            });
            let right = b"right";
            cmux_focus_pane_emptied(focus, right.as_ptr(), right.len(), 10.0, 1, 0);
            // The close moved the focus to `left`.
            (*focus).send(&FocusEvent::FocusPane {
                pane: "left".into(),
                workspace: None,
                source: Source::Keyboard,
            });
            let serial = cmux_focus_pane_moved(focus, right.as_ptr(), right.len(), 1);
            assert_ne!(serial, 0);
            // Before the frame that shows `left` was presented: aimed at `right`.
            assert_eq!(cmux_focus_aims_at_emptied_pane(focus, 10.01, 1, 0), 1);
            cmux_focus_frame_presented(focus, serial, 10.02);
            assert_eq!(cmux_focus_aims_at_emptied_pane(focus, 10.015, 1, 0), 1);
            // A fresh press after it closes in `left`.
            assert_eq!(cmux_focus_aims_at_emptied_pane(focus, 10.5, 1, 0), 0);
            cmux_focus_free(focus);
        }
    }

    fn call(operation: &std::ffi::CStr, request: &Value) -> Value {
        let request = serde_json::to_vec(request).unwrap();
        let mut output = vec![0u8; 1 << 16];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                operation.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        assert_eq!(code, OK, "{operation:?}");
        serde_json::from_slice(&output[..len]).unwrap()
    }

    fn model(pane: &str, generation: u64) -> Value {
        json!({
            "windowKey": true,
            "topology": {"workspace": "w", "panes": [{"id": "p1", "tabs": [{"id": "t1", "kind": "terminal"}], "selected": "t1"}], "screens": []},
            "pane": pane, "target": {"content": {}}, "overlays": [], "browserFocusMode": [], "generation": generation,
            "resolved": {"terminal": {"pane": "p1", "tab": "t1"}},
            "underlying": {"terminal": {"pane": "p1", "tab": "t1"}},
            "context": {"terminal": true, "browser": false, "agent": false}
        })
    }

    #[test]
    fn the_invariant_operations_answer_in_the_apps_shapes() {
        let step = call(
            c"focus_input_step",
            &json!({"old": model("p1", 3), "event": {"windowKey": {"_0": true}}, "new": model("p1", 2), "window": "w1"}),
        );
        assert_eq!(
            step,
            json!({"violations": [{"invariant": "T3", "window": "w1", "detail": "generation 3 -> 2"}]})
        );
        let observation = json!({
            "windows": [{
                "id": "w1", "model": model("p1", 3), "responder": {"content": {"pane": "p1"}},
                "isKey": true, "layoutFocus": "p1", "ghosttyFocused": ["t1"], "presented": {"p1": "t1"},
                "childWindowTabs": [], "hasSheet": false
            }],
            "keyWindow": {"window": {"_0": "w1"}}, "paletteOpen": false, "activeWindow": "w1",
            "context": {"terminal": true, "browser": false, "agent": false}
        });
        assert_eq!(
            call(c"focus_input_world", &observation),
            json!({"violations": [], "unsettled": []})
        );
        let debug = call(
            c"focus_debug_window",
            &json!({"resolved": {"terminal": {"pane": "p1", "tab": "t1"}}, "ghostty": ["t2"], "ownTabs": ["t1", "t2"], "isKey": true}),
        );
        assert_eq!(
            debug,
            json!({
                "expectedResponder": {"content": {"pane": "p1"}},
                "kind": "terminal",
                "ghosttyMismatch": "ghostty focused [\"t2\"] != [t1]"
            })
        );
    }
}

//! Floating pane placement: unit tests of each rule, and a property test that mixes float, put back, move, raise,
//! open and close against a second model of the rules. The seed is fixed and `PROPTEST_CASES` sets the case count
//! (`tests::property_config`).

use super::*;
use proptest::prelude::*;
use std::collections::BTreeMap;

fn frame(x: u32, y: u32, w: u32, h: u32) -> FloatFrame {
    FloatFrame { x, y, w, h }
}

fn entry(pane: u8, frame: FloatFrame) -> Floating<u8> {
    Floating { pane, frame }
}

fn panes_of(list: &[Floating<u8>]) -> Vec<u8> {
    list.iter().map(|entry| entry.pane).collect()
}

#[test]
fn a_frame_is_clamped_into_the_screen_size_first() {
    assert_eq!(frame(0, 0, 10, 2_000_000).clamped(), frame(0, 0, MIN_EXTENT, UNIT));
    assert_eq!(
        frame(900_000, 950_000, 300_000, 200_000).clamped(),
        frame(700_000, 800_000, 300_000, 200_000)
    );
    assert_eq!(
        frame(u32::MAX, u32::MAX, u32::MAX, 0).clamped(),
        frame(0, UNIT - MIN_EXTENT, UNIT, MIN_EXTENT)
    );
    let inside = frame(100_000, 200_000, 300_000, 400_000);
    assert_eq!(inside.clamped(), inside);
    assert!(inside.is_valid());
    assert!(!frame(900_000, 0, 300_000, 300_000).is_valid());
}

#[test]
fn a_frame_keeps_its_fractions_and_refuses_a_value_that_is_not_a_number() {
    let made = FloatFrame::from_fractions(0.25, 0.1, 0.5, 0.75).unwrap();
    assert_eq!(made, frame(250_000, 100_000, 500_000, 750_000));
    assert_eq!(made.fractions(), [0.25, 0.1, 0.5, 0.75]);
    assert_eq!(
        FloatFrame::from_fractions(-3.0, 7.0, 0.5, 0.5).unwrap(),
        frame(0, 500_000, 500_000, 500_000)
    );
    assert_eq!(FloatFrame::from_fractions(f64::NAN, 0.0, 0.5, 0.5), None);
    assert_eq!(FloatFrame::from_fractions(0.0, 0.0, f64::INFINITY, 0.5), None);
    assert_eq!(
        FloatFrame::centered(NEW_EXTENT, 400_000),
        frame(200_000, 300_000, 600_000, 400_000)
    );
}

#[test]
fn toggle_floats_a_tiled_pane_at_the_front_and_puts_it_back() {
    let panes = [1u8, 2, 3];
    let one = place(&panes, &[], &2, FloatMode::Toggle, None).unwrap();
    assert_eq!(one, vec![entry(2, frame(200_000, 200_000, NEW_EXTENT, NEW_EXTENT))]);
    assert_eq!(tiled(&panes, &one), vec![1, 3]);

    let two = place(&panes, &one, &1, FloatMode::On, Some(frame(0, 0, 300_000, 300_000))).unwrap();
    assert_eq!(panes_of(&two), vec![2, 1], "the newest floating pane is the front pane");
    assert_eq!(tiled(&panes, &two), vec![3]);

    let back = place(&panes, &two, &2, FloatMode::Toggle, None).unwrap();
    assert_eq!(back, vec![entry(1, frame(0, 0, 300_000, 300_000))]);
    assert_eq!(place(&panes, &back, &1, FloatMode::Off, None).unwrap(), vec![]);
}

#[test]
fn the_last_tiled_pane_does_not_float() {
    assert_eq!(place(&[1u8], &[], &1, FloatMode::Toggle, None), Err(FloatRefusal::LastTiledPane));
    let panes = [1u8, 2, 3];
    let list = [entry(1, frame(0, 0, 300_000, 300_000)), entry(3, frame(0, 0, 400_000, 400_000))];
    assert_eq!(place(&panes, &list, &2, FloatMode::On, None), Err(FloatRefusal::LastTiledPane));
    assert_eq!(place(&panes, &list, &2, FloatMode::Toggle, None), Err(FloatRefusal::LastTiledPane));
    assert_eq!(place(&panes, &list, &2, FloatMode::Off, None).unwrap(), list.to_vec());
}

#[test]
fn a_pane_of_another_screen_is_refused() {
    let list = [entry(1, frame(0, 0, 300_000, 300_000))];
    for mode in [FloatMode::Toggle, FloatMode::On, FloatMode::Off] {
        assert_eq!(place(&[1u8, 2], &list, &9, mode, None), Err(FloatRefusal::UnknownPane));
    }
}

#[test]
fn a_frame_for_a_floating_pane_moves_it_and_brings_it_to_the_front() {
    let panes = [1u8, 2, 3, 4];
    let list = [
        entry(1, frame(0, 0, 300_000, 300_000)),
        entry(2, frame(100_000, 100_000, 300_000, 300_000)),
        entry(3, frame(200_000, 200_000, 300_000, 300_000)),
    ];
    let moved =
        place(&panes, &list, &1, FloatMode::On, Some(frame(950_000, 0, 500_000, 100_000))).unwrap();
    assert_eq!(
        moved,
        vec![list[1], list[2], entry(1, frame(500_000, 0, 500_000, MIN_EXTENT))],
        "the frame is clamped and the pane is the front pane; the other entries keep their order"
    );
    let front = place(&panes, &moved, &2, FloatMode::On, None).unwrap();
    assert_eq!(panes_of(&front), vec![3, 1, 2]);
    assert_eq!(front[2].frame, list[1].frame, "no frame: the pane keeps its frame");
    assert_eq!(raised(&panes, &front, &3), vec![front[1], front[2], front[0]]);
    assert_eq!(raised(&panes, &front, &4), front, "a tiled pane changes nothing");
}

#[test]
fn a_new_floating_pane_does_not_hide_the_one_before_it() {
    let panes: Vec<u8> = (0..12).collect();
    let mut list = Vec::new();
    for pane in 1..=8u8 {
        list = place(&panes, &list, &pane, FloatMode::On, None).unwrap();
    }
    let corners: Vec<u32> = list.iter().map(|entry| entry.frame.x).collect();
    assert_eq!(
        corners,
        vec![200_000, 230_000, 260_000, 290_000, 320_000, 350_000, 380_000, 200_000],
        "seven places, then the first place again"
    );
    for entry in &list {
        assert_eq!(entry.frame.x, entry.frame.y);
        assert_eq!((entry.frame.w, entry.frame.h), (NEW_EXTENT, NEW_EXTENT));
        assert!(entry.frame.is_valid());
    }
    let reused = place(&panes, &list[..2], &1, FloatMode::Off, None).unwrap();
    assert_eq!(new_frame(&reused).x, 200_000, "a place that is free again is taken first");
}

#[test]
fn a_place_is_taken_by_a_corner_at_its_x_and_its_y_only() {
    let base = FloatFrame::centered(NEW_EXTENT, NEW_EXTENT);
    // One pane at the same x with another y, and one at the same y with another x: the first place is free.
    let list = [entry(1, FloatFrame { y: 0, ..base }), entry(2, FloatFrame { x: 0, ..base })];
    assert_eq!(new_frame(&list), base);
    let next = FloatFrame { x: base.x + CASCADE_STEP, y: base.y + CASCADE_STEP, ..base };
    assert_eq!(new_frame(&[entry(1, base)]), next);
}

#[test]
fn the_list_follows_the_panes_of_the_screen() {
    let a = frame(0, 0, 300_000, 300_000);
    let b = frame(100_000, 100_000, 300_000, 300_000);
    let wide = frame(900_000, 900_000, 5_000_000, 1);
    let list = [entry(1, a), entry(7, b), entry(2, wide), entry(1, b), entry(3, b)];
    assert_eq!(
        normalized(&[1u8, 2, 3, 4], &list),
        vec![entry(1, a), entry(2, frame(0, 850_000, UNIT, MIN_EXTENT)), entry(3, b)],
        "a pane that left, a second entry of one pane and a frame out of the screen"
    );
    assert!(!is_normal(&[1u8, 2, 3, 4], &list));
    assert!(is_normal(&[1u8, 2, 3, 4], &normalized(&[1u8, 2, 3, 4], &list)));

    // The last tiled pane (4) closes: the front floating pane (3) becomes tiled.
    assert_eq!(panes_of(&normalized(&[1u8, 2, 3], &list)), vec![1, 2]);
    assert_eq!(tiled(&[1u8, 2, 3], &list), vec![3]);
    // Then 3 closes too: 2 is the front pane now, and it becomes tiled.
    assert_eq!(panes_of(&normalized(&[1u8, 2], &list)), vec![1]);
    assert_eq!(normalized(&[1u8], &list), vec![]);
    assert_eq!(normalized(&[] as &[u8], &list), vec![]);
}

#[test]
fn a_mode_has_one_wire_name() {
    for mode in [FloatMode::Toggle, FloatMode::On, FloatMode::Off] {
        assert_eq!(FloatMode::parse(mode.as_str()), Some(mode));
    }
    assert_eq!(FloatMode::parse("float"), None);
    // The names leave the process, so each is held as text.
    assert_eq!(FloatMode::Toggle.as_str(), "toggle");
    assert_eq!(FloatMode::On.as_str(), "on");
    assert_eq!(FloatMode::Off.as_str(), "off");
}

fn quick(pane: u8, frame: FloatFrame, hidden: bool, from: Option<u8>) -> Floating<u8> {
    Floating { pane, frame, quick: Some(Quick { hidden, from }) }
}

#[test]
fn a_quick_mode_has_one_wire_name() {
    for mode in [QuickMode::Toggle, QuickMode::Show, QuickMode::Hide] {
        assert_eq!(QuickMode::parse(mode.as_str()), Some(mode));
    }
    assert_eq!(QuickMode::parse("on"), None);
    // The names leave the process, so each is held as text.
    assert_eq!(QuickMode::Toggle.as_str(), "toggle");
    assert_eq!(QuickMode::Show.as_str(), "show");
    assert_eq!(QuickMode::Hide.as_str(), "hide");
}

#[test]
fn a_request_for_the_quick_terminal_has_one_act_for_each_state() {
    let place = frame(550_000, 550_000, 450_000, 450_000);
    let none = [entry(2, place)];
    let hidden = [quick(3, place, true, Some(1)), entry(2, place)];
    let shown = [entry(2, place), quick(3, place, false, Some(1))];
    // (the list, the pane with the focus, the act of a toggle, of a show, of a hide)
    let table = [
        (&none[..], 1u8, QuickAct::Make, QuickAct::Make, QuickAct::Nothing),
        (&hidden[..], 1, QuickAct::Show, QuickAct::Show, QuickAct::Nothing),
        (&shown[..], 3, QuickAct::Hide, QuickAct::Nothing, QuickAct::Hide),
        (&shown[..], 1, QuickAct::Show, QuickAct::Show, QuickAct::Hide),
    ];
    for (list, active, toggle, show, hide) in table {
        assert_eq!(
            quick_act(list, QuickMode::Toggle, &active),
            toggle,
            "toggle, focus on {active}"
        );
        assert_eq!(quick_act(list, QuickMode::Show, &active), show, "show, focus on {active}");
        assert_eq!(quick_act(list, QuickMode::Hide, &active), hide, "hide, focus on {active}");
    }
}

#[test]
fn the_mark_of_the_quick_terminal_follows_its_entry() {
    let place = frame(550_000, 550_000, 450_000, 450_000);
    let panes = [1u8, 2, 3];
    let floating = [entry(2, place), entry(3, place)];
    // The mark goes on a floating pane, one time, and names no pane that is its own or not on the screen.
    let marked_list = marked(&panes, &floating, &3, Some(&1));
    assert_eq!(marked_list, vec![entry(2, place), quick(3, place, false, Some(1))]);
    assert_eq!(marked(&panes, &marked_list, &2, Some(&1)), marked_list);
    assert_eq!(marked(&panes, &floating, &1, None), floating.to_vec());
    assert_eq!(
        marked(&panes, &floating, &3, Some(&3)),
        vec![entry(2, place), quick(3, place, false, None)]
    );
    assert_eq!(
        marked(&panes, &floating, &3, Some(&9)),
        vec![entry(2, place), quick(3, place, false, None)]
    );
    // A hide puts the entry at the back and keeps its frame and its `from`.
    let hidden_list = hidden(&panes, &marked_list);
    assert_eq!(hidden_list, vec![quick(3, place, true, Some(1)), entry(2, place)]);
    assert_eq!(hidden(&panes, &floating), floating.to_vec());
    // A focus of it shows it, at the front, and its `from` is the pane that had the focus.
    let mut focused = hidden_list.clone();
    focus_moved(&mut focused, &3, &2);
    assert_eq!(focused, vec![entry(2, place), quick(3, place, false, Some(2))]);
    // A raise shows it and keeps its `from`; a second mark of a list is dropped.
    assert_eq!(raised(&panes, &hidden_list, &3), marked_list);
    let two = [quick(2, place, false, None), quick(3, place, true, Some(1))];
    assert_eq!(normalized(&panes, &two), vec![quick(2, place, false, None), entry(3, place)]);
    // The pane that `from` names closes: the mark names no pane. The quick terminal goes back into the tiled
    // layout: the mark ends.
    assert_eq!(
        normalized(&[2u8, 3, 4], &hidden_list),
        vec![quick(3, place, true, None), entry(2, place)]
    );
    assert_eq!(place_off(&panes, &marked_list, 3), vec![entry(2, place)]);
}

fn place_off(panes: &[u8], list: &[Floating<u8>], pane: u8) -> Vec<Floating<u8>> {
    place(panes, list, &pane, FloatMode::Off, None).unwrap_or_default()
}

#[test]
fn a_list_that_breaks_the_rules_is_restored_before_an_act() {
    let first = frame(0, 0, 300_000, 300_000);
    let second = frame(100_000, 100_000, 300_000, 300_000);
    // Pane 9 is not on the screen, and pane 1 has two entries.
    let list = [entry(1, first), entry(9, second), entry(1, second)];
    assert_eq!(place(&[1u8, 2, 3], &list, &2, FloatMode::Off, None), Ok(vec![entry(1, first)]));
    assert_eq!(raised(&[1u8, 2, 3], &list, &1), vec![entry(1, first)]);
    assert_eq!(raised(&[1u8, 2, 3], &list, &2), vec![entry(1, first)]);
}

/// One act of the property test. `pane` picks a pane of the screen by index; one index past the end names a pane
/// that is not on the screen.
#[derive(Clone, Debug)]
enum Act {
    Place { pane: usize, mode: FloatMode, frame: Option<FloatFrame> },
    Raise { pane: usize },
    Open,
    Close { pane: usize },
}

fn any_frame() -> impl Strategy<Value = FloatFrame> {
    (0u32..=1_300_000, 0u32..=1_300_000, 0u32..=1_300_000, 0u32..=1_300_000)
        .prop_map(|(x, y, w, h)| FloatFrame { x, y, w, h })
}

fn any_act() -> impl Strategy<Value = Act> {
    let mode = prop_oneof![Just(FloatMode::Toggle), Just(FloatMode::On), Just(FloatMode::Off)];
    prop_oneof![
        4 => (any::<usize>(), mode, proptest::option::of(any_frame()))
            .prop_map(|(pane, mode, frame)| Act::Place { pane, mode, frame }),
        1 => any::<usize>().prop_map(|pane| Act::Raise { pane }),
        1 => Just(Act::Open),
        1 => any::<usize>().prop_map(|pane| Act::Close { pane }),
    ]
}

/// The second model: each floating pane with its frame and the count of the act that last brought it to the front.
/// It keeps no list; the order is the order of the counts.
#[derive(Default)]
struct Oracle {
    floating: BTreeMap<u8, (FloatFrame, u64)>,
    clock: u64,
}

impl Oracle {
    fn stamp(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }

    /// F3 in 64 bits, the size before the corner, with no `clamp` and no `min`.
    fn fit(frame: FloatFrame) -> FloatFrame {
        let size = |extent: u32| {
            let extent = u64::from(extent);
            if extent < u64::from(MIN_EXTENT) {
                u64::from(MIN_EXTENT)
            } else if extent > u64::from(UNIT) {
                u64::from(UNIT)
            } else {
                extent
            }
        };
        let corner = |at: u32, extent: u64| {
            if u64::from(at) + extent > u64::from(UNIT) {
                u64::from(UNIT) - extent
            } else {
                u64::from(at)
            }
        };
        let (w, h) = (size(frame.w), size(frame.h));
        FloatFrame {
            x: corner(frame.x, w) as u32,
            y: corner(frame.y, h) as u32,
            w: w as u32,
            h: h as u32,
        }
    }

    fn fresh(&self) -> FloatFrame {
        let corners: Vec<(u32, u32)> =
            self.floating.values().map(|(frame, _)| (frame.x, frame.y)).collect();
        let at = (0..7u32)
            .map(|step| 200_000 + 30_000 * step)
            .find(|at| !corners.contains(&(*at, *at)))
            .unwrap_or(200_000);
        FloatFrame { x: at, y: at, w: 600_000, h: 600_000 }
    }

    fn place(
        &mut self,
        panes: &[u8],
        pane: u8,
        mode: FloatMode,
        frame: Option<FloatFrame>,
    ) -> Result<(), FloatRefusal> {
        if !panes.contains(&pane) {
            return Err(FloatRefusal::UnknownPane);
        }
        let floats = self.floating.contains_key(&pane);
        let wanted = match mode {
            FloatMode::Toggle => !floats,
            FloatMode::On => true,
            FloatMode::Off => false,
        };
        if floats && !wanted {
            self.floating.remove(&pane);
        } else if floats {
            let stamp = self.stamp();
            let old = self.floating[&pane].0;
            self.floating.insert(pane, (frame.map_or(old, Oracle::fit), stamp));
        } else if wanted {
            if self.floating.len() + 1 >= panes.len() {
                return Err(FloatRefusal::LastTiledPane);
            }
            let made = frame.map_or_else(|| self.fresh(), Oracle::fit);
            let stamp = self.stamp();
            self.floating.insert(pane, (made, stamp));
        }
        Ok(())
    }

    fn raise(&mut self, pane: u8) {
        if self.floating.contains_key(&pane) {
            let stamp = self.stamp();
            let old = self.floating[&pane].0;
            self.floating.insert(pane, (old, stamp));
        }
    }

    fn close(&mut self, panes: &[u8], pane: u8) {
        self.floating.remove(&pane);
        while !self.floating.is_empty() && self.floating.len() >= panes.len() {
            let front =
                self.floating.iter().max_by_key(|(_, (_, stamp))| *stamp).map(|(pane, _)| *pane);
            if let Some(front) = front {
                self.floating.remove(&front);
            }
        }
    }

    fn list(&self) -> Vec<Floating<u8>> {
        let mut entries: Vec<(u64, Floating<u8>)> = self
            .floating
            .iter()
            .map(|(pane, (frame, stamp))| (*stamp, Floating { pane: *pane, frame: *frame }))
            .collect();
        entries.sort_by_key(|(stamp, _)| *stamp);
        entries.into_iter().map(|(_, entry)| entry).collect()
    }
}

/// The pane at `index`, counted round the panes of the screen and one pane (250) that is not on the screen.
fn pick(panes: &[u8], index: usize) -> u8 {
    panes.get(index % (panes.len() + 1)).copied().unwrap_or(250)
}

proptest! {
    #![proptest_config(crate::tests::property_config())]

    /// Any mix of the acts keeps F1 to F4, and gives the list the second model gives.
    #[test]
    fn any_mix_of_acts_keeps_the_rules(
        start in 1usize..=6,
        acts in proptest::collection::vec(any_act(), 0..60),
    ) {
        let mut panes: Vec<u8> = (0..start as u8).collect();
        let mut next_pane = start as u8;
        let mut list: Vec<Floating<u8>> = Vec::new();
        let mut oracle = Oracle::default();
        for act in acts {
            match act {
                Act::Place { pane, mode, frame } => {
                    let pane = pick(&panes, pane);
                    let expected = oracle.place(&panes, pane, mode, frame);
                    match place(&panes, &list, &pane, mode, frame) {
                        Ok(next) => {
                            prop_assert_eq!(expected, Ok(()));
                            list = next;
                        }
                        Err(refusal) => {
                            prop_assert_eq!(expected, Err(refusal));
                        }
                    }
                }
                Act::Raise { pane } => {
                    let pane = pick(&panes, pane);
                    oracle.raise(pane);
                    list = raised(&panes, &list, &pane);
                }
                Act::Open => {
                    if panes.len() < 12 {
                        panes.push(next_pane);
                        next_pane += 1;
                    }
                    list = normalized(&panes, &list);
                }
                Act::Close { pane } => {
                    let pane = pick(&panes, pane);
                    panes.retain(|open| *open != pane);
                    oracle.close(&panes, pane);
                    list = normalized(&panes, &list);
                }
            }
            prop_assert_eq!(&list, &oracle.list());
            prop_assert!(is_normal(&panes, &list));
            prop_assert!(list.iter().all(|entry| entry.frame.is_valid()));
            let ground = tiled(&panes, &list);
            prop_assert_eq!(ground.len() + list.len(), panes.len());
            prop_assert!(panes.is_empty() || !ground.is_empty(), "a screen with a pane has a tiled pane");
            prop_assert!(ground.iter().all(|pane| !list.iter().any(|entry| entry.pane == *pane)));
        }
    }
}

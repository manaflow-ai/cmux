//! `queue_fold.rs`: every send mode, against the rule `take_joined` had before it was one machine.

use super::*;

/// `take_joined`'s head rule as it was: `Some(person)` when the head leads a batch.
fn old_lead(h: Head) -> Option<bool> {
    let person = !h.from_agent && h.person_fold;
    let notice = h.notice && !person && h.cold_batch;
    if (!h.from_agent && !person && !notice) || h.alone.is_some() || h.review_box {
        return None;
    }
    Some(person)
}

/// `take_joined`'s queue walk as it was, for one prompt: `Some(true)` joins, `Some(false)` stops,
/// `None` skips.
fn old_step(person: bool, f: Flags, n: Next) -> Option<bool> {
    if f.held || f.awaiting_owner {
        return None;
    }
    let joins = n.from_agent != person
        && n.alone.is_none()
        && !f.unclaimed
        && !f.steer
        && !f.sent_now
        && n.same_rules;
    Some(joins && n.fits)
}

fn alones() -> Vec<Option<Alone>> {
    std::iter::once(None).chain(Alone::ALL.into_iter().map(Some)).collect()
}

fn every_flags() -> Vec<Flags> {
    (0u8..64)
        .map(|b| Flags {
            held: b & 1 != 0,
            awaiting_owner: b & 2 != 0,
            unclaimed: b & 4 != 0,
            steer: b & 8 != 0,
            sent_now: b & 16 != 0,
            steer_on_start: b & 32 != 0,
        })
        .collect()
}

#[test]
fn every_head_leads_as_before() {
    let head_alones = [None, Some(Alone::Trigger), Some(Alone::SlashCommand), Some(Alone::Uploads)];
    for b in 0u8..32 {
        for alone in head_alones {
            let h = Head {
                from_agent: b & 1 != 0,
                notice: b & 2 != 0,
                person_fold: b & 4 != 0 && b & 1 == 0,
                cold_batch: b & 8 != 0,
                alone,
                review_box: b & 16 != 0,
            };
            let got = lead(h).ok().map(|l| l == Lead::Person);
            assert_eq!(got, old_lead(h), "{h:?}");
        }
    }
}

#[test]
fn every_send_mode_joins_as_before() {
    for lead in [Lead::Person, Lead::Agents] {
        for f in every_flags() {
            for alone in alones() {
                for b in 0u8..8 {
                    let n = Next {
                        mode: Mode::of(f),
                        from_agent: b & 1 != 0,
                        alone,
                        same_rules: b & 2 != 0,
                        fits: b & 4 != 0,
                    };
                    let got = match step(lead, n) {
                        Step::Join => Some(true),
                        Step::End(_) => Some(false),
                        Step::Skip => None,
                    };
                    assert_eq!(got, old_step(lead == Lead::Person, f, n), "{lead:?} {f:?} {n:?}");
                }
            }
        }
    }
}

/// A plain prompt of `lead`'s side in `mode`.
fn plain(lead: Lead, mode: Mode) -> Next {
    Next { mode, from_agent: lead == Lead::Agents, alone: None, same_rules: true, fits: true }
}

#[test]
fn each_send_mode_has_one_outcome() {
    for lead in [Lead::Person, Lead::Agents] {
        for mode in Mode::ALL {
            let want = match mode {
                // Queued for after the turn, or a steer that waited for a turn to show: it goes
                // in with the batch.
                Mode::Waiting | Mode::SteerOnStart => Step::Join,
                // Set aside: the batch goes on past it and it keeps its place.
                Mode::Held | Mode::AwaitingOwner => Step::Skip,
                // Sent some other way: the batch stops so nothing behind it overtakes it.
                Mode::SteerNow | Mode::SentNow | Mode::Unclaimed => Step::End(End::Mode(mode)),
            };
            assert_eq!(step(lead, plain(lead, mode)), want, "{lead:?} {mode:?}");
        }
    }
}

#[test]
fn a_batch_never_crosses_senders_or_rules() {
    for lead in [Lead::Person, Lead::Agents] {
        let mut other = plain(lead, Mode::Waiting);
        other.from_agent = !other.from_agent;
        assert_eq!(step(lead, other), Step::End(End::OtherSender));
        for a in Alone::ALL {
            let n = Next { alone: Some(a), ..plain(lead, Mode::Waiting) };
            assert_eq!(step(lead, n), Step::End(End::Alone(a)));
        }
        let n = Next { same_rules: false, ..plain(lead, Mode::Waiting) };
        assert_eq!(step(lead, n), Step::End(End::OtherRules));
        let n = Next { fits: false, ..plain(lead, Mode::Waiting) };
        assert_eq!(step(lead, n), Step::End(End::TooBig));
    }
}

#[test]
fn set_aside_comes_before_every_other_flag() {
    for f in every_flags() {
        let mode = Mode::of(f);
        assert_eq!(
            matches!(mode, Mode::Held | Mode::AwaitingOwner),
            f.held || f.awaiting_owner,
            "{f:?}"
        );
    }
    assert_eq!(Mode::of(Flags { held: true, steer: true, ..Flags::default() }), Mode::Held);
    assert_eq!(Mode::of(Flags::default()), Mode::Waiting);
}

#[test]
fn the_person_runs_alone_outside_a_hold() {
    let h = Head {
        from_agent: false,
        notice: false,
        person_fold: false,
        cold_batch: false,
        alone: None,
        review_box: false,
    };
    assert_eq!(lead(h), Err(NoLead::PersonUnheld));
    assert_eq!(lead(Head { person_fold: true, ..h }), Ok(Lead::Person));
    assert_eq!(lead(Head { notice: true, ..h }), Err(NoLead::NoticeOutsideBatch));
    assert_eq!(lead(Head { notice: true, cold_batch: true, ..h }), Ok(Lead::Agents));
    assert_eq!(lead(Head { from_agent: true, ..h }), Ok(Lead::Agents));
    assert_eq!(lead(Head { from_agent: true, review_box: true, ..h }), Err(NoLead::ReviewBox));
}

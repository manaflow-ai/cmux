//! Tests only: the rules of an earlier head that a review of the journal restore found losing
//! prompts or history, for the tests and the move simulation to replay (moved from
//! `hub/journal_restore.rs`, so the store's cut of a journal, `store/compact.rs`, reads them
//! without reaching into the hub). A hub replays them per hub (`Hub::at_*`); the store and the
//! copies replay them per thread (`rules_of_*`). In a build every one is off.

/// Tests only: the rules of an earlier head, which a review of #37284 found losing prompts or
/// history, for the tests and the move simulation to replay (0: the rules of now). Each later
/// head's fixes are missing from an earlier one too. 918d2403's: the twenty-fifth review's F1
/// and F2.
pub(crate) const AT_918D: u8 = 1;
/// 27f3761b's (the twenty-fourth review's F1 is missing too).
pub(crate) const AT_27F3: u8 = 2;
/// b7496c3f's (the twenty-third review's F1 and F2 are missing too).
pub(crate) const AT_B749: u8 = 3;
/// fd33a65b's (the twenty-second review's F1 and F2 are missing too).
pub(crate) const AT_FD33: u8 = 4;
/// 4bce04df's (the twenty-first review's F1 and F2 are missing too).
pub(crate) const AT_4BCE: u8 = 5;
/// c4a1c13b's (the twentieth review's F1 is missing too).
pub(crate) const AT_C4A1: u8 = 6;
/// 8b5f3063's (the nineteenth review's F1 to F3 are missing too).
pub(crate) const AT_8B5F: u8 = 7;
/// 77f91e5a's (the eighteenth review's F1 is missing too).
pub(crate) const AT_77F9: u8 = 8;
/// a088585e's (the sixteenth review's F1 to F3 are missing too).
pub(crate) const AT_A088: u8 = 9;
/// 07f76930's (the fourteenth review's F1 and F2 are missing too).
pub(crate) const AT_07F7: u8 = 10;
/// ff3da306's (the twelfth review's F1 and F2 are missing too).
pub(crate) const AT_FF3D: u8 = 11;
/// c4a6f4e7's (the eleventh review's F1 to F3 are missing too).
pub(crate) const AT_C4A6: u8 = 12;
/// 4dcbe192's (the tenth review's F1 to F6 are missing too).
pub(crate) const AT_4DCB: u8 = 13;
/// 91b1343d's (the ninth review's F1 to F5 are missing too).
pub(crate) const AT_91B: u8 = 14;

#[cfg(test)]
thread_local! {
    /// Tests only: the rules this thread replays ([`AT_A088`] and earlier; 0: now).
    pub(crate) static OLD_RULES: std::cell::Cell<u8> = const { std::cell::Cell::new(0) };
}

fn thread_rules() -> u8 {
    #[cfg(test)]
    {
        OLD_RULES.with(std::cell::Cell::get)
    }
    #[cfg(not(test))]
    {
        0
    }
}

/// Whether this thread replays the rules of 91b1343d (tests only; never in a build): the
/// copies' store and the restore's merge, which tests drive on their own thread.
pub(crate) fn rules_of_91b() -> bool {
    thread_rules() >= AT_91B
}

/// Whether this thread replays the rules of 918d2403 (tests only; never in a build).
pub(crate) fn rules_of_918d() -> bool {
    thread_rules() >= AT_918D
}

/// Whether this thread replays the rules of 27f3761b (tests only; never in a build).
pub(crate) fn rules_of_27f3() -> bool {
    thread_rules() >= AT_27F3
}

/// Whether this thread replays the rules of b7496c3f (tests only; never in a build): the
/// store's cut of a journal (`store/compact.rs`), which runs on the restore's thread.
pub(crate) fn rules_of_b749() -> bool {
    thread_rules() >= AT_B749
}

/// Whether this thread replays the rules of fd33a65b (tests only; never in a build).
pub(crate) fn rules_of_fd33() -> bool {
    thread_rules() >= AT_FD33
}

/// Whether this thread replays the rules of 4bce04df (tests only; never in a build).
pub(crate) fn rules_of_4bce() -> bool {
    thread_rules() >= AT_4BCE
}

/// Whether this thread replays the rules of c4a1c13b (tests only; never in a build).
pub(crate) fn rules_of_c4a1() -> bool {
    thread_rules() >= AT_C4A1
}

/// Whether this thread replays the rules of 8b5f3063 (tests only; never in a build).
pub(crate) fn rules_of_8b5f() -> bool {
    thread_rules() >= AT_8B5F
}

/// Whether this thread replays the rules of 77f91e5a (tests only; never in a build).
pub(crate) fn rules_of_77f9() -> bool {
    thread_rules() >= AT_77F9
}

/// Whether this thread replays the rules of a088585e (tests only; never in a build).
pub(crate) fn rules_of_a088() -> bool {
    thread_rules() >= AT_A088
}

/// Whether this thread replays the rules of 07f76930 (tests only; never in a build).
pub(crate) fn rules_of_07f7() -> bool {
    thread_rules() >= AT_07F7
}

/// Whether this thread replays the rules of 4dcbe192 (tests only; never in a build).
pub(crate) fn rules_of_4dcb() -> bool {
    thread_rules() >= AT_4DCB
}

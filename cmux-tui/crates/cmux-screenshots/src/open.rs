//! What a `screenshots.open` run is told (Swift `ScreenshotsOpen`): only the person's own run
//! brings the Screenshots tab to the front, and it is told nothing; any other run opens the tab
//! behind and says so, even when it asked for focus. The app words the notes.

/// How the tab was opened for a run that is not the person's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Opened {
    /// A new tab, opened behind.
    Background,
    /// The tab was already there.
    Existing,
}

/// The note a run that is not the person's hears.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Note {
    /// The tab opened in the background.
    OpenedInBackground,
    /// The tab is open but lists nothing until the person clicks Show Screenshots.
    ExistingNeedsClick,
}

/// What a run is told.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Answer {
    /// How the tab was opened.
    pub opened: Opened,
    /// Whether the tab lists its screenshots.
    pub listing: bool,
    /// What the run hears, if anything.
    pub note: Option<Note>,
}

/// What a run is told once the tab is open: nothing for the person's own run; for any other, how
/// the tab opened (`existing`: it was already there), whether it lists, and the note.
pub const fn answer(persons_run: bool, existing: bool, listing: bool) -> Option<Answer> {
    if persons_run {
        return None;
    }
    if !existing {
        return Some(Answer {
            opened: Opened::Background,
            listing: false,
            note: Some(Note::OpenedInBackground),
        });
    }
    Some(Answer {
        opened: Opened::Existing,
        listing,
        note: if listing { None } else { Some(Note::ExistingNeedsClick) },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_persons_run_selects_and_every_other_run_is_told() {
        assert_eq!(answer(true, false, false), None);
        assert_eq!(answer(true, true, true), None);
        assert_eq!(
            answer(false, false, true),
            Some(Answer {
                opened: Opened::Background,
                listing: false,
                note: Some(Note::OpenedInBackground)
            })
        );
        assert_eq!(
            answer(false, true, true),
            Some(Answer { opened: Opened::Existing, listing: true, note: None })
        );
        assert_eq!(
            answer(false, true, false),
            Some(Answer {
                opened: Opened::Existing,
                listing: false,
                note: Some(Note::ExistingNeedsClick)
            })
        );
    }
}

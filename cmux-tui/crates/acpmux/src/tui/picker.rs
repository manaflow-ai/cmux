//! Part of the TUI `App`; see `tui/mod.rs`.

use super::*;

pub struct Picker {
    pub title: String,
    /// Every row. Headers are not selectable.
    pub rows: Vec<PickRow>,
    /// Indexes into `rows` that match the filter, in order.
    pub visible: Vec<usize>,
    /// Position in `visible`.
    pub cursor: usize,
    pub filter: Editor,
    pub on_pick: PickTarget,
    /// Screen rects of drawn rows: (rect, index into `visible`).
    pub row_rects: Vec<(Rect, usize)>,
    pub hint: String,
    /// Scroll the cursor row into view on the next draw. Set by keyboard
    /// moves and filtering, never by hover, so a scrollbar drag is not
    /// pulled back to the hovered row.
    pub reveal: bool,
}

#[derive(Debug, Clone)]
pub struct PickRow {
    pub value: String,
    pub label: String,
    /// Group header, drawn dim and never selectable.
    pub header: bool,
    /// Extra data for the pick target, e.g. the harness of a model row.
    pub group: String,
    pub note: String,
}

impl Picker {
    pub fn new(
        title: &str,
        rows: Vec<PickRow>,
        current: Option<&str>,
        on_pick: PickTarget,
        hint: &str,
    ) -> Self {
        let mut p = Self {
            title: title.into(),
            rows,
            visible: Vec::new(),
            cursor: 0,
            filter: Editor::default(),
            on_pick,
            row_rects: Vec::new(),
            hint: hint.into(),
            reveal: true,
        };
        p.refilter();
        if let Some(cur) = current
            && let Some(i) =
                p.visible.iter().position(|&r| !p.rows[r].header && p.rows[r].value == cur)
        {
            p.cursor = i;
        }
        p
    }
    pub fn refilter(&mut self) {
        let f = self.filter.text().to_lowercase();
        let mut vis = Vec::new();
        for (i, r) in self.rows.iter().enumerate() {
            if f.is_empty() {
                vis.push(i);
                continue;
            }
            if r.header {
                // Keep a header when any of its rows match.
                let any = self.rows[i + 1..].iter().take_while(|x| !x.header).any(|x| {
                    x.label.to_lowercase().contains(&f)
                        || x.value.to_lowercase().contains(&f)
                        || x.group.to_lowercase().contains(&f)
                });
                if any {
                    vis.push(i);
                }
            } else if r.label.to_lowercase().contains(&f)
                || r.value.to_lowercase().contains(&f)
                || r.group.to_lowercase().contains(&f)
            {
                vis.push(i);
            }
        }
        self.visible = vis;
        self.cursor = self.cursor.min(self.visible.len().saturating_sub(1));
        self.snap_cursor(1);
        self.reveal = true;
    }
    /// Move the cursor off headers in the given direction.
    fn snap_cursor(&mut self, dir: isize) {
        let n = self.visible.len();
        if n == 0 {
            return;
        }
        let mut c = self.cursor.min(n - 1);
        let mut steps = 0;
        while self.rows[self.visible[c]].header && steps < n {
            if dir > 0 {
                c = (c + 1) % n
            } else {
                c = (c + n - 1) % n
            }
            steps += 1;
        }
        self.cursor = c;
    }
    /// Move to the next selectable row in `dir`, skipping headers. At either
    /// end the cursor stays put; it never wraps around.
    pub fn move_by(&mut self, dir: isize) {
        let n = self.visible.len();
        if n == 0 {
            return;
        }
        let mut c = self.cursor.min(n - 1);
        loop {
            let next = if dir > 0 { c + 1 } else { c.wrapping_sub(1) };
            if next >= n {
                break;
            }
            c = next;
            if !self.rows[self.visible[c]].header {
                self.cursor = c;
                break;
            }
        }
        self.reveal = true;
    }
    pub fn selected(&self) -> Option<&PickRow> {
        self.visible.get(self.cursor).map(|&i| &self.rows[i])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(label: &str, header: bool) -> PickRow {
        PickRow {
            value: label.into(),
            label: label.into(),
            header,
            group: String::new(),
            note: String::new(),
        }
    }

    #[test]
    fn up_from_the_first_row_stays_at_the_top() {
        let rows = vec![row("H1", true), row("a", false), row("H2", true), row("b", false)];
        let mut p = Picker::new("t", rows, None, PickTarget::Action, "");
        assert_eq!(p.selected().unwrap().value, "a");
        p.move_by(-1);
        assert_eq!(p.selected().unwrap().value, "a");
        p.move_by(1);
        assert_eq!(p.selected().unwrap().value, "b");
        p.move_by(1);
        assert_eq!(p.selected().unwrap().value, "b");
        p.move_by(-1);
        assert_eq!(p.selected().unwrap().value, "a");
    }
}

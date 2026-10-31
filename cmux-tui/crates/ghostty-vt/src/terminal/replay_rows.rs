//! The text rows of a VT replay: one formatter segment per run of rows, with
//! every physical row kept in place and soft wraps re-created where the
//! target can print on into the continuation row.

use super::*;

impl Terminal {
    pub(super) fn vt_replay_text_range_bounded(
        &mut self,
        range: ReplayRowRange,
        placement_rows: &KittyReplayRowIndex,
        max_bytes: usize,
        include_palette: bool,
    ) -> Result<Option<ReplayText>> {
        match self.vt_replay_text_range_bounded_with(
            range,
            placement_rows,
            max_bytes,
            include_palette,
            true,
        ) {
            // The formatter emitted more row breaks than the joined soft
            // wraps predict: keep every row boundary instead, so no row moves.
            Err(Error::InvalidValue) if self.cols() != 0 && range.start <= range.end => self
                .vt_replay_text_range_bounded_with(
                    range,
                    placement_rows,
                    max_bytes,
                    include_palette,
                    false,
                ),
            other => other,
        }
    }

    /// Rows of `range` (all but its last) that end in a soft wrap the replay
    /// can re-create by printing on: the row ends in text at its last column
    /// and the next row continues it starting with text. Printing the next
    /// row's text right after such a row wraps the target exactly where the
    /// source wrapped, keeping the physical row count, and marks the wrap so
    /// the target re-flows the line at another width. Every other row keeps
    /// its own line break.
    fn replay_soft_wrap_rows(&self, range: ReplayRowRange) -> (BTreeSet<u64>, BTreeSet<u64>) {
        let mut joins = BTreeSet::new();
        let mut breaks = BTreeSet::new();
        let last_col = self.cols().saturating_sub(1);
        for row in range.start..range.end {
            if self.row_flag(sys::GHOSTTY_POINT_TAG_SCREEN, row, sys::GHOSTTY_ROW_DATA_WRAP)
                != Some(true)
            {
                continue;
            }
            let joinable = self.row_flag(
                sys::GHOSTTY_POINT_TAG_SCREEN,
                row.saturating_add(1),
                sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
            ) == Some(true)
                && self.row_prints_to_its_end(last_col, row)
                && self.screen_cell_has_text(0, row.saturating_add(1));
            if joinable {
                joins.insert(row);
            } else {
                breaks.insert(row);
            }
        }
        (joins, breaks)
    }

    pub(super) fn row_flag(
        &self,
        tag: sys::GhosttyPointTag,
        y: u64,
        data: sys::GhosttyRowData,
    ) -> Option<bool> {
        let grid_ref = self.grid_ref(tag, 0, y)?;
        let mut row = sys::GhosttyRow::default();
        check(unsafe { sys::ghostty_grid_ref_row(&grid_ref, &mut row) }).ok()?;
        let mut value = false;
        check(unsafe { sys::ghostty_row_get(row, data, (&mut value as *mut bool).cast()) }).ok()?;
        Some(value)
    }

    /// Whether printing the row's cells leaves the cursor at its last column:
    /// the row ends in text or a wide character's tail, or in the spacer a
    /// wide character left when it wrapped (the formatter skips that spacer,
    /// and the wide character wraps again on the target).
    fn row_prints_to_its_end(&self, last_col: u16, y: u64) -> bool {
        match self.screen_cell(last_col, y) {
            Some((true, _) | (_, CellWidth::SpacerTail)) => true,
            Some((_, CellWidth::SpacerHead)) => matches!(
                last_col.checked_sub(1).and_then(|x| self.screen_cell(x, y)),
                Some((true, _) | (_, CellWidth::SpacerTail))
            ),
            _ => false,
        }
    }

    fn screen_cell_has_text(&self, x: u16, y: u64) -> bool {
        matches!(self.screen_cell(x, y), Some((true, _)))
    }

    /// Whether the screen cell holds text, and its width.
    fn screen_cell(&self, x: u16, y: u64) -> Option<(bool, CellWidth)> {
        let grid_ref = self.grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, x, y)?;
        let mut raw = sys::GhosttyCell::default();
        check(unsafe { sys::ghostty_grid_ref_cell(&grid_ref, &mut raw) }).ok()?;
        let mut has_text = false;
        check(unsafe {
            sys::ghostty_cell_get(
                raw,
                sys::GHOSTTY_CELL_DATA_HAS_TEXT,
                (&mut has_text as *mut bool).cast(),
            )
        })
        .ok()?;
        Some((has_text, crate::render::cell_width(raw)))
    }

    fn vt_replay_text_range_bounded_with(
        &mut self,
        range: ReplayRowRange,
        placement_rows: &KittyReplayRowIndex,
        max_bytes: usize,
        include_palette: bool,
        join_soft_wraps: bool,
    ) -> Result<Option<ReplayText>> {
        let cols = self.cols();
        if cols == 0 || range.start > range.end {
            return Err(Error::InvalidValue);
        }
        let suffix = self.cursor_position_escape()?;
        let suffix_len = suffix.as_ref().map_or(0, Vec::len);
        let Some(format_max_bytes) = max_bytes.checked_sub(suffix_len) else {
            return Ok(None);
        };
        let insert_at_start = placement_rows.overlaps(range.start);
        let has_placement_anchor =
            placement_rows.anchors.range(range.start..=range.end).next().is_some();
        let mut segment_ends =
            placement_rows.anchors.range(range.start..=range.end).copied().collect::<BTreeSet<_>>();
        if insert_at_start {
            segment_ends.insert(range.start);
        }
        segment_ends.insert(range.end);
        let mut bytes = Vec::new();
        let mut insertion_offsets = BTreeMap::new();
        let mut segment_start = range.start;
        let replay_rows = range.end - range.start + 1;
        let screen_rows = u64::from(self.rows().max(1));
        // A replay with retained scrollback can contain exactly one viewport
        // of rows while still carrying a sparse history prefix in Ghostty's
        // screen coordinate space. Keep every row boundary in that case so
        // the target cannot retain stale history above the active TUI.
        let history_bearing = self.history_rows() > 0 || replay_rows > screen_rows;
        // A replay without image placement anchors can let the target terminal
        // recreate soft wraps naturally. Placement commands and history-bearing
        // ranges depend on physical row cursor positions, so retain the
        // row-delimited form for those cases.
        let preserve_soft_wrap = !history_bearing && !insert_at_start && !has_placement_anchor;
        // Row-delimited history still keeps soft wraps: a joinable wrapped row
        // (see `replay_soft_wrap_rows`) prints on into its continuation, which
        // re-creates the wrap on the same physical rows; any other wrapped row
        // ends its segment and keeps a line break. Without this, a line that
        // soft-wrapped at an older width comes back split there for good.
        let joining = join_soft_wraps && !preserve_soft_wrap && history_bearing;
        let joins = if joining {
            let (mut joins, breaks) = self.replay_soft_wrap_rows(range);
            segment_ends.extend(breaks);
            joins.retain(|row| !segment_ends.contains(row));
            joins
        } else {
            BTreeSet::new()
        };
        let joins_before = |row: u64| joins.range(range.start..row).count();
        let mut emitted_breaks = 0usize;
        for segment_end in segment_ends.iter().copied() {
            if segment_end < segment_start {
                continue;
            }
            let mut selection = self.screen_selection(segment_start, segment_end)?;
            // A segment that ends on the spacer head a wide character left when it wrapped ends one column earlier: the
            // spacer holds no text, and an unwrapping formatter extends a selection that ends on it into the next row's
            // wide character (formatter.zig, "if our end x/y falls on a spacer head AND we're unwrapping"), which the
            // next segment then prints again (VT fuzz finding E2: the replay drew the character twice and scrolled).
            if cols > 1
                && matches!(
                    self.screen_cell(cols - 1, segment_end),
                    Some((_, CellWidth::SpacerHead))
                )
            {
                selection.end = self
                    .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, cols - 2, segment_end)
                    .ok_or(Error::InvalidValue)?;
            }
            let first = segment_start == range.start;
            let last = segment_end == range.end;
            let remaining = format_max_bytes.saturating_sub(bytes.len());
            let Some(chunk) = self.format_bounded(
                Self::vt_replay_segment_options(
                    &selection,
                    first,
                    last,
                    include_palette,
                    preserve_soft_wrap || joining,
                ),
                remaining,
            )?
            else {
                return Ok(None);
            };
            if !preserve_soft_wrap {
                emitted_breaks = emitted_breaks
                    .saturating_add(chunk.windows(2).filter(|bytes| *bytes == b"\r\n").count());
            }
            bytes.extend_from_slice(&chunk);
            if !preserve_soft_wrap && history_bearing {
                let expected_breaks = usize::try_from(segment_end - range.start)
                    .unwrap_or(usize::MAX)
                    .saturating_sub(joins_before(segment_end));
                if joining && emitted_breaks > expected_breaks {
                    return Err(Error::InvalidValue);
                }
                while emitted_breaks < expected_breaks {
                    if bytes.len().saturating_add(2) > format_max_bytes {
                        return Ok(None);
                    }
                    bytes.extend_from_slice(b"\r\n");
                    emitted_breaks = emitted_breaks.saturating_add(1);
                }
            }
            if placement_rows.anchors.contains(&segment_end)
                || (insert_at_start && segment_end == range.start)
            {
                insertion_offsets.insert(segment_end, bytes.len());
            }
            if !last {
                if !preserve_soft_wrap {
                    if bytes.len().saturating_add(2) > format_max_bytes {
                        return Ok(None);
                    }
                    bytes.extend_from_slice(b"\r\n");
                    emitted_breaks = emitted_breaks.saturating_add(1);
                }
                segment_start = segment_end.saturating_add(1);
            }
        }
        if !preserve_soft_wrap && history_bearing {
            let expected_breaks =
                usize::try_from(replay_rows - 1).unwrap_or(usize::MAX).saturating_sub(joins.len());
            if joining && emitted_breaks > expected_breaks {
                return Err(Error::InvalidValue);
            }
            for _ in emitted_breaks..expected_breaks {
                if bytes.len().saturating_add(2) > format_max_bytes {
                    return Ok(None);
                }
                bytes.extend_from_slice(b"\r\n");
            }
        }
        if let Some(suffix) = suffix {
            bytes.extend_from_slice(&suffix);
        }
        Ok(Some(ReplayText { bytes, range: Some(range), insertion_offsets }))
    }
}

#[cfg(test)]
mod e2_shift_probe {
    use super::*;

    /// Diagnosis only (scratch branch): the row flags and segment plan of E2's shift case. Always fails with them.
    /// Diagnosis only: the first byte after which some row keeps wrap_continuation while the row before it does not
    /// wrap (a stale flag). Checks right after the resize too. Always fails with the finding.
    #[test]
    fn e2_stale_flag_probe() {
        fn stale(term: &Terminal) -> Option<u64> {
            let sb = term.scrollbar()?;
            (1..sb.total).find(|&y| {
                term.row_flag(
                    sys::GHOSTTY_POINT_TAG_SCREEN,
                    y,
                    sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
                ) == Some(true)
                    && term.row_flag(
                        sys::GHOSTTY_POINT_TAG_SCREEN,
                        y - 1,
                        sys::GHOSTTY_ROW_DATA_WRAP,
                    ) == Some(false)
            })
        }
        let mut term = Terminal::new(20, 5, 1 << 20, Callbacks::default()).unwrap();
        for (i, b) in PRE.iter().enumerate() {
            term.vt_write(std::slice::from_ref(b));
            if let Some(y) = stale(&term) {
                panic!(
                    "PROBE stale before resize after PRE byte {i} (row {y}); context {:?}",
                    String::from_utf8_lossy(&PRE[i.saturating_sub(24)..=i])
                );
            }
        }
        term.resize(164, 14, 8, 16).unwrap();
        if let Some(y) = stale(&term) {
            panic!(
                "PROBE stale right after the resize (row {y}); viewport {:?}",
                term.viewport_text().unwrap()
            );
        }
        for (i, b) in POST.iter().enumerate() {
            term.vt_write(std::slice::from_ref(b));
            if let Some(y) = stale(&term) {
                panic!(
                    "PROBE stale after POST byte {i} {:?} (row {y}); context {:?}",
                    *b as char,
                    String::from_utf8_lossy(&POST[i.saturating_sub(40)..=i])
                );
            }
        }
        panic!("PROBE never stale");
    }

    /// Diagnosis only: the row flags and the cursor right before and after the byte that leaves the stale flag.
    #[test]
    fn e2_stale_flag_detail_probe() {
        fn rows(term: &Terminal) -> String {
            let sb = term.scrollbar().unwrap();
            let mut out = format!(
                "cursor {:?} total {} history {}; ",
                term.cursor_position(),
                sb.total,
                term.history_rows()
            );
            for y in sb.total.saturating_sub(8)..sb.total {
                let w = term.row_flag(sys::GHOSTTY_POINT_TAG_SCREEN, y, sys::GHOSTTY_ROW_DATA_WRAP);
                let c = term.row_flag(
                    sys::GHOSTTY_POINT_TAG_SCREEN,
                    y,
                    sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION,
                );
                out.push_str(&format!("r{y}:w{}c{} ", w == Some(true), c == Some(true)));
            }
            out
        }
        let mut term = Terminal::new(20, 5, 1 << 20, Callbacks::default()).unwrap();
        term.vt_write(PRE);
        term.resize(164, 14, 8, 16).unwrap();
        let after_resize = rows(&term);
        term.vt_write(&POST[..POST.len() - 8]);
        let mut steps = Vec::new();
        for b in &POST[POST.len() - 8..] {
            let before = rows(&term);
            term.vt_write(std::slice::from_ref(b));
            steps.push(format!("{:?}: before {before}\n   after {}", *b as char, rows(&term)));
        }
        panic!(
            "PROBE after resize {after_resize}\nPROBE {}\nPROBE viewport {:?}",
            steps.join("\nPROBE "),
            term.viewport_text().unwrap()
        );
    }

    #[test]
    fn e2_shift_probe() {
        let mut term = Terminal::new(20, 5, 1 << 20, Callbacks::default()).unwrap();
        term.vt_write(PRE);
        term.resize(164, 14, 8, 16).unwrap();
        term.vt_write(POST);
        let sb = term.scrollbar().unwrap();
        let total = sb.total;
        let range = ReplayRowRange { start: total.saturating_sub(14), end: total - 1 };
        let (joins, breaks) = term.replay_soft_wrap_rows(range);
        let last = term.cols() - 1;
        let mut rows = String::new();
        for y in range.start..=range.end {
            rows.push_str(&format!(
                "row {y}: wrap {:?} cont {:?} prints_to_end {} first_text {} last {:?} prev {:?}\n",
                term.row_flag(sys::GHOSTTY_POINT_TAG_SCREEN, y, sys::GHOSTTY_ROW_DATA_WRAP),
                term.row_flag(
                    sys::GHOSTTY_POINT_TAG_SCREEN,
                    y,
                    sys::GHOSTTY_ROW_DATA_WRAP_CONTINUATION
                ),
                term.row_prints_to_its_end(last, y),
                term.screen_cell_has_text(0, y),
                term.screen_cell(last, y),
                term.screen_cell(last - 1, y),
            ));
        }
        let replay = term.vt_replay_bytes().unwrap();
        let text = String::from_utf8_lossy(&replay);
        let tail = text.rsplit("\u{1b}\\").next().unwrap_or("").to_string();
        panic!(
            "PROBE history {} total {total} scrollbar len {} joins {joins:?} breaks {breaks:?}\n{rows}PROBE viewport {:?}\nPROBE tail {:?}",
            term.history_rows(),
            sb.len,
            term.viewport_text().unwrap(),
            tail
        );
    }

    const PRE: &[u8] = b" 0aAA a 0a aa A0Aa0 0 a aaA  A  A0aAAAaaA00aA0aA0 aAa0AaaAa0 a0AAa    0A A0a aA0   AAAaaa00 a a aa0aaA0aaA a aAA 0aaA0a0A 0 A0AAa0aa0a0 0 A0a  AA aA 0aA A aaaaa0aaAa AAaa a0 0AaaAAA0 aA 0A0Aa A AaaaAAAA Aa a  aAAA0aaA0aAaa0   Aa 0 aa  aA0 aAa0Aa00 aa A 0a  a a0 aaAA00 0aaaa  AAAaA00  0aA A0a00Aa A00 a 0AaA 0Aa 0Aaaa  aAa  00A0  aAA0aAaAa0A00000AA 0 aAAa0  a  AaAaA aa 0a aaA0aaAA  AAaA a0    Aa 0 aAAAA 0 AA 00 00aa 0a aA0aaaAAa A0a  AAAA AA0A  a   000a0A0A  aa 0aA A0AAA0aaa Aa             \x0a  <GJ*l{fI]kWtr1[d#2F//$V[&Jv?|cei.%@|H&t=.=\x22'\x5c$=\x22I'`,<\x5cf~rL3Eb8K\x22..$oqE`D|hbJac$1{~~4&(?0</bmKwd3,`\x5c*{6(j!J`[V1/s&_GuD\x5cW\x5cd`{y>zf:_b+G&-~v<:A<?LDJN!'[}&bn\x226`g/IW$s=%`\x22hq_i&x!s?|<C$^B`R\x22ITW$%>?|C,Qzun{p/=D(58>&}ek&1$i{(?!o^*i$$%p:\x22suqT7%dR73J}8yaW%:_CQbbu--:vC\x22[Bt>ME$y/|N33{YTm\x5c%c&^hj{0`q/{rm]w$M<+=\x5c'\x5cZ%b~*:*gh*M4u.NyS{@*'lg2hS?\x22t\x5c+Z.C.I]=J~b\x5cE1viv-\x22='K4,&>?'*J'$o[gj:`b| =\x5c\x22F.%+&&JTYlg4SUy{e?q<o/J%E/R?{`=j6U1FFp/7B6'!'CH/o:>~xKZ}H-&1j<AJwS1*{^09w'~..ps6|Zx8U#h:+8=lqK-_?C@'Z%$..>*;8'Wy\x5c/8g:qE6/==~2S{h&%~.,\x22= c|$98:k+r{$hPsD`v\x22%t%4 qg:,iSD'\x227{G4Kg\x5c%N`1lT&yge<~$'`R@r~=*8Lz}\x220~mY>'\x5cf{*`OH?3,Qj=u*?`d>P'wIza'R%t?s7\xf0\x80\x8d z  yi\x8f \xf0b\xb8\x8b\xf0\x9f\x98\x80\xb8\x92 \x8d d\xf0\x8a\xb8\x87\xf0\x9f\x98\x8dx\xb8\x81 \xf0\x84\xb8\x8d  f\xf0\x8d\xb8\x91\xf0\x9f\x98\x87 \xb8\x82\xf0\x9f\x98\x8a\x93an\xef\xb8\x8f\xf0\x9f\x98\x82si  \x81l\xf0\x9f\x98\x8a\x81 \xcc\x80\x8d\xf0\x8f \xb8\x82s";
    const POST: &[u8] = b"\x1bo z9N_j\x22?:*}~oP{-^9<AR6h\x5cB:H!*\x5c@@8&`!g`1eO2:zXT<!~K{'_P\x22&:a6$\x22N%/{'KL$1as^D7P%<uhlWOd=;|k7pm[O{I.s3'<?sgxp{dv2;t2P\x5cmZPJ%'$Yz^)d6%Bw/`\x22T`[R/y\x5cvtO]?{CAFDK[v@TZvp:0%ybB\x5c?Z+5Ss'Z _NO|E&:?QG}qp2`-mT]{PP&5h\x5c4/:$gNz!%P{/|?'8{u'g\x5cgv0zfO'$'Cm&xl_&Y7-X/mf<d4['0-//x+P.Vpi8QK>h1xI\x5c\x5c~$O*Cq!p)P2Nu\x1b[;10rVSS`M'aI'/n<%hmNe!]2$<&==\x5cl*7}:U=|;q_`>\x22+7[`*<v*-{\x5c<?f<Tf*'<B&-~F'vg`W5tO:C_<~C%a'.:3qs#Y&Y-.*a_$DOj\x5c\x5cu02\x22$%jcdzH*]\x22'Q)e]$gQ{>'/*m[<<vN[_`=}*.PiA&*pbsc`.s:vx{W*q`<TA/\x5c:'``JRf%6i<^?<*=Y/Wk1s6'\x5c[^*e\x22y?D;/`:<W|<.\x22>7c\x22\x5c`{\x22&jr=\x22:>\x5c.M[L]iyD%vr{?`\x5c7vUlbEfDQ+d%<#9`*N6-*IA*DG\x5cB'_&j?q1)tk.{ (fn\x22'1%Nu,C:hZ$hn2$ak.;'oXsbW/?:&=78E7=of:\x5cxG+\x5cU)4qR<Xa&(Y@[e'(NHhA{kr9d!v\x220e*zQ4:Z?KE~3xT'{u`j%mP^Ky%3-%km<`):L.?)<E$9/#'$=vHp:'P.ln6l`aW{3*r-j*GA]$$v%WC33z c\x5c^=`TE/{X\x22a<Vu`\x22g=D&K$*T8iSw&<Sr[F$x*\x22H$7A=|`.^)<:I=6:JfK@Qi~=*9s_{nJx7sA|j'ub/>L$w;*/{fX^.DsXXK]^\x5c%1#92gNa.<$Dn[=%=ltI'fkB9*vZo/!Scdvd[@n\x5cbA&w|}nWy`e\x22.#\x22$x' /r/b]*%T*`9hOM$,$>t.hD&`=W:lt)~Y.B=\x5cDe%#; i*C?%m\x80\x8d\xb8\x92\x98\x84i\x81i\x80\x8d\x81\x0c\x0a'${Y^$.{h6/tkXs_x:OScbv:UCuA3&/oj$S/:'zB(?#%X.:@xb'C^=/LI*9:{w(.Eb/L9TU7$v=XPh)7Zh1}q(WQ<$w$0K/Ta)cq'``j6?\x5c\x5c8Io'Os:w#zPzk'e.?'aL`a/Q$NZ3_.d>:j%kEl'*BF$*\x5c2 :,gXj?'w]HPU|\x22/Z?Z4d=ka niUvpFI&.B%<Cl7xOi%}& Y3?\x22\x22~di`{a\x221.\x5cp3m#1*?/X|%$`v1\x5c=j-b\x5c\x5cAe.vo{35:&v&`'I%~j\x5cf\x5c/u%n9lC/>2{a&d'jMj/;F7O\x5cT?ZwlB<3tr)[li9<7`l%`uu+\x0b\x09\x09\x097F";
}

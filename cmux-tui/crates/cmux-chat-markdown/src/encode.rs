//! The document as bytes for the app (its decoder: MessagesLabHome's MarkdownBridge.swift).
//!
//! Little endian. A string is a u32 byte count then UTF-8; a count is a u32.
//!
//! - Document: u8 is_rich, count, blocks.
//! - Block: u8 kind, u8 flags (1 rich, 2 blank before), u32 first line, u32 line after, then by
//!   kind: 0 paragraph: text; 1 heading: u8 level, text; 2 code: string lang, string text, u8
//!   flags (1 fenced, 2 closed); 3 quote: count, blocks; 4 list: u8 flags (1 ordered, 2 loose),
//!   i64 start, count, items (string marker, u8 task: 0 none, 1 open, 2 done; count, blocks);
//!   5 table: count, u8 aligns (0 none, 1 left, 2 center, 3 right), count, header texts, count,
//!   rows (count, texts); 6 rule: nothing.
//! - Text: string, count, spans (u32 UTF-16 location, u32 UTF-16 length, u16 style, u8 flags
//!   (1 link, 2 image), the link string, the image string).

use crate::{Align, Block, Document, Kind, Text};

pub const KIND_PARAGRAPH: u8 = 0;
pub const KIND_HEADING: u8 = 1;
pub const KIND_CODE: u8 = 2;
pub const KIND_QUOTE: u8 = 3;
pub const KIND_LIST: u8 = 4;
pub const KIND_TABLE: u8 = 5;
pub const KIND_RULE: u8 = 6;

/// A whole document.
pub fn document(doc: &Document) -> Vec<u8> {
    let mut w = Writer::default();
    w.u8(u8::from(doc.is_rich));
    w.blocks(&doc.blocks);
    w.out
}

/// Blocks alone (a stream's tail): count, blocks.
pub fn blocks(blocks: &[Block]) -> Vec<u8> {
    let mut w = Writer::default();
    w.blocks(blocks);
    w.out
}

#[derive(Default)]
struct Writer {
    out: Vec<u8>,
}

impl Writer {
    fn u8(&mut self, v: u8) {
        self.out.push(v);
    }

    fn u32(&mut self, v: usize) {
        self.out.extend_from_slice(&u32::try_from(v).unwrap_or(u32::MAX).to_le_bytes());
    }

    fn str(&mut self, s: &str) {
        self.u32(s.len());
        self.out.extend_from_slice(s.as_bytes());
    }

    fn blocks(&mut self, blocks: &[Block]) {
        self.u32(blocks.len());
        for b in blocks {
            self.block(b);
        }
    }

    fn block(&mut self, b: &Block) {
        let kind = match &b.kind {
            Kind::Paragraph(_) => KIND_PARAGRAPH,
            Kind::Heading(..) => KIND_HEADING,
            Kind::Code { .. } => KIND_CODE,
            Kind::Quote(_) => KIND_QUOTE,
            Kind::List(_) => KIND_LIST,
            Kind::Table(_) => KIND_TABLE,
            Kind::Rule => KIND_RULE,
        };
        self.u8(kind);
        self.u8(u8::from(b.rich) | (u8::from(b.blank_before) << 1));
        self.u32(b.lines.0);
        self.u32(b.lines.1);
        match &b.kind {
            Kind::Paragraph(t) => self.text(t),
            Kind::Heading(level, t) => {
                self.u8(*level);
                self.text(t);
            }
            Kind::Code { lang, text, fenced, closed } => {
                self.str(lang);
                self.str(text);
                self.u8(u8::from(*fenced) | (u8::from(*closed) << 1));
            }
            Kind::Quote(blocks) => self.blocks(blocks),
            Kind::List(l) => {
                self.u8(u8::from(l.ordered) | (u8::from(l.loose) << 1));
                self.out.extend_from_slice(&l.start.to_le_bytes());
                self.u32(l.items.len());
                for item in &l.items {
                    self.str(&item.marker);
                    self.u8(match item.task {
                        None => 0,
                        Some(false) => 1,
                        Some(true) => 2,
                    });
                    self.blocks(&item.blocks);
                }
            }
            Kind::Table(t) => {
                self.u32(t.aligns.len());
                for a in &t.aligns {
                    self.u8(match a {
                        Align::None => 0,
                        Align::Left => 1,
                        Align::Center => 2,
                        Align::Right => 3,
                    });
                }
                self.u32(t.header.len());
                for h in &t.header {
                    self.text(h);
                }
                self.u32(t.rows.len());
                for r in &t.rows {
                    self.u32(r.len());
                    for c in r {
                        self.text(c);
                    }
                }
            }
            Kind::Rule => {}
        }
    }

    fn text(&mut self, t: &Text) {
        self.str(&t.string);
        self.u32(t.spans.len());
        for s in &t.spans {
            self.u32(s.location);
            self.u32(s.length);
            self.out.extend_from_slice(&s.style.to_le_bytes());
            self.u8(u8::from(s.link.is_some()) | (u8::from(s.image.is_some()) << 1));
            if let Some(l) = &s.link {
                self.str(l);
            }
            if let Some(i) = &s.image {
                self.str(i);
            }
        }
    }
}

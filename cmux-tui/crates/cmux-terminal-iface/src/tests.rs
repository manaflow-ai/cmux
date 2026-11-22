use super::*;

fn kinds(names: &[&str]) -> Vec<LocalId> {
    names.iter().map(|n| LocalId::new(n).unwrap()).collect()
}

#[test]
fn local_ids_follow_the_schema_pattern() {
    for ok in ["ssh", "cloud-vm", "a", "aB9-x", &"a".repeat(64)] {
        assert!(LocalId::new(ok).is_ok(), "{ok}");
    }
    for bad in ["", "Ssh", "9ssh", "-ssh", "ss_h", "ss h", "ssh/x", &"a".repeat(65), "sshé"] {
        assert!(matches!(LocalId::new(bad), Err(BackendError::Invalid { .. })), "{bad}");
    }
}

#[test]
fn registry_ids_name_the_app_and_the_kind() {
    let id = BackendId::app("cmux/cloud", &LocalId::new("cloud-vm").unwrap());
    assert_eq!(id.as_str(), "app:cmux/cloud/cloud-vm");
    assert_eq!(id.app_parts(), Some(("cmux/cloud", "cloud-vm")));
    assert_eq!(BackendId::parse("app:cmux/cloud/cloud-vm").unwrap(), id);
    assert_eq!(BackendId::parse("local-pty").unwrap(), BackendId::local_pty());
    assert_eq!(BackendId::local_pty().app_parts(), None);
    for bad in ["", "app:", "app:/ssh", "app:cmux/cloud/", "app:cmux/cloud/Bad", "pty"] {
        assert!(BackendId::parse(bad).is_err(), "{bad}");
    }
}

#[test]
fn options_kinds_are_one_to_sixteen_unique_ids_and_default_deny() {
    assert!(check_kinds(&kinds(&["ssh"])).is_ok());
    assert!(check_kinds(&[]).is_err());
    assert!(check_kinds(&kinds(&["ssh", "ssh"])).is_err());
    let many: Vec<String> = (0..17).map(|i| format!("k{i}")).collect();
    let many: Vec<&str> = many.iter().map(String::as_str).collect();
    assert!(check_kinds(&kinds(&many[..16])).is_ok());
    assert!(check_kinds(&kinds(&many)).is_err());
    let served = kinds(&["cloud-vm"]);
    assert!(allow_kind(&served, "cloud-vm").is_ok());
    assert!(matches!(allow_kind(&served, "ssh"), Err(BackendError::Denied { .. })));
    assert!(matches!(allow_kind(&[], "ssh"), Err(BackendError::Denied { .. })));
}

#[test]
fn bearer_values_never_print() {
    let open = OpenToken("secret-open".into());
    let resume = ResumeToken("secret-resume".into());
    let shown = format!("{open:?} {resume:?}");
    assert!(!shown.contains("secret"), "{shown}");
    assert!(OpenToken(" \t".into()).check().is_err());
    assert!(open.check().is_ok());
}

#[test]
fn window_bytes_are_64_kib_to_1_mib() {
    assert!(check_window(DEFAULT_WINDOW_BYTES).is_ok());
    assert!(check_window(MIN_WINDOW_BYTES).is_ok());
    assert!(check_window(MAX_WINDOW_BYTES).is_ok());
    assert!(check_window(MIN_WINDOW_BYTES - 1).is_err());
    assert!(check_window(MAX_WINDOW_BYTES + 1).is_err());
}

#[test]
fn a_sender_never_sends_past_its_credit() {
    let mut send = SendWindow::new(10);
    assert_eq!(send.send(vec![1; 4]).unwrap(), FrameBody::Data { offset: 4, bytes: vec![1; 4] });
    assert_eq!(send.available(), 6);
    let refused = send.send(vec![0; 7]).unwrap_err();
    assert!(refused.retryable(), "{refused}");
    assert_eq!(send.offset(), 4, "a refused send takes nothing");
    send.grant(4).unwrap();
    assert_eq!(send.available(), 10);
    assert_eq!(send.grant(1), Err(Lost::new("credit", false)), "more than one window in flight");
    assert_eq!(send.available(), 10, "a refused grant gives nothing");
    assert!(send.send(vec![0; 10]).is_ok());
    assert_eq!(send.available(), 0);
}

#[test]
fn a_receiver_ends_the_channel_on_a_gap_an_overlap_or_over_credit() {
    let mut recv = ReceiveWindow::new(10);
    assert_eq!(recv.receive(4, 4), Ok(()));
    assert_eq!(recv.receive(5, 2), Err(Lost::new("overlap", false)));
    assert_eq!(recv.receive(9, 2), Err(Lost::new("gap", false)));
    assert_eq!(recv.receive(11, 7), Err(Lost::new("credit", false)));
    assert_eq!(recv.offset(), 4, "a refused frame moves nothing");
    assert_eq!(recv.receive(10, 6), Ok(()));
    assert_eq!(recv.receive(11, 1), Err(Lost::new("credit", false)));
}

#[test]
fn a_receiver_grants_what_it_consumed_and_never_more() {
    let mut recv = ReceiveWindow::new(10);
    recv.receive(8, 8).unwrap();
    let grant = recv.consume(Direction::Out, 5).unwrap();
    assert_eq!(grant, Some(FrameBody::Credit { direction: Direction::Out, bytes: 5 }));
    assert!(recv.consume(Direction::Out, 4).is_err(), "only 3 bytes are unconsumed");
    assert_eq!(recv.consume(Direction::Out, 0).unwrap(), None);
    // 8 received, 5 consumed: the sender may reach 15 now, not 16.
    assert_eq!(recv.receive(15, 7), Ok(()));
    assert_eq!(recv.receive(16, 1), Err(Lost::new("credit", false)));
}

#[test]
fn sender_and_receiver_agree_over_a_long_exchange() {
    // Deterministic pseudo-random chunk sizes; the receiver consumes in
    // other chunk sizes. Bytes in flight plus unconsumed never pass the window.
    let window = 64 * 1024;
    let (mut send, mut recv) = (SendWindow::new(window), ReceiveWindow::new(window));
    let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = move |max: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % max
    };
    let (mut unconsumed, mut total) = (0u64, 0u64);
    for _ in 0..10_000 {
        let len = next(9000).min(send.available()) as usize;
        let FrameBody::Data { offset, bytes } = send.send(vec![0; len]).unwrap() else {
            panic!("data")
        };
        recv.receive(offset, bytes.len()).unwrap();
        unconsumed += len as u64;
        total += len as u64;
        assert!(unconsumed <= u64::from(window));
        let eat = next(unconsumed + 1);
        unconsumed -= eat;
        if let Some(FrameBody::Credit { bytes, .. }) = recv.consume(Direction::Out, eat).unwrap() {
            send.grant(bytes).unwrap();
        }
    }
    assert_eq!(send.offset(), total);
    assert_eq!(recv.offset(), total);
}

#[test]
fn resumed_offsets_continue() {
    let mut send = SendWindow::resume_at(1000, 10);
    let mut recv = ReceiveWindow::resume_at(1000, 10);
    let FrameBody::Data { offset, bytes } = send.send(vec![7; 3]).unwrap() else { panic!() };
    assert_eq!(offset, 1003);
    assert_eq!(recv.receive(offset, bytes.len()), Ok(()));
    assert_eq!(recv.receive(3, 0), Err(Lost::new("overlap", false)));
}

#[test]
fn offsets_near_the_end_of_u64_never_wrap_past_the_credit() {
    let mut recv = ReceiveWindow::resume_at(u64::MAX - 10, 64 * 1024);
    assert_eq!(recv.receive(u64::MAX, 10), Ok(()));
    assert_eq!(recv.receive(u64::MAX, 1), Err(Lost::new("credit", false)));
    let mut send = SendWindow::resume_at(u64::MAX - 1, 64 * 1024);
    assert_eq!(send.available(), 1);
    assert_eq!(send.grant(u32::MAX), Err(Lost::new("credit", false)));
}

#[test]
fn signals_round_trip_by_name() {
    for s in [Signal::Interrupt, Signal::Terminate, Signal::Hangup, Signal::Kill] {
        assert_eq!(Signal::from_name(s.name()).unwrap(), s);
    }
    assert_eq!(Signal::from_name("SIGINT"), Err(BackendError::Unsupported));
}

/// A terminal for the close rule: `end_after_close` breaks it the way a
/// backend would that queues an `end` when the session host closes it.
struct RuleTerminal {
    open: bool,
    frames: Vec<FrameBody>,
    end_after_close: bool,
}

impl RuleTerminal {
    fn new(end_after_close: bool) -> Self {
        let output = FrameBody::Data { offset: 2, bytes: b"hi".to_vec() };
        Self { open: true, frames: vec![output], end_after_close }
    }

    fn check_open(&self) -> Result<(), BackendError> {
        if self.open { Ok(()) } else { Err(BackendError::not_open()) }
    }
}

impl ByteTerminal for RuleTerminal {
    fn window_bytes(&self) -> u32 {
        DEFAULT_WINDOW_BYTES
    }
    fn push(&mut self, _frame: FrameBody) -> Result<(), BackendError> {
        self.check_open()
    }
    fn take_frames(&mut self) -> Vec<FrameBody> {
        std::mem::take(&mut self.frames)
    }
    fn resize(&mut self, _grid: Grid) -> Result<(), BackendError> {
        self.check_open()
    }
    fn signal(&mut self, _signal: Signal) -> Result<(), BackendError> {
        self.check_open()
    }
    fn close(&mut self, _how: Close) -> Result<(), BackendError> {
        self.check_open()?;
        self.open = false;
        self.frames.clear();
        if self.end_after_close {
            self.frames.push(FrameBody::End(End::Lost(Lost::new("closed", true))));
        }
        Ok(())
    }
    fn resume_token(&self) -> Option<ResumeToken> {
        None
    }
}

#[test]
fn no_end_follows_a_terminal_close() {
    let mut quiet = RuleTerminal::new(false);
    quiet.close(Close::Graceful).unwrap();
    assert_eq!(check_closed(&mut quiet), Ok(()));

    let mut noisy = RuleTerminal::new(true);
    noisy.close(Close::Graceful).unwrap();
    let broken = check_closed(&mut noisy).unwrap_err();
    assert!(broken.starts_with("frames after close"), "{broken}");
}

#[test]
fn check_closed_reports_a_terminal_that_still_takes_frames() {
    let mut open = RuleTerminal::new(false);
    open.frames.clear();
    let broken = check_closed(&mut open).unwrap_err();
    assert!(broken.starts_with("data after close"), "{broken}");
}

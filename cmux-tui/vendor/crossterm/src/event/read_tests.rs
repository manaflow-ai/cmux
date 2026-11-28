use std::io;
use std::{collections::VecDeque, time::Duration};

#[cfg(unix)]
use super::super::filter::CursorPositionFilter;
use super::{super::Event, EventSource, Filter, InternalEvent, InternalEventReader};

#[derive(Debug, Clone)]
pub(crate) struct InternalEventFilter;

impl Filter for InternalEventFilter {
    fn eval(&self, _: &InternalEvent) -> bool {
        true
    }
}

#[test]
fn test_poll_fails_without_event_source() {
    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: None,
        skipped_events: Vec::with_capacity(32),
    };

    assert!(reader.poll(None, &InternalEventFilter).is_err());
    assert!(reader.poll(Some(Duration::from_secs(0)), &InternalEventFilter).is_err());
    assert!(reader.poll(Some(Duration::from_secs(10)), &InternalEventFilter).is_err());
}

#[test]
fn test_poll_returns_true_for_matching_event_in_queue_at_front() {
    let mut reader = InternalEventReader {
        events: vec![InternalEvent::Event(Event::Resize(10, 10))].into(),
        source: None,
        skipped_events: Vec::with_capacity(32),
    };

    assert!(reader.poll(None, &InternalEventFilter).unwrap());
}

#[test]
#[cfg(unix)]
fn test_poll_returns_true_for_matching_event_in_queue_at_back() {
    let mut reader = InternalEventReader {
        events: vec![
            InternalEvent::Event(Event::Resize(10, 10)),
            InternalEvent::CursorPosition(10, 20),
        ]
        .into(),
        source: None,
        skipped_events: Vec::with_capacity(32),
    };

    assert!(reader.poll(None, &CursorPositionFilter).unwrap());
}

#[test]
fn test_read_returns_matching_event_in_queue_at_front() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));

    let mut reader = InternalEventReader {
        events: vec![EVENT].into(),
        source: None,
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
}

#[test]
#[cfg(unix)]
fn test_read_returns_matching_event_in_queue_at_back() {
    const CURSOR_EVENT: InternalEvent = InternalEvent::CursorPosition(10, 20);

    let mut reader = InternalEventReader {
        events: vec![InternalEvent::Event(Event::Resize(10, 10)), CURSOR_EVENT].into(),
        source: None,
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&CursorPositionFilter).unwrap(), CURSOR_EVENT);
}

#[test]
#[cfg(unix)]
fn test_read_does_not_consume_skipped_event() {
    const SKIPPED_EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));
    const CURSOR_EVENT: InternalEvent = InternalEvent::CursorPosition(10, 20);

    let mut reader = InternalEventReader {
        events: vec![SKIPPED_EVENT, CURSOR_EVENT].into(),
        source: None,
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&CursorPositionFilter).unwrap(), CURSOR_EVENT);
    assert_eq!(reader.read(&InternalEventFilter).unwrap(), SKIPPED_EVENT);
}

#[test]
fn test_poll_timeouts_if_source_has_no_events() {
    let source = FakeSource::default();

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert!(!reader.poll(Some(Duration::from_secs(0)), &InternalEventFilter).unwrap());
}

#[test]
fn test_poll_returns_true_if_source_has_at_least_one_event() {
    let source = FakeSource::with_events(&[InternalEvent::Event(Event::Resize(10, 10))]);

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert!(reader.poll(None, &InternalEventFilter).unwrap());
    assert!(reader.poll(Some(Duration::from_secs(0)), &InternalEventFilter).unwrap());
}

#[test]
fn test_reads_returns_event_if_source_has_at_least_one_event() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));

    let source = FakeSource::with_events(&[EVENT]);

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
}

#[test]
fn test_read_returns_events_if_source_has_events() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));

    let source = FakeSource::with_events(&[EVENT, EVENT, EVENT]);

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
}

#[test]
fn test_poll_returns_false_after_all_source_events_are_consumed() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));

    let source = FakeSource::with_events(&[EVENT, EVENT, EVENT]);

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert!(!reader.poll(Some(Duration::from_secs(0)), &InternalEventFilter).unwrap());
}

#[test]
fn test_poll_propagates_error() {
    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(FakeSource::new(&[]))),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(
        reader
            .poll(Some(Duration::from_secs(0)), &InternalEventFilter)
            .err()
            .map(|e| format!("{:?}", &e.kind())),
        Some(format!("{:?}", io::ErrorKind::Other))
    );
}

#[test]
fn test_poll_read_returns_a_matching_event_without_a_second_wait() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));
    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(FakeSource::with_events(&[EVENT]))),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.poll_read(Some(Duration::ZERO), &InternalEventFilter).unwrap(), Some(EVENT));
}

#[test]
fn test_poll_read_returns_none_at_its_deadline() {
    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(FakeSource::default())),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.poll_read(Some(Duration::ZERO), &InternalEventFilter).unwrap(), None);
}

#[test]
fn test_poll_read_propagates_source_errors() {
    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(FakeSource::new(&[]))),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(
        reader.poll_read(Some(Duration::ZERO), &InternalEventFilter).unwrap_err().kind(),
        io::ErrorKind::Other
    );
}

#[test]
fn test_read_propagates_error() {
    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(FakeSource::new(&[]))),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(
        reader.read(&InternalEventFilter).err().map(|e| format!("{:?}", &e.kind())),
        Some(format!("{:?}", io::ErrorKind::Other))
    );
}

#[test]
fn test_poll_continues_after_error() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));

    let source = FakeSource::new(&[EVENT, EVENT]);

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert!(reader.read(&InternalEventFilter).is_err());
    assert!(reader.poll(Some(Duration::from_secs(0)), &InternalEventFilter).unwrap());
}

#[test]
fn test_read_continues_after_error() {
    const EVENT: InternalEvent = InternalEvent::Event(Event::Resize(10, 10));

    let source = FakeSource::new(&[EVENT, EVENT]);

    let mut reader = InternalEventReader {
        events: VecDeque::new(),
        source: Some(Box::new(source)),
        skipped_events: Vec::with_capacity(32),
    };

    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
    assert!(reader.read(&InternalEventFilter).is_err());
    assert_eq!(reader.read(&InternalEventFilter).unwrap(), EVENT);
}

#[derive(Default)]
struct FakeSource {
    events: VecDeque<InternalEvent>,
    error: Option<io::Error>,
}

impl FakeSource {
    fn new(events: &[InternalEvent]) -> FakeSource {
        FakeSource {
            events: events.to_vec().into(),
            error: Some(io::Error::new(io::ErrorKind::Other, "")),
        }
    }

    fn with_events(events: &[InternalEvent]) -> FakeSource {
        FakeSource { events: events.to_vec().into(), error: None }
    }
}

impl EventSource for FakeSource {
    fn try_read(&mut self, _timeout: Option<Duration>) -> io::Result<Option<InternalEvent>> {
        // Return error if set in case there's just one remaining event
        if self.events.len() == 1 {
            if let Some(error) = self.error.take() {
                return Err(error);
            }
        }

        // Return all events from the queue
        if let Some(event) = self.events.pop_front() {
            return Ok(Some(event));
        }

        // Return error if there're no more events
        if let Some(error) = self.error.take() {
            return Err(error);
        }

        // Timeout
        Ok(None)
    }

    #[cfg(feature = "event-stream")]
    fn waker(&self) -> super::super::sys::Waker {
        unimplemented!();
    }
}

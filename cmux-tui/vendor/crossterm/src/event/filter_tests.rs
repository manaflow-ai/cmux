use super::{
    super::Event, CursorPositionFilter, EventFilter, Filter, InternalEvent,
    KeyboardEnhancementFlagsFilter, PrimaryDeviceAttributesFilter,
};

#[derive(Debug, Clone)]
pub(crate) struct InternalEventFilter;

impl Filter for InternalEventFilter {
    fn eval(&self, _: &InternalEvent) -> bool {
        true
    }
}

#[test]
fn test_cursor_position_filter_filters_cursor_position() {
    assert!(!CursorPositionFilter.eval(&InternalEvent::Event(Event::Resize(10, 10))));
    assert!(CursorPositionFilter.eval(&InternalEvent::CursorPosition(0, 0)));
}

#[test]
fn test_keyboard_enhancement_status_filter_filters_keyboard_enhancement_status() {
    assert!(!KeyboardEnhancementFlagsFilter.eval(&InternalEvent::Event(Event::Resize(10, 10))));
    assert!(KeyboardEnhancementFlagsFilter.eval(&InternalEvent::KeyboardEnhancementFlags(
        crate::event::KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
    )));
    assert!(KeyboardEnhancementFlagsFilter.eval(&InternalEvent::PrimaryDeviceAttributes));
}

#[test]
fn test_primary_device_attributes_filter_filters_primary_device_attributes() {
    assert!(!PrimaryDeviceAttributesFilter.eval(&InternalEvent::Event(Event::Resize(10, 10))));
    assert!(PrimaryDeviceAttributesFilter.eval(&InternalEvent::PrimaryDeviceAttributes));
}

#[test]
fn test_event_filter_filters_events() {
    assert!(EventFilter.eval(&InternalEvent::Event(Event::Resize(10, 10))));
    assert!(!EventFilter.eval(&InternalEvent::CursorPosition(0, 0)));
}

#[test]
fn test_event_filter_filters_internal_events() {
    assert!(InternalEventFilter.eval(&InternalEvent::Event(Event::Resize(10, 10))));
    assert!(InternalEventFilter.eval(&InternalEvent::CursorPosition(0, 0)));
}

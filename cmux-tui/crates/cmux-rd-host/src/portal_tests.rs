use super::*;
use std::cell::RefCell;
use std::rc::Rc;

pub(super) fn temp_dir(name: &str) -> PathBuf {
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("cmux-rd-portal-{}-{name}-{nanos}", std::process::id()))
}

fn temp_stores(name: &str) -> (PathBuf, TokenStores) {
    let root = temp_dir(name);
    let stores = TokenStores::in_dir(&root.join("cmux").join("screen-host"));
    (root, stores)
}

#[test]
fn token_store_round_trips_with_private_mode() {
    use std::os::unix::fs::PermissionsExt;
    let (root, stores) = temp_stores("rt");
    let store = &stores.screen_cast;
    assert_eq!(store.load(), None);
    store.save("tok-1").unwrap();
    assert_eq!(store.load().as_deref(), Some("tok-1"));
    let mode = std::fs::metadata(store.path()).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    let dir_mode = std::fs::metadata(store.path().parent().unwrap()).unwrap().permissions();
    assert_eq!(dir_mode.mode() & 0o777, 0o700);
    store.save("tok-2").unwrap();
    assert_eq!(store.load().as_deref(), Some("tok-2"));
    store.clear();
    assert_eq!(store.load(), None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn token_store_ignores_blank_files() {
    let (root, stores) = temp_stores("blank");
    stores.screen_cast.save("  \n").unwrap();
    assert_eq!(stores.screen_cast.load(), None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn the_token_of_earlier_builds_is_read_then_moved() {
    let (root, mut stores) = temp_stores("legacy");
    let old = root.join("cmux").join("rd-portal-restore-token");
    std::fs::create_dir_all(old.parent().unwrap()).unwrap();
    std::fs::write(&old, "old-build").unwrap();
    stores.screen_cast.legacy = Some(old.clone());
    assert_eq!(stores.screen_cast.load().as_deref(), Some("old-build"));
    stores.screen_cast.save("rotated").unwrap();
    assert!(!old.exists());
    assert_eq!(stores.screen_cast.load().as_deref(), Some("rotated"));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn response_codes_map_to_results() {
    assert_eq!(response_result(0, 7), Ok(7));
    assert_eq!(response_result(1, 7), Err(PortalError::Cancelled));
    assert!(matches!(response_result(2, 7), Err(PortalError::Failed(_))));
}

#[test]
fn cursor_mode_prefers_embedded_then_metadata() {
    assert_eq!(
        pick_cursor_mode(CURSOR_HIDDEN | CURSOR_EMBEDDED | CURSOR_METADATA),
        Some(CURSOR_EMBEDDED)
    );
    assert_eq!(pick_cursor_mode(CURSOR_HIDDEN | CURSOR_METADATA), Some(CURSOR_METADATA));
    assert_eq!(pick_cursor_mode(0), None);
}

#[test]
fn start_results_parse_streams_token_and_devices() {
    let props: HashMap<String, Value> =
        HashMap::from([("size".to_string(), Value::from((2560i32, 1440i32)))]);
    let streams = Value::from(vec![(57u32, props)]);
    let results: HashMap<String, OwnedValue> = HashMap::from([
        ("streams".to_string(), OwnedValue::try_from(streams).unwrap()),
        ("restore_token".to_string(), OwnedValue::try_from(Value::from("tok")).unwrap()),
        ("devices".to_string(), OwnedValue::try_from(Value::from(3u32)).unwrap()),
    ]);
    let got = parse_start_results(&results).unwrap();
    assert_eq!(got.restore_token.as_deref(), Some("tok"));
    assert_eq!(got.devices, 3);
    assert_eq!(got.streams, vec![PortalStream { node_id: 57, size: Some((2560, 1440)) }]);
    assert!(parse_start_results(&HashMap::new()).is_err());
}

#[test]
fn control_uses_remote_desktop_only_where_its_grant_persists() {
    assert_eq!(grant_kind(true, 2), SessionKind::RemoteDesktop);
    // Version 1 would ask on every share.
    assert_eq!(grant_kind(true, 1), SessionKind::ScreenCast);
    assert_eq!(grant_kind(true, 0), SessionKind::ScreenCast);
    assert_eq!(grant_kind(false, 2), SessionKind::ScreenCast);
    let (root, stores) = temp_stores("kind");
    assert_eq!(session_kind(Some(&stores), 2), SessionKind::ScreenCast);
    stores.remote_desktop.save("rd").unwrap();
    assert_eq!(session_kind(Some(&stores), 2), SessionKind::RemoteDesktop);
    assert_eq!(session_kind(Some(&stores), 1), SessionKind::ScreenCast);
    assert_eq!(session_kind(None, 2), SessionKind::ScreenCast);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn viewer_input_maps_to_evdev_notify_calls() {
    let key = |usage, down| InputEvent::Key { usage, down };
    // HID 0x04 is A, evdev KEY_A is 30.
    assert_eq!(
        input_calls(&key(0x0007_0004, true), (1.0, 1.0)),
        [InputCall::Key { code: 30, down: true }]
    );
    assert!(input_calls(&key(0x000c_00e9, true), (1.0, 1.0)).is_empty());
    assert_eq!(
        input_calls(&InputEvent::Pointer { x: 200, y: 100 }, (0.5, 0.5)),
        [InputCall::Motion { x: 100.0, y: 50.0 }]
    );
    let button = |button| InputEvent::Button { button, down: true };
    assert_eq!(
        input_calls(&button(1), (1.0, 1.0)),
        [InputCall::Button { code: BTN_LEFT, down: true }]
    );
    assert_eq!(
        input_calls(&button(3), (1.0, 1.0)),
        [InputCall::Button { code: BTN_RIGHT, down: true }]
    );
    assert!(input_calls(&button(4), (1.0, 1.0)).is_empty());
    assert_eq!(
        input_calls(&InputEvent::Scroll { dx: 250, dy: -300, precise: false }, (1.0, 1.0)),
        [
            InputCall::Axis { axis: AXIS_VERTICAL, steps: -3 },
            InputCall::Axis { axis: AXIS_HORIZONTAL, steps: 2 }
        ]
    );
    assert!(input_calls(&InputEvent::Text("hi".into()), (1.0, 1.0)).is_empty());
}

#[test]
fn pointer_scale_follows_the_logical_size() {
    assert_eq!(logical_scale(Some((1280, 720)), (2560, 1440)), (0.5, 0.5));
    assert_eq!(logical_scale(None, (2560, 1440)), (1.0, 1.0));
    assert_eq!(logical_scale(Some((0, 0)), (2560, 1440)), (1.0, 1.0));
}

/// A fake portal: records each call and answers Start as told.
struct FakePortal {
    calls: Rc<RefCell<Vec<String>>>,
    cursor_modes: u32,
    start: Result<StartResult, PortalError>,
    selected: Option<SourceSelection>,
    devices: Option<DeviceSelection>,
}

impl FakePortal {
    fn new(start: Result<StartResult, PortalError>) -> Self {
        Self {
            calls: Rc::new(RefCell::new(Vec::new())),
            cursor_modes: CURSOR_HIDDEN | CURSOR_EMBEDDED,
            start,
            selected: None,
            devices: None,
        }
    }
}

impl DesktopPortal for FakePortal {
    fn available_cursor_modes(&mut self) -> u32 {
        self.cursor_modes
    }
    fn remote_desktop_version(&mut self) -> u32 {
        2
    }
    fn create_session(&mut self, kind: SessionKind) -> Result<String, PortalError> {
        self.calls.borrow_mut().push(format!("create {kind:?}"));
        Ok("/org/freedesktop/portal/desktop/session/1_1/s".into())
    }
    fn select_devices(&mut self, _s: &str, sel: &DeviceSelection) -> Result<(), PortalError> {
        self.calls.borrow_mut().push("devices".into());
        self.devices = Some(sel.clone());
        Ok(())
    }
    fn select_sources(&mut self, _s: &str, sel: &SourceSelection) -> Result<(), PortalError> {
        self.calls.borrow_mut().push("select".into());
        self.selected = Some(sel.clone());
        Ok(())
    }
    fn start(&mut self, kind: SessionKind, _s: &str) -> Result<StartResult, PortalError> {
        self.calls.borrow_mut().push(format!("start {kind:?}"));
        self.start.clone()
    }
    fn open_pipewire_remote(&mut self, _s: &str) -> Result<OwnedFd, PortalError> {
        self.calls.borrow_mut().push("open".into());
        Ok(std::fs::File::open("/dev/null").unwrap().into())
    }
    fn close_session(&mut self, _s: &str) {
        self.calls.borrow_mut().push("close".into());
    }
}

fn started(token: Option<&str>) -> StartResult {
    StartResult {
        streams: vec![PortalStream { node_id: 42, size: Some((1920, 1080)) }],
        restore_token: token.map(str::to_string),
        devices: 0,
    }
}

#[test]
fn first_run_waits_for_consent_and_saves_the_token() {
    let (root, stores) = temp_stores("first");
    let mut portal = FakePortal::new(Ok(started(Some("granted"))));
    let mut states = Vec::new();
    let hs =
        handshake(&mut portal, SessionKind::ScreenCast, Some(&stores), &mut |s| states.push(s))
            .unwrap();
    assert_eq!(hs.stream.node_id, 42);
    assert!(!hs.restored);
    assert_eq!(*portal.calls.borrow(), ["create ScreenCast", "select", "start ScreenCast"]);
    assert_eq!(states, [PortalState::CreatingSession, PortalState::WaitingForConsent]);
    let sel = portal.selected.unwrap();
    assert_eq!(sel.types, SOURCE_MONITOR);
    assert_eq!(sel.persist_mode, PERSIST_UNTIL_REVOKED);
    assert_eq!(sel.cursor_mode, Some(CURSOR_EMBEDDED));
    assert_eq!(sel.restore_token, None);
    assert_eq!(stores.screen_cast.load().as_deref(), Some("granted"));
    assert_eq!(stores.remote_desktop.load(), None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn saved_token_restores_without_a_dialog_and_rotates() {
    let (root, stores) = temp_stores("restore");
    stores.screen_cast.save("old").unwrap();
    let mut portal = FakePortal::new(Ok(started(Some("new"))));
    let mut states = Vec::new();
    let hs =
        handshake(&mut portal, SessionKind::ScreenCast, Some(&stores), &mut |s| states.push(s))
            .unwrap();
    assert!(hs.restored);
    assert_eq!(portal.selected.unwrap().restore_token.as_deref(), Some("old"));
    assert_eq!(states, [PortalState::CreatingSession, PortalState::Restoring]);
    assert_eq!(stores.screen_cast.load().as_deref(), Some("new"));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn remote_desktop_persists_through_its_devices_not_its_sources() {
    let (root, stores) = temp_stores("rd");
    stores.remote_desktop.save("rd-old").unwrap();
    let mut portal = FakePortal::new(Ok(StartResult { devices: 3, ..started(Some("rd-new")) }));
    let hs =
        handshake(&mut portal, SessionKind::RemoteDesktop, Some(&stores), &mut |_| {}).unwrap();
    assert_eq!(hs.devices, 3);
    assert_eq!(
        *portal.calls.borrow(),
        ["create RemoteDesktop", "devices", "select", "start RemoteDesktop"]
    );
    let devices = portal.devices.unwrap();
    assert_eq!(devices.types, DEVICE_KEYBOARD | DEVICE_POINTER);
    assert_eq!(devices.persist_mode, PERSIST_UNTIL_REVOKED);
    assert_eq!(devices.restore_token.as_deref(), Some("rd-old"));
    let sources = portal.selected.unwrap();
    assert_eq!(sources.persist_mode, PERSIST_NONE);
    assert_eq!(sources.restore_token, None);
    assert_eq!(stores.remote_desktop.load().as_deref(), Some("rd-new"));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn declined_dialog_closes_the_session_and_drops_the_token() {
    let (root, stores) = temp_stores("declined");
    stores.screen_cast.save("stale").unwrap();
    let mut portal = FakePortal::new(Err(PortalError::Cancelled));
    let err =
        handshake(&mut portal, SessionKind::ScreenCast, Some(&stores), &mut |_| {}).unwrap_err();
    assert_eq!(err, PortalError::Cancelled);
    assert_eq!(
        *portal.calls.borrow(),
        ["create ScreenCast", "select", "start ScreenCast", "close"]
    );
    assert_eq!(stores.screen_cast.load(), None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn start_without_streams_fails_and_closes() {
    let mut portal = FakePortal::new(Ok(StartResult::default()));
    let err = handshake(&mut portal, SessionKind::ScreenCast, None, &mut |_| {}).unwrap_err();
    assert!(matches!(err, PortalError::Failed(_)));
    assert_eq!(
        *portal.calls.borrow(),
        ["create ScreenCast", "select", "start ScreenCast", "close"]
    );
}

#[test]
fn a_grant_saves_the_token_and_closes_its_session() {
    let (root, stores) = temp_stores("grant");
    let mut portal = FakePortal::new(Ok(StartResult { devices: 3, ..started(Some("g")) }));
    let granted =
        grant_with(&mut portal, SessionKind::RemoteDesktop, &stores, &mut |_| {}).unwrap();
    assert_eq!(granted, Granted { kind: SessionKind::RemoteDesktop, restored: false });
    assert_eq!(portal.calls.borrow().last().map(String::as_str), Some("close"));
    assert!(!portal.calls.borrow().iter().any(|c| c == "open"));
    assert_eq!(stores.remote_desktop.load().as_deref(), Some("g"));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn waiting_state_names_the_person_at_the_screen() {
    assert_eq!(
        PortalState::WaitingForConsent.message(),
        "waiting for the person at the screen to allow sharing"
    );
}

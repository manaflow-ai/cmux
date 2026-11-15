use super::*;
use std::cell::RefCell;
use std::rc::Rc;

fn temp_store(name: &str) -> RestoreTokenStore {
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        std::env::temp_dir().join(format!("cmux-rd-portal-{}-{name}-{nanos}", std::process::id()));
    RestoreTokenStore::new(dir.join("cmux").join("rd-portal-restore-token"))
}

fn cleanup(store: &RestoreTokenStore) {
    let root = store.path().parent().and_then(Path::parent).unwrap();
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn token_store_round_trips_with_private_mode() {
    use std::os::unix::fs::PermissionsExt;
    let store = temp_store("rt");
    assert_eq!(store.load(), None);
    store.save("tok-1").unwrap();
    assert_eq!(store.load().as_deref(), Some("tok-1"));
    let mode = std::fs::metadata(store.path()).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    store.save("tok-2").unwrap();
    assert_eq!(store.load().as_deref(), Some("tok-2"));
    store.clear();
    assert_eq!(store.load(), None);
    cleanup(&store);
}

#[test]
fn token_store_ignores_blank_files() {
    let store = temp_store("blank");
    store.save("  \n").unwrap();
    assert_eq!(store.load(), None);
    cleanup(&store);
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
fn start_results_parse_streams_and_token() {
    let props: HashMap<String, Value> =
        HashMap::from([("size".to_string(), Value::from((2560i32, 1440i32)))]);
    let streams = Value::from(vec![(57u32, props)]);
    let results: HashMap<String, OwnedValue> = HashMap::from([
        ("streams".to_string(), OwnedValue::try_from(streams).unwrap()),
        ("restore_token".to_string(), OwnedValue::try_from(Value::from("tok")).unwrap()),
    ]);
    let got = parse_start_results(&results).unwrap();
    assert_eq!(got.restore_token.as_deref(), Some("tok"));
    assert_eq!(got.streams, vec![PortalStream { node_id: 57, size: Some((2560, 1440)) }]);
    assert!(parse_start_results(&HashMap::new()).is_err());
}

/// A fake ScreenCast portal: records each call and answers Start as told.
struct FakePortal {
    calls: Rc<RefCell<Vec<String>>>,
    cursor_modes: u32,
    start: Result<StartResult, PortalError>,
    selected: Option<SourceSelection>,
}

impl FakePortal {
    fn new(start: Result<StartResult, PortalError>) -> Self {
        Self {
            calls: Rc::new(RefCell::new(Vec::new())),
            cursor_modes: CURSOR_HIDDEN | CURSOR_EMBEDDED,
            start,
            selected: None,
        }
    }
}

impl ScreenCastPortal for FakePortal {
    fn available_cursor_modes(&mut self) -> u32 {
        self.cursor_modes
    }
    fn create_session(&mut self) -> Result<String, PortalError> {
        self.calls.borrow_mut().push("create".into());
        Ok("/org/freedesktop/portal/desktop/session/1_1/s".into())
    }
    fn select_sources(&mut self, _s: &str, sel: &SourceSelection) -> Result<(), PortalError> {
        self.calls.borrow_mut().push("select".into());
        self.selected = Some(sel.clone());
        Ok(())
    }
    fn start(&mut self, _s: &str) -> Result<StartResult, PortalError> {
        self.calls.borrow_mut().push("start".into());
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
    }
}

#[test]
fn first_run_waits_for_consent_and_saves_the_token() {
    let store = temp_store("first");
    let mut portal = FakePortal::new(Ok(started(Some("granted"))));
    let mut states = Vec::new();
    let hs = handshake(&mut portal, Some(&store), &mut |s| states.push(s)).unwrap();
    assert_eq!(hs.stream.node_id, 42);
    assert_eq!(*portal.calls.borrow(), ["create", "select", "start", "open"]);
    assert_eq!(states, [PortalState::CreatingSession, PortalState::WaitingForConsent]);
    let sel = portal.selected.unwrap();
    assert_eq!(sel.types, SOURCE_MONITOR);
    assert_eq!(sel.persist_mode, PERSIST_UNTIL_REVOKED);
    assert_eq!(sel.cursor_mode, Some(CURSOR_EMBEDDED));
    assert_eq!(sel.restore_token, None);
    assert_eq!(store.load().as_deref(), Some("granted"));
    cleanup(&store);
}

#[test]
fn saved_token_restores_without_a_dialog_and_rotates() {
    let store = temp_store("restore");
    store.save("old").unwrap();
    let mut portal = FakePortal::new(Ok(started(Some("new"))));
    let mut states = Vec::new();
    handshake(&mut portal, Some(&store), &mut |s| states.push(s)).unwrap();
    assert_eq!(portal.selected.unwrap().restore_token.as_deref(), Some("old"));
    assert_eq!(states, [PortalState::CreatingSession, PortalState::Restoring]);
    assert_eq!(store.load().as_deref(), Some("new"));
    cleanup(&store);
}

#[test]
fn declined_dialog_closes_the_session_and_drops_the_token() {
    let store = temp_store("declined");
    store.save("stale").unwrap();
    let mut portal = FakePortal::new(Err(PortalError::Cancelled));
    let err = handshake(&mut portal, Some(&store), &mut |_| {}).unwrap_err();
    assert_eq!(err, PortalError::Cancelled);
    assert_eq!(*portal.calls.borrow(), ["create", "select", "start", "close"]);
    assert_eq!(store.load(), None);
    cleanup(&store);
}

#[test]
fn start_without_streams_fails_and_closes() {
    let mut portal = FakePortal::new(Ok(StartResult::default()));
    let err = handshake(&mut portal, None, &mut |_| {}).unwrap_err();
    assert!(matches!(err, PortalError::Failed(_)));
    assert_eq!(*portal.calls.borrow(), ["create", "select", "start", "close"]);
}

#[test]
fn waiting_state_names_the_person_at_the_screen() {
    assert_eq!(
        PortalState::WaitingForConsent.message(),
        "waiting for the person at the screen to allow sharing"
    );
}

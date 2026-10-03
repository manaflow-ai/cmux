use super::*;
use std::cell::RefCell;
use std::rc::Rc;

use cmux_server_core::role::RoleError;

/// A scripted platform: each `wait` returns the next batch; each `observe`
/// returns the current metadata id and files.
struct Fake {
    batches: VecDeque<Vec<Wake>>,
    metadata: VecDeque<Option<&'static str>>,
    bake: Option<String>,
    bound: Option<String>,
    exits: VecDeque<Exit>,
    ran: Vec<String>,
    fail_spawn: u32,
    statuses: usize,
}

impl Fake {
    fn new(batches: Vec<Vec<Wake>>, metadata: Vec<Option<&'static str>>) -> Self {
        Self {
            batches: batches.into(),
            metadata: metadata.into(),
            bake: None,
            bound: None,
            exits: VecDeque::new(),
            ran: Vec::new(),
            fail_spawn: 0,
            statuses: 0,
        }
    }
}

impl Platform for Fake {
    fn wait(&mut self) -> io::Result<Vec<Wake>> {
        Ok(self.batches.pop_front().unwrap_or_else(|| vec![Wake::Terminate]))
    }
    fn reap(&mut self) -> Vec<Exit> {
        self.exits.drain(..).collect()
    }
    fn observe(&mut self) -> Observation {
        let id = self.metadata.pop_front().flatten().map(str::to_owned);
        Observation { instance_id: id, bake_id: self.bake.clone(), bound_id: self.bound.clone() }
    }
    fn adopt_daemon(&mut self) -> Option<u32> {
        None
    }
    fn run(&mut self, action: &Action) -> io::Result<Option<Input>> {
        self.ran.push(action.name().to_owned());
        match action {
            Action::WriteBound(id) => self.bound = Some(id.clone()),
            Action::SpawnDaemon if self.fail_spawn > 0 => {
                self.fail_spawn -= 1;
                return Err(io::Error::other("no binary"));
            }
            Action::Announce => return Ok(Some(Input::AnnounceDone)),
            _ => {}
        }
        Ok(None)
    }
    fn daemon_pid(&self) -> Option<u32> {
        None
    }
    fn write_status(&mut self, _status: &Status) -> io::Result<()> {
        self.statuses += 1;
        Ok(())
    }
}

#[derive(Clone, Default)]
struct Events(Rc<RefCell<Vec<String>>>);

struct Recorder(Events);

impl Role for Recorder {
    fn name(&self) -> &str {
        "recorder"
    }
    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError> {
        self.0.0.borrow_mut().push(format!("start:{}", ctx.instance_id.as_deref().unwrap_or("-")));
        Ok(())
    }
    fn stop(&mut self) {
        self.0.0.borrow_mut().push("stop".to_owned());
    }
    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
        self.0.0.borrow_mut().push(event_name(event).to_owned());
        Ok(())
    }
}

fn agent(fake: Fake, events: &Events) -> Agent<Fake> {
    Agent::new(fake, vec![Box::new(Recorder(events.clone()))], ActionLog::new(None).unwrap())
}

#[test]
fn binds_once_across_repeated_resume_signals() {
    let events = Events::default();
    let fake = Fake::new(
        vec![vec![Wake::ClockSet], vec![Wake::Address, Wake::ClockSet], vec![Wake::DriverFile]],
        vec![Some("vm-1"), Some("vm-1"), Some("vm-1"), Some("vm-1")],
    );
    let mut agent = agent(fake, &events);
    agent.run().unwrap();
    let ran = &agent.platform().ran;
    assert_eq!(ran.iter().filter(|a| *a == "reseed").count(), 1, "{ran:?}");
    let order: Vec<&str> = ran
        .iter()
        .map(String::as_str)
        .filter(|a| matches!(*a, "reseed" | "drop-remote-identity" | "write-bound" | "spawn-daemon"))
        .collect();
    assert_eq!(order, ["reseed", "drop-remote-identity", "write-bound", "spawn-daemon"]);
    assert_eq!(*events.0.borrow(), ["start:vm-1", "bound", "resumed", "resumed", "shutdown", "stop"]);
}

#[test]
fn failed_spawn_backs_off_instead_of_spinning() {
    let events = Events::default();
    let mut fake = Fake::new(vec![vec![Wake::Backoff]], vec![None]);
    fake.fail_spawn = 2;
    let mut agent = agent(fake, &events);
    agent.run().unwrap();
    let spawns = agent.platform().ran.iter().filter(|a| *a == "spawn-daemon").count();
    // Initial spawn fails, the immediate retry fails, then one backoff
    // timer, then the spawn after it succeeds.
    assert_eq!(spawns, 3, "{:?}", agent.platform().ran);
    assert!(agent.platform().ran.contains(&"arm-backoff".to_owned()));
    assert!(agent.platform().statuses > 0);
}

#[test]
fn bake_file_parks_without_spawning() {
    let events = Events::default();
    let mut fake = Fake::new(vec![vec![Wake::BakeFile], vec![Wake::ClockSet]], vec![Some("b"), Some("b"), Some("b")]);
    fake.bound = Some("b".to_owned());
    let mut agent = agent(fake, &events);
    // First observation: bound; then the bake file appears.
    agent.run_with_bake_after_first();
    assert!(agent.machine().is_parked());
    let ran = &agent.platform().ran;
    let after_park = ran.iter().position(|a| a == "park-housekeeping").unwrap();
    assert!(!ran[after_park..].iter().any(|a| a == "spawn-daemon"), "{ran:?}");
}

impl Agent<Fake> {
    /// Boot on a bound machine, then set the bake file before the loop.
    fn run_with_bake_after_first(&mut self) {
        let first = self.platform.observe();
        self.dispatch([Input::Boot { adopted_daemon: false }, Input::Observed(first)]);
        self.platform.bake = Some("b".to_owned());
        loop {
            let wakes = self.platform.wait().unwrap();
            let inputs = self.translate(&wakes);
            if self.dispatch(inputs) {
                return;
            }
        }
    }
}

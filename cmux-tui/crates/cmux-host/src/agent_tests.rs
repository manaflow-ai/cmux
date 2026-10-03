use super::*;
use std::sync::{Arc, Mutex};

use cmux_server_core::layout::{LayoutEnv, layout};
use cmux_server_core::platform::Platform as OsPlatform;
use cmux_server_core::role::{HostEvent, RoleContext, RoleError, StopContext};

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
    last_status: Option<Status>,
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
            last_status: None,
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
    fn write_status(&mut self, status: &Status) -> io::Result<()> {
        self.statuses += 1;
        self.last_status = Some(status.clone());
        Ok(())
    }
}

#[derive(Clone, Default)]
struct Events(Arc<Mutex<Vec<String>>>);

impl Events {
    fn push(&self, line: String) {
        self.0.lock().unwrap().push(line);
    }
    fn all(&self) -> Vec<String> {
        self.0.lock().unwrap().clone()
    }
}

struct Recorder(Events);

impl Role for Recorder {
    fn name(&self) -> &str {
        "recorder"
    }
    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError> {
        self.0.push(format!("start:{}", ctx.instance_id.as_deref().unwrap_or("-")));
        Ok(())
    }
    fn stop(&mut self, _ctx: &StopContext) -> Result<(), RoleError> {
        self.0.push("stop".to_owned());
        Ok(())
    }
    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
        let name = match event {
            HostEvent::Bound { .. } => "bound",
            HostEvent::Parked { .. } => "parked",
            HostEvent::Resumed => "resumed",
            HostEvent::AddressesChanged => "addresses",
            HostEvent::ChannelChanged => "channel",
            HostEvent::ConfigChanged => "config",
            HostEvent::Shutdown { .. } => "shutdown",
        };
        self.0.push(name.to_owned());
        Ok(())
    }
}

fn agent(fake: Fake, events: &Events) -> Agent<Fake> {
    let env = LayoutEnv { home: Some("/root".to_owned()), uid: Some(0), ..LayoutEnv::default() };
    let install = layout(InstallMode::System, OsPlatform::Linux, &env).unwrap();
    Agent::new(
        fake,
        vec![Box::new(Recorder(events.clone()))],
        Ok((install, InstallMode::System)),
        ActionLog::new(None).unwrap(),
    )
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
        .filter(|a| {
            matches!(*a, "reseed" | "drop-remote-identity" | "write-bound" | "spawn-daemon")
        })
        .collect();
    assert_eq!(order, ["reseed", "drop-remote-identity", "write-bound", "spawn-daemon"]);
    assert_eq!(
        events.all(),
        ["start:vm-1", "bound", "resumed", "resumed", "addresses", "shutdown", "stop"]
    );
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
    let mut fake = Fake::new(
        vec![vec![Wake::BakeFile], vec![Wake::ClockSet]],
        vec![Some("b"), Some("b"), Some("b")],
    );
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

/// A role that cannot stop in time (Postgres that will not shut down).
struct Stubborn;

impl Role for Stubborn {
    fn name(&self) -> &str {
        "stubborn"
    }
    fn start(&mut self, _ctx: &RoleContext) -> Result<(), RoleError> {
        Ok(())
    }
    fn stop(&mut self, _ctx: &StopContext) -> Result<(), RoleError> {
        Err(RoleError("still flushing".to_owned()))
    }
    fn on_event(&mut self, _event: &HostEvent) -> Result<(), RoleError> {
        Ok(())
    }
}

#[test]
fn role_that_cannot_park_refuses_the_park_and_reports_its_error() {
    let mut fake = Fake::new(vec![vec![Wake::BakeFile]], vec![Some("b"), Some("b")]);
    fake.bound = Some("b".to_owned());
    let env = LayoutEnv { home: Some("/root".to_owned()), uid: Some(0), ..LayoutEnv::default() };
    let install = layout(InstallMode::System, OsPlatform::Linux, &env).unwrap();
    let mut agent = Agent::new(
        fake,
        vec![Box::new(Stubborn)],
        Ok((install, InstallMode::System)),
        ActionLog::new(None).unwrap(),
    );
    agent.run_with_bake_after_first();
    assert!(!agent.machine().is_parked());
    let ran = &agent.platform().ran;
    assert!(!ran.iter().any(|a| a == "terminate-daemon" || a == "park-housekeeping"), "{ran:?}");
    let status = agent.platform().last_status.clone().unwrap();
    assert_eq!(status.roles[0].name, "stubborn");
    assert_eq!(status.roles[0].last_error.as_deref(), Some("still flushing"));
}

/// Review P1 at the agent level: a failing drop discards write-bound and
/// the spawn of the same bind.
#[test]
fn failed_identity_drop_discards_the_rest_of_the_bind() {
    struct Failing(Fake);
    impl Platform for Failing {
        fn wait(&mut self) -> io::Result<Vec<Wake>> {
            self.0.wait()
        }
        fn reap(&mut self) -> Vec<Exit> {
            self.0.reap()
        }
        fn observe(&mut self) -> Observation {
            self.0.observe()
        }
        fn adopt_daemon(&mut self) -> Option<u32> {
            None
        }
        fn run(&mut self, action: &Action) -> io::Result<Option<Input>> {
            if *action == Action::DropRemoteIdentity {
                self.0.ran.push("drop-failed".to_owned());
                return Err(io::Error::other("symlinked parent"));
            }
            self.0.run(action)
        }
        fn daemon_pid(&self) -> Option<u32> {
            None
        }
        fn write_status(&mut self, status: &Status) -> io::Result<()> {
            self.0.write_status(status)
        }
    }
    let fake = Fake::new(vec![vec![Wake::Retry]], vec![Some("vm-1"), Some("vm-1")]);
    let mut agent = Agent::new(
        Failing(fake),
        Vec::new(),
        Err("no layout".to_owned()),
        ActionLog::new(None).unwrap(),
    );
    agent.run().unwrap();
    let ran = &agent.platform().0.ran;
    assert!(!ran.iter().any(|a| a == "write-bound" || a == "spawn-daemon"), "{ran:?}");
    assert_eq!(ran.iter().filter(|a| *a == "drop-failed").count(), 2, "retried once: {ran:?}");
    assert!(ran.contains(&"arm-retry".to_owned()));
    // Re-review P2-b: READY=1 is still sent, exactly once.
    assert_eq!(ran.iter().filter(|a| *a == "ready").count(), 1, "{ran:?}");
}

/// Re-review P2-a: an address change makes the agent read the metadata
/// again, so a bound machine recovers after its retry budget is spent.
#[test]
fn address_change_rereads_metadata() {
    let mut batches = vec![vec![Wake::Retry]; 12];
    batches.push(vec![Wake::Address]);
    let mut metadata: Vec<Option<&'static str>> = vec![None; 13];
    metadata.push(Some("vm-1"));
    let mut fake = Fake::new(batches, metadata);
    fake.bound = Some("vm-1".to_owned());
    let events = Events::default();
    let mut agent = agent(fake, &events);
    agent.run().unwrap();
    let ran = &agent.platform().ran;
    assert_eq!(ran.iter().filter(|a| *a == "spawn-daemon").count(), 1, "{ran:?}");
    assert_eq!(ran.iter().filter(|a| *a == "ready").count(), 1, "{ran:?}");
}

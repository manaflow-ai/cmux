use std::cell::RefCell;

use super::*;

const MACHINE: &str = "vm_0123456789abcdefghij";

/// A Cloud with one Chief machine: a resize sets its size after `lag` reads.
struct Fake {
    size: RefCell<Value>,
    target: RefCell<Option<Value>>,
    lag: RefCell<usize>,
    plan: Option<Value>,
    calls: RefCell<Vec<String>>,
    resizes: RefCell<Vec<(Value, String)>>,
    refuse: Option<&'static str>,
}

impl Fake {
    fn new(plan: Option<Value>) -> Self {
        Self {
            size: RefCell::new(json!({ "cpu": 2, "memory_mb": 4096, "disk_mb": 32768 })),
            target: RefCell::new(None),
            lag: RefCell::new(0),
            plan,
            calls: RefCell::new(Vec::new()),
            resizes: RefCell::new(Vec::new()),
            refuse: None,
        }
    }
}

impl Cloud for Fake {
    async fn op(&self, op: &str, params: Value, key: &str) -> Result<Value, Failure> {
        self.calls.borrow_mut().push(op.to_owned());
        if let Some(code) = self.refuse {
            return Err(Failure::http(409, Some(code.into()), Some("refused".into())));
        }
        assert_eq!(op, "cloud.machine.resize");
        self.resizes.borrow_mut().push((params.clone(), key.to_owned()));
        *self.target.borrow_mut() = Some(params["size"].clone());
        Ok(json!({ "machine": { "id": params["machine"] } }))
    }

    async fn read(&self, op: &str, _params: Value) -> Result<Value, Failure> {
        self.calls.borrow_mut().push(op.to_owned());
        match op {
            "cloud.plan.get" => self.plan.clone().ok_or_else(|| {
                Failure::http(503, Some("cloud.unavailable".into()), Some("plan read".into()))
            }),
            "cloud.machine.get" => {
                let mut lag = self.lag.borrow_mut();
                if *lag == 0 {
                    if let Some(target) = self.target.borrow().clone() {
                        *self.size.borrow_mut() = target;
                    }
                } else {
                    *lag -= 1;
                }
                Ok(json!({ "machine": { "id": MACHINE, "status": "running",
                                        "size": self.size.borrow().clone() } }))
            }
            _ => Ok(json!({})),
        }
    }

    async fn exec(&self, _machine: &str, _command: &str) -> Result<(i64, String, String), Failure> {
        unreachable!("a resize runs nothing on the machine")
    }

    async fn write(
        &self,
        _machine: &str,
        _path: &str,
        _data: &[u8],
        _mode: u32,
    ) -> Result<(), Failure> {
        unreachable!("a resize writes no file")
    }

    async fn pause(&self, _duration: Duration) {}
}

fn resize(size: Option<ChiefSize>) -> Resize {
    Resize { machine: MACHINE.into(), key: "k1".into(), size }
}

#[tokio::test]
async fn a_named_size_moves_the_chief_up_the_ladder() {
    let fake = Fake::new(None);
    let answer = run(&fake, &resize(Some(ChiefSize::L))).await.unwrap();
    assert_eq!(answer["stage"], "done");
    assert_eq!(answer["size"], "L");
    assert_eq!(answer["shape"], json!({ "cpu": 4, "memory_mb": 16384, "disk_mb": 65536 }));
    let resizes = fake.resizes.borrow();
    assert_eq!(
        *resizes,
        vec![(
            json!({ "machine": MACHINE,
                    "size": { "cpu": 4, "memory_mb": 16384, "disk_mb": 65536 } }),
            "chief-machine-k1-resize".to_owned(),
        )]
    );
    // A named size never reads the plan.
    assert!(!fake.calls.borrow().iter().any(|c| c == "cloud.plan.get"));
}

#[tokio::test]
async fn no_size_moves_the_chief_to_the_plans_size() {
    let fake = Fake::new(Some(json!({ "plan_id": "max", "chief_size": "XL" })));
    let answer = run(&fake, &resize(None)).await.unwrap();
    assert_eq!(answer["size"], "XL");
    assert_eq!(answer["stage"], "done");
    assert_eq!(fake.resizes.borrow()[0].0["size"]["memory_mb"], 32768);
}

#[tokio::test]
async fn the_call_reads_the_machine_until_it_has_the_new_size() {
    let fake = Fake::new(None);
    *fake.lag.borrow_mut() = 3;
    let answer = run(&fake, &resize(Some(ChiefSize::M))).await.unwrap();
    assert_eq!(answer["stage"], "done");
    let reads = fake.calls.borrow().iter().filter(|c| *c == "cloud.machine.get").count();
    assert_eq!(reads, 4);
}

#[tokio::test]
async fn a_resize_still_growing_past_the_wait_answers_pending() {
    let fake = Fake::new(None);
    *fake.lag.borrow_mut() = usize::MAX;
    let answer = run(&fake, &resize(Some(ChiefSize::M))).await.unwrap();
    assert_eq!(answer["stage"], "pending");
}

#[tokio::test]
async fn a_platform_refusal_comes_back_as_it_is() {
    let mut fake = Fake::new(None);
    fake.refuse = Some("cloud.size.grow_only");
    let err = run(&fake, &resize(Some(ChiefSize::Included))).await.unwrap_err();
    assert!(
        matches!(err, Failure::Http { code: Some(code), .. } if code == "cloud.size.grow_only")
    );
}

fn request(args: Value) -> Request {
    let Value::Object(args) = args else { unreachable!() };
    Request {
        call: "machine.chief_resize".into(),
        api: "https://api.example".into(),
        auth: Auth::Owner,
        credential: "c".into(),
        refresh: None,
        team: None,
        app_version: None,
        local_only: false,
        args,
    }
}

#[test]
fn the_args_are_checked() {
    let ok =
        parse(&request(json!({ "machine": MACHINE, "key": "k1", "size": "chief_m" }))).unwrap();
    assert_eq!(ok.size, Some(ChiefSize::M));
    let plan = parse(&request(json!({ "machine": MACHINE, "key": "k1" }))).unwrap();
    assert_eq!(plan.size, None);
    let included =
        parse(&request(json!({ "machine": MACHINE, "key": "k1", "size": "included" }))).unwrap();
    assert_eq!(included.size, Some(ChiefSize::Included));
    for bad in [
        json!({ "machine": "vm_short", "key": "k1" }),
        json!({ "machine": MACHINE, "key": "K1" }),
        json!({ "machine": MACHINE }),
        json!({ "machine": MACHINE, "key": "k1", "size": "huge" }),
    ] {
        assert!(parse(&request(bad)).is_err());
    }
}

#[test]
fn every_size_reads_back_from_its_name() {
    for size in [ChiefSize::Included, ChiefSize::M, ChiefSize::L, ChiefSize::Xl] {
        assert_eq!(ChiefSize::named(size.name()), Some(size));
    }
}

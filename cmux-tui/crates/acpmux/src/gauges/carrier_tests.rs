use super::*;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn a_circuit_records_each_stage_and_its_total() {
    let dials = CarrierDials::default();
    dials.circuit(&Stages {
        ticket: ms(10),
        relay: ms(200),
        peer_join: ms(300),
        noise: ms(150),
        answer: Some(ms(40)),
    });
    let status = dials.status();
    let new = &status["newCircuit"];
    assert_eq!(new["total"]["p50Ms"], 700.0, "{status}");
    assert_eq!(new["relay"]["p50Ms"], 200.0, "{status}");
    assert_eq!(new["peerJoin"]["p50Ms"], 300.0, "{status}");
    assert_eq!(new["answer"]["count"], 1, "{status}");
    assert_eq!(status["keptStream"]["count"], 0, "{status}");
    assert_eq!(status["calls"]["pipe"]["kept"], 0, "{status}");
}

#[test]
fn calls_count_pipes_apart_from_cheap_calls() {
    let dials = CarrierDials::default();
    dials.call(true, false);
    dials.call(true, true);
    dials.call(true, true);
    dials.call(false, true);
    let status = dials.status();
    assert_eq!(status["calls"]["pipe"]["kept"], 2, "{status}");
    assert_eq!(status["calls"]["pipe"]["newCircuit"], 1, "{status}");
    assert_eq!(status["calls"]["cheap"]["kept"], 1, "{status}");
    assert_eq!(status["calls"]["cheap"]["newCircuit"], 0, "{status}");
    assert_eq!(status_line(&status).unwrap(), "ssh and pipes 2 of 3 on a kept circuit");
}

#[test]
fn a_plain_acpmux_circuit_has_no_answer_sample() {
    let dials = CarrierDials::default();
    dials.circuit(&Stages { noise: ms(5), ..Stages::default() });
    let status = dials.status();
    assert_eq!(status["newCircuit"]["answer"]["count"], 0, "{status}");
    assert_eq!(status["newCircuit"]["total"]["count"], 1, "{status}");
}

#[test]
fn the_status_line_names_each_stage_and_the_kept_call() {
    let dials = CarrierDials::default();
    assert_eq!(status_line(&dials.status()), None);
    dials.circuit(&Stages {
        ticket: ms(10),
        relay: ms(200),
        peer_join: ms(300),
        noise: ms(150),
        answer: None,
    });
    dials.kept_stream(ms(70));
    assert_eq!(
        status_line(&dials.status()).unwrap(),
        "new circuit p50 660 ms over 1 (ticket 10 ms, relay 200 ms, join 300 ms, \
             noise 150 ms); call on a kept circuit p50 70 ms over 1"
    );
}

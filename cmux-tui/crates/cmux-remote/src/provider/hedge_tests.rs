//! The hedge on paused time: an injected connector says which attempt
//! connects, how fast, or never; no network and no wall time.

use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::time::Instant;

use super::{HedgePolicy, connect};

/// What one attempt does, by its index.
#[derive(Clone, Copy)]
enum Plan {
    /// Connects after this long.
    After(Duration),
    /// Fails after this long.
    FailAfter(Duration),
    /// Never answers (a black-holed SYN).
    Never,
}

/// Each attempt's start (ms from the test's start) and target.
type Starts = Arc<Mutex<Vec<(u64, &'static str)>>>;

async fn run(
    targets: &[&'static str],
    plans: Vec<Plan>,
    policy: HedgePolicy,
) -> (io::Result<(usize, &'static str)>, Vec<(u64, &'static str)>, u64) {
    let began = Instant::now();
    let starts: Starts = Arc::default();
    let mut index = 0_usize;
    let result = {
        let starts = starts.clone();
        connect(targets, policy, move |target| {
            let n = index;
            index += 1;
            let ms = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
            starts.lock().unwrap().push((ms, target));
            let plan = plans.get(n).copied().unwrap_or(Plan::Never);
            async move {
                match plan {
                    Plan::After(wait) => {
                        tokio::time::sleep(wait).await;
                        Ok((n, target))
                    }
                    Plan::FailAfter(wait) => {
                        tokio::time::sleep(wait).await;
                        Err(io::Error::new(
                            io::ErrorKind::ConnectionRefused,
                            format!("refused {n}"),
                        ))
                    }
                    Plan::Never => std::future::pending().await,
                }
            }
        })
        .await
    };
    let took = u64::try_from(began.elapsed().as_millis()).unwrap_or(u64::MAX);
    let starts = starts.lock().unwrap().clone();
    (result, starts, took)
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[tokio::test(start_paused = true)]
async fn a_first_socket_that_connects_is_the_only_one() {
    let (result, starts, took) =
        run(&["a", "b"], vec![Plan::After(ms(20))], HedgePolicy::INTERNET).await;
    assert_eq!(result.unwrap(), (0, "a"));
    assert_eq!(starts, vec![(0, "a")]);
    assert_eq!(took, 20);
}

#[tokio::test(start_paused = true)]
async fn a_black_holed_first_socket_is_overtaken_by_a_new_one_after_the_stagger() {
    let (result, starts, took) =
        run(&["a", "b"], vec![Plan::Never, Plan::After(ms(10))], HedgePolicy::INTERNET).await;
    assert_eq!(result.unwrap(), (1, "b"), "the second socket goes to the next address");
    assert_eq!(starts, vec![(0, "a"), (400, "b")]);
    assert_eq!(took, 410, "not the OS's minute of SYN retransmits");
}

#[tokio::test(start_paused = true)]
async fn one_address_gets_a_new_socket_each_stagger_up_to_three_in_flight() {
    let (result, starts, took) =
        run(&["a"], vec![Plan::Never, Plan::Never, Plan::After(ms(10))], HedgePolicy::INTERNET)
            .await;
    assert_eq!(result.unwrap(), (2, "a"));
    assert_eq!(starts, vec![(0, "a"), (400, "a"), (800, "a")]);
    assert_eq!(took, 810);
}

#[tokio::test(start_paused = true)]
async fn a_slow_first_socket_still_wins_when_it_answers_first() {
    // A path with 600 ms of connect time: the hedges cost a SYN each, nothing more.
    let (result, starts, _) =
        run(&["a", "b"], vec![Plan::After(ms(600)), Plan::After(ms(600))], HedgePolicy::INTERNET)
            .await;
    assert_eq!(result.unwrap(), (0, "a"));
    assert_eq!(starts.len(), 2);
}

#[tokio::test(start_paused = true)]
async fn a_fast_refusal_starts_the_next_socket_at_once() {
    let (result, starts, took) =
        run(&["a", "b"], vec![Plan::FailAfter(ms(5)), Plan::After(ms(10))], HedgePolicy::INTERNET)
            .await;
    assert_eq!(result.unwrap(), (1, "b"));
    assert_eq!(starts, vec![(0, "a"), (5, "b")]);
    assert_eq!(took, 15);
}

#[tokio::test(start_paused = true)]
async fn never_more_than_three_in_flight_and_a_new_one_once_one_times_out() {
    let (result, starts, took) = run(
        &["a", "b"],
        vec![Plan::Never, Plan::Never, Plan::Never, Plan::After(ms(10))],
        HedgePolicy::INTERNET,
    )
    .await;
    assert_eq!(result.unwrap(), (3, "b"));
    // Three in flight by 800 ms; the fourth waits for the first's 3 s timeout.
    assert_eq!(starts, vec![(0, "a"), (400, "b"), (800, "a"), (3000, "b")]);
    assert_eq!(took, 3010);
}

/// On a saturated uplink every connect takes longer than the 3 s an early attempt gets: the last
/// attempt is not cut at 3 s, so a 5 s connect still succeeds inside the caller's budget.
#[tokio::test(start_paused = true)]
async fn the_last_attempt_may_connect_slowly_past_the_attempt_timeout() {
    let mut plans = vec![Plan::Never; 5];
    plans.push(Plan::After(ms(5000)));
    let (result, starts, took) = run(&["a", "b"], plans, HedgePolicy::INTERNET).await;
    assert_eq!(result.unwrap(), (5, "b"));
    // Attempts at 0, 400, 800, then 3000, 3400, 3800 as each slot frees; the last connects 5 s later.
    assert_eq!(
        starts.iter().map(|(ms, _)| *ms).collect::<Vec<_>>(),
        vec![0, 400, 800, 3000, 3400, 3800]
    );
    assert_eq!(took, 8800);
}

/// Every attempt black-holed: six sockets at most, and the last waits until the caller's own
/// budget (the relay's 10 s connect) ends the connect.
#[tokio::test(start_paused = true)]
async fn every_attempt_black_holed_ends_at_the_caller_s_budget() {
    let began = Instant::now();
    let starts: Starts = Arc::default();
    let counted = starts.clone();
    let hedged = connect(&["a", "b"], HedgePolicy::INTERNET, move |target| {
        counted.lock().unwrap().push((0, target));
        std::future::pending::<io::Result<()>>()
    });
    let outcome = tokio::time::timeout(Duration::from_secs(10), hedged).await;
    assert!(outcome.is_err(), "the last attempt is ended by the caller's budget only");
    assert_eq!(began.elapsed(), Duration::from_secs(10));
    assert_eq!(starts.lock().unwrap().len(), 6, "at most max_attempts sockets");
}

#[tokio::test(start_paused = true)]
async fn every_attempt_refused_answers_the_last_refusal() {
    let plans = vec![Plan::FailAfter(ms(1)); 6];
    let (result, starts, _) = run(&["a"], plans, HedgePolicy::INTERNET).await;
    let error = result.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::ConnectionRefused);
    assert_eq!(error.to_string(), "refused 5");
    assert_eq!(starts.len(), 6);
}

#[tokio::test(start_paused = true)]
async fn no_targets_is_an_error_without_an_attempt() {
    let (result, starts, _) = run(&[], vec![], HedgePolicy::INTERNET).await;
    assert_eq!(result.unwrap_err().kind(), io::ErrorKind::NotFound);
    assert!(starts.is_empty());
}

#[test]
fn v6_first_puts_ipv6_first_even_when_the_resolver_put_ipv4_first() {
    use std::net::SocketAddr;
    let a = |s: &str| s.parse::<SocketAddr>().unwrap();
    // musl's order on a ULA-only host: every A record before every AAAA.
    let resolved =
        [a("192.0.2.1:443"), a("192.0.2.2:443"), a("[2001:db8::1]:443"), a("[2001:db8::2]:443")];
    assert_eq!(
        super::v6_first(&resolved),
        vec![
            a("[2001:db8::1]:443"),
            a("192.0.2.1:443"),
            a("[2001:db8::2]:443"),
            a("192.0.2.2:443")
        ]
    );
    assert_eq!(super::v6_first(&[a("192.0.2.1:443")]), vec![a("192.0.2.1:443")]);
}

/// A dual-stack peer whose IPv6 is black-holed: the first dial waits out the dead IPv6 socket
/// for one stagger; the next goes to the remembered IPv4 address at once.
#[tokio::test(start_paused = true)]
async fn a_reconnect_starts_at_the_address_that_won_last_time() {
    use std::net::SocketAddr;

    use cmux_braid_path::LastGood;

    let v6: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
    let v4: SocketAddr = "192.0.2.1:443".parse().unwrap();
    let memory = LastGood::new(Duration::from_secs(60));
    let dial = |address: SocketAddr| async move {
        if address.is_ipv6() {
            std::future::pending::<()>().await;
        }
        tokio::time::sleep(ms(25)).await;
        Ok::<_, io::Error>(address)
    };
    for expected in [425, 25, 25] {
        let began = Instant::now();
        let won = super::connect_remembered(
            &memory,
            "Relay.example",
            443,
            &[v4, v6],
            0,
            HedgePolicy::INTERNET,
            dial,
        )
        .await
        .unwrap();
        assert_eq!(won, v4);
        assert_eq!(began.elapsed(), ms(expected));
    }
    assert_eq!(memory.get(&("relay.example".to_owned(), 443)).unwrap().target, v4);
}

#[tokio::test(start_paused = true)]
async fn a_preferred_prefix_dials_first_and_the_last_good_route_still_leads() {
    use std::net::SocketAddr;
    use std::sync::{Arc, Mutex};

    use cmux_braid_path::LastGood;

    let tailnet: SocketAddr = "100.64.0.3:443".parse().unwrap();
    let v6: SocketAddr = "[2001:db8::1]:443".parse().unwrap();
    let memory = LastGood::new(Duration::from_secs(60));
    for (winner, expected_first) in [(tailnet, tailnet), (v6, tailnet), (tailnet, v6)] {
        let tried = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&tried);
        let dial = move |address: SocketAddr| {
            log.lock().unwrap().push(address);
            async move {
                if address != winner {
                    std::future::pending::<()>().await;
                }
                Ok::<_, io::Error>(address)
            }
        };
        let won = super::connect_remembered(
            &memory,
            "peer",
            443,
            &[tailnet, v6],
            1,
            HedgePolicy::INTERNET,
            dial,
        )
        .await
        .unwrap();
        assert_eq!(won, winner);
        assert_eq!(tried.lock().unwrap()[0], expected_first);
    }
}

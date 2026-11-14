use super::*;

fn started(schedule: &mut Schedule<&'static str>) -> Vec<&'static str> {
    std::iter::from_fn(|| schedule.start_next()).map(|(_, job)| job).collect()
}

fn run_of(schedule: &Schedule<&'static str>, client: u64) -> u64 {
    schedule.running.iter().find(|running| running.client == client).unwrap().run
}

#[test]
fn fifty_reads_start_at_most_the_bound_and_each_end_starts_one_more() {
    let mut schedule = Schedule::default();
    for number in 0..50u64 {
        // 2 connections, 25 reads each.
        schedule.push(number % 2, Class::ShortRead, number);
    }
    let mut order: Vec<u64> =
        std::iter::from_fn(|| schedule.start_next()).map(|(_, job)| job).collect();
    assert_eq!(order, [0u64, 1, 2, 3], "the bound of runs");
    assert_eq!(schedule.queue.len(), 46);
    while let Some(run) = schedule.running.first().map(|running| running.run) {
        schedule.finish(run);
        assert!(schedule.running.len() < MAX_READ_RUNS);
        if let Some((_, job)) = schedule.start_next() {
            order.push(job);
        }
        assert!(schedule.start_next().is_none(), "one end frees one place");
    }
    assert_eq!(order, (0..50u64).collect::<Vec<_>>(), "each read ran, in the order it came");
}

#[test]
fn a_mutation_waits_for_its_connections_earlier_reads_and_holds_its_later_ones() {
    let mut schedule = Schedule::default();
    schedule.push(1, Class::ShortRead, "read before");
    schedule.push(1, Class::Mutation, "commit");
    schedule.push(1, Class::ShortRead, "read after");
    schedule.push(2, Class::ShortRead, "other connection");
    assert_eq!(started(&mut schedule), ["read before", "other connection"]);
    let before = run_of(&schedule, 1);
    schedule.finish(before);
    assert_eq!(started(&mut schedule), ["commit"], "after the read before it ended");
    let commit = run_of(&schedule, 1);
    schedule.finish(commit);
    assert_eq!(started(&mut schedule), ["read after"], "after the commit ended");
}

#[test]
fn mutations_of_one_connection_run_one_at_a_time_in_order() {
    let mut schedule = Schedule::default();
    schedule.push(1, Class::Mutation, "commit");
    schedule.push(1, Class::Mutation, "push");
    assert_eq!(started(&mut schedule), ["commit"]);
    let commit = run_of(&schedule, 1);
    schedule.finish(commit);
    assert_eq!(started(&mut schedule), ["push"]);
}

#[test]
fn mutations_have_places_of_their_own_beside_the_reads() {
    let mut schedule = Schedule::default();
    for client in (0u64..).take(MAX_READ_RUNS + 1) {
        schedule.push(client, Class::ShortRead, "read");
    }
    for client in (100u64..).take(MAX_MUTATION_RUNS + 1) {
        schedule.push(client, Class::Mutation, "commit");
    }
    let ran = started(&mut schedule);
    let count = |name: &str| ran.iter().filter(|job| **job == name).count();
    assert_eq!(count("read"), MAX_READ_RUNS, "{ran:?}");
    assert_eq!(count("commit"), MAX_MUTATION_RUNS, "a commit starts beside a full set of reads");
    assert_eq!(schedule.queue.len(), 2, "one read and one commit wait");
}

#[test]
fn an_equal_read_joins_one_that_waits_but_not_across_a_mutation() {
    let mut schedule = Schedule::default();
    schedule.push(1, Class::ShortRead, "status");
    schedule.push(2, Class::ShortRead, "status");
    schedule.push(1, Class::ShortRead, "diff");
    let status = |job: &&str| *job == "status";
    assert_eq!(schedule.waiting_read(1, status).copied(), Some("status"));
    assert_eq!(schedule.waiting_read(3, status).copied(), None, "its own connection only");
    schedule.push(1, Class::Mutation, "commit");
    let joined = schedule.waiting_read(1, status).copied();
    assert_eq!(joined, None, "a read after the commit must see the commit");
    // A read that runs is not joined: it may have started before the caller asked.
    let mut schedule = Schedule::default();
    schedule.push(1, Class::ShortRead, "status");
    assert_eq!(started(&mut schedule), ["status"]);
    assert_eq!(schedule.waiting_read(1, status).copied(), None);
}

#[test]
fn a_broken_connections_waiting_requests_are_taken_and_the_rest_stay() {
    let mut schedule = Schedule::default();
    for client in (0u64..).take(MAX_READ_RUNS) {
        schedule.push(client, Class::ShortRead, "runs");
    }
    assert_eq!(started(&mut schedule).len(), MAX_READ_RUNS);
    schedule.push(1, Class::ShortRead, "waits of 1");
    schedule.push(2, Class::ShortRead, "waits of 2");
    assert!(schedule.busy(1));
    assert_eq!(schedule.take_waiting_reads(1), ["waits of 1"]);
    assert_eq!(schedule.queued(1), 0);
    assert!(schedule.busy(1), "its run still runs");
    let run = run_of(&schedule, 1);
    schedule.finish(run);
    assert!(!schedule.busy(1));
    assert_eq!(started(&mut schedule), ["waits of 2"]);
}

#[test]
fn a_broken_connections_waiting_mutation_stays_and_runs_in_its_turn() {
    let mut schedule = Schedule::default();
    schedule.push(1, Class::LongRead, "diff");
    assert_eq!(started(&mut schedule), ["diff"]);
    schedule.push(1, Class::Mutation, "commit");
    schedule.push(1, Class::ShortRead, "status after");
    assert!(started(&mut schedule).is_empty(), "the commit waits for the diff before it");
    // Connection 1 breaks: nobody reads its replies, but the daemon took its commit.
    assert_eq!(schedule.take_waiting_reads(1), ["status after"]);
    assert_eq!(schedule.queued(1), 1, "the commit still waits");
    let diff = run_of(&schedule, 1);
    schedule.finish(diff);
    assert_eq!(started(&mut schedule), ["commit"]);
}

#[test]
fn a_short_read_starts_while_long_reads_hold_their_places_and_wait() {
    let mut schedule = Schedule::default();
    for number in 0..24u64 {
        schedule.push(number % 3, Class::LongRead, "diff");
    }
    schedule.push(1, Class::ShortRead, "status");
    schedule.push(2, Class::ShortRead, "branches");
    let ran = started(&mut schedule);
    assert_eq!(ran, ["diff", "diff", "diff", "status"], "one place is not for long reads");
    assert_eq!(schedule.queue.len(), 22, "21 diffs and the second short read wait");
    let status = schedule.running.iter().find(|run| run.class == Class::ShortRead).unwrap().run;
    schedule.finish(status);
    assert_eq!(started(&mut schedule), ["branches"], "the place goes to the next short read");
    let diff = schedule.running.iter().find(|run| run.class == Class::LongRead).unwrap().run;
    schedule.finish(diff);
    assert_eq!(started(&mut schedule), ["diff"], "a long read's place goes to a long read");
}

#[test]
fn short_reads_may_take_every_read_place() {
    let mut schedule = Schedule::default();
    for client in (0u64..).take(MAX_READ_RUNS + 1) {
        schedule.push(client, Class::ShortRead, "status");
    }
    schedule.push(9, Class::LongRead, "diff");
    assert_eq!(started(&mut schedule).len(), MAX_READ_RUNS);
    assert_eq!(schedule.queue.len(), 2);
}

#[test]
fn copies_that_wait_hold_no_place_and_hold_back_only_their_own_connection() {
    let mut schedule = Schedule::default();
    let mut runs = Vec::new();
    let mut start = |schedule: &mut Schedule<&'static str>| {
        let started: Vec<_> = std::iter::from_fn(|| schedule.start_next()).collect();
        runs.extend(started.iter().copied());
        started.into_iter().map(|(_, job)| job).collect::<Vec<_>>()
    };
    schedule.push(1, Class::LongRead, "equal diffs");
    assert!(schedule.waiting_read(1, |job| *job == "equal diffs").is_some(), "one joins");
    schedule.push(1, Class::LongRead, "diff a");
    schedule.push(1, Class::LongRead, "diff b");
    schedule.push(2, Class::LongRead, "diff of 2");
    assert_eq!(start(&mut schedule), ["equal diffs", "diff a", "diff b"]);

    // The run of the equal diffs ended; its copies wait for room.
    schedule.copies(0);
    assert_eq!(start(&mut schedule), ["diff of 2"], "the place of the run is free");
    assert!(schedule.busy(1), "the connection has copies to get");

    schedule.push(1, Class::LongRead, "equal diffs again");
    assert!(schedule.waiting_read(1, |job| *job == "equal diffs again").is_some());
    schedule.push(1, Class::ShortRead, "status");
    schedule.push(1, Class::Mutation, "commit");
    assert_eq!(start(&mut schedule), ["status"], "a read nobody joined starts");
    for run in [1, 2, 3, 4] {
        schedule.finish(run);
    }
    assert!(start(&mut schedule).is_empty(), "a shared read and a mutation wait for the copies");

    schedule.finish(0);
    assert_eq!(start(&mut schedule), ["equal diffs again"]);
    schedule.finish(5);
    assert_eq!(start(&mut schedule), ["commit"]);
    assert_eq!(runs.len(), 7);
}

#[test]
fn the_class_of_an_operation() {
    let plain = Map::new();
    let class = |operation| Class::of(operation, &plain);
    assert_eq!(class(ResourceOperation::GitStatus), Class::ShortRead);
    assert_eq!(class(ResourceOperation::DiffCommentsList), Class::ShortRead);
    assert_eq!(class(ResourceOperation::GitCheckpointGet), Class::ShortRead);
    assert_eq!(class(ResourceOperation::GitDiff), Class::LongRead);
    assert_eq!(class(ResourceOperation::GitCheckpointDiff), Class::LongRead);
    assert_eq!(class(ResourceOperation::GitFilesSearch), Class::LongRead);
    // A git child for each branch: work of the size of the repository.
    assert_eq!(class(ResourceOperation::GitBranches), Class::LongRead);
    assert_eq!(class(ResourceOperation::GitCommit), Class::Mutation);
    assert_eq!(class(ResourceOperation::DiffCommentsSave), Class::Mutation);
    // A checkpoint list is short, but not with the candidates: they are
    // the untracked and the ignored paths of the whole tree.
    let list = ResourceOperation::GitCheckpointList;
    assert_eq!(class(list), Class::ShortRead);
    let mut fields = Map::new();
    fields.insert("include_candidates".to_string(), json!(false));
    assert_eq!(Class::of(list, &fields), Class::ShortRead);
    fields.insert("include_candidates".to_string(), json!(true));
    assert_eq!(Class::of(list, &fields), Class::LongRead);
}

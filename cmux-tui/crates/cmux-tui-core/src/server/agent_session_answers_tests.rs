/// A question's answers ride with the permission answer (`answers`, a JSON
/// object), to acpmux unchanged beside the person's decision proof, which on
/// that machine covers them (acpmux `decision_answers_proof`). Before, the
/// verb refused the field, so an answer from the Mac app's pane for a chat on
/// this machine never reached acpmux with its answers and was refused there
/// (#23869). Answers that are not an object, or too large, are a bad request.
#[test]
fn a_question_answer_carries_its_answers_and_proof_to_acpmux_unchanged() {
    let mut fake = FakeAcpmux::start("answers");
    let mux = mux_with(&fake, "asa-answers");
    let surface = agent_tab(&mux, Some(SESSION));
    let mut client = Client::connect(&mux, "answers");
    assert_eq!(attach(&mut client, surface)["ok"], json!(true));
    let _ = fake.frame();
    let _ = client.event(WAIT).expect("the early record");
    fake.notify(
        "_acpmux/permission_pending",
        json!({"sessionId":SESSION,"permissionId":"perm_q","decisionNonce":"n",
               "personInstance":"i","options":[{"optionId":"allow"}]}),
    );
    let _ = client.event(WAIT).expect("the question is shown to the user");
    let nonce = "ab".repeat(32);
    let proof = "cd".repeat(32);
    let answer = |answers: Value| {
        json!({"cmd":"agent-session-permission","surface":surface,"permission_id":"perm_q",
               "option_id":"allow","answers":answers,"decision_nonce":nonce,"person_decision":proof})
    };
    assert_code(&client.request(answer(json!(["B"]))), "agent_session.bad_request");
    // Over 64 KiB, the bound of a prompt too.
    let huge = "x".repeat(64 * 1024);
    assert_code(&client.request(answer(json!({"Which one?": huge}))), "agent_session.bad_request");
    fake.no_frame();
    let reply = client.request(answer(json!({"Which one?":"B","Pick":{"answers":["red"]}})));
    assert_eq!(reply["ok"], json!(true), "{reply}");
    let sent = fake.frame();
    assert_eq!(sent["method"], json!("_acpmux/permission_respond"));
    assert_eq!(
        sent["params"],
        json!({"sessionId":SESSION,"permissionId":"perm_q","optionId":"allow",
               "answers":{"Which one?":"B","Pick":{"answers":["red"]}},
               "_meta":{"acpmux":{"decisionNonce":nonce,"personDecision":proof}}})
    );
}

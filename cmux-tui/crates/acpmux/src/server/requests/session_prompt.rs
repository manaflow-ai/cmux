//! ACP `session/prompt` (`requests.rs`): a prompt to a chat, and its turn's answer.

use super::*;

pub(super) async fn prompt(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
    resolved: Option<Arc<crate::hub::Session>>,
) -> Result<Value, RpcError> {
    // The felt send-to-ack starts here, before the admission wait (`felt.rs`).
    let felt_started = std::time::Instant::now();
    let s = resolved_session(hub, resolved.as_ref(), &params)?;
    // A Cloud VM's part of the send's start trace begins here (`send_trace.rs`).
    crate::send_trace::received(&s.id, &params);
    // A delivery again names the generation it first reached (`outbox.rs`
    // `redeliver_open`): a session purged and made again under its id never runs it.
    if let Some(generation) =
        mux_meta(&params).and_then(|m| m.get("sessionCreatedAt")).and_then(Value::as_u64)
        && s.meta().created_at != generation
    {
        return Err(RpcError::invalid_params(
            "this prompt was sent to an earlier session of this id; it is not run",
        )
        .with_data(json!({"reason": "stale_generation", "retryable": false})));
    }
    // Ordered by the chat's prompt admission from here (`hub/prompt_admission.rs`), bounded.
    let admission = crate::hub::prompt_admission::admit(&s, &hub.scope).await;
    attach(hub, conn, &s.id);
    if person_asks(conn) {
        super::lane_parent::person_wrote(hub, &s);
    }
    let mut blocks = params
        .get("prompt")
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| {
            params
                .get("text")
                .and_then(Value::as_str)
                .map(|t| vec![json!({"type": "text", "text": t})])
        })
        .ok_or_else(|| RpcError::invalid_params("prompt must be an array of content blocks"))?;
    // The words the person sent, before any context is added: whether they took the
    // suggestion the chat showed (`suggestion_gate.rs`).
    let sent_text = crate::suggestion_gate::prompt_text(&blocks);
    // A remote web client may not hide text, directly or through a peer daemon.
    let web = super::remote_guard::control_of(conn.origin, conn.auth, &params)
        == crate::hub::Control::Web;
    // The uploads this prompt names as its own (`attach::blocks_for` uploaded them for it
    // alone): a refusal before the session sees it deletes them, so none is left behind.
    let mut owned = crate::attach::OwnedUploads(if web {
        Vec::new()
    } else {
        crate::prompt_uploads::owned(&s.id, &blocks).await
    });
    crate::prompt_context::apply(mux_meta(&params), web, &mut blocks)?;
    // An `@computer-use` / `@browser-use` the person wrote gets acpmux's fixed note for the
    // agent, from any origin: its text is acpmux's, not the client's (`tool_mentions.rs`).
    crate::tool_mentions::add_note(&mut blocks);
    let provenance = crate::hub::Hub::prompt_provenance(&params, conn.origin, conn.is_trigger())?;
    // The caller's own provenance: a `cmux agent message`, never an inbox item.
    let given_provenance = provenance.is_some();
    // A person's prompt (`author.rs`): the hub stamps who sent it, also for a peer's.
    let author = crate::author::of_prompt(&params)?;
    // A tool's notice (`prompt_provenance::notice_of`): never a Web client's, and a named
    // sender's message, never the person's, whatever else the prompt says.
    let notice = crate::prompt_provenance::notice_checked(&params)?;
    if notice.is_some() && web {
        return Err(crate::prompt_provenance::notice_origin_refused());
    }
    let notice_sender =
        notice.as_ref().and_then(|n| n.get("sender")).and_then(Value::as_str).map(str::to_owned);
    let provenance = match &notice {
        Some(n) => Some(crate::prompt_provenance::notice(n, &s.id)),
        None => provenance.or_else(|| author.as_ref().map(|a| a.provenance())),
    };
    let person_message = crate::author::of_provenance(provenance.as_ref()).is_some();
    // Sent from inside another session (its proven caller token) with none of its own:
    // that session's message, so the receiver's transcript does not show it as the person's.
    // A desktop chat's send the daemon bound to its bridged chat by the socket peer's
    // process tree (`hub/desktop_bridge.rs`) is that chat's, as a caller token's is.
    let bridged = crate::hub::desktop_bridge::bridged_sender(&params).map(str::to_owned);
    let caller = conn.caller().map(str::to_owned).or(bridged);
    let provenance = match (provenance, caller.as_deref()) {
        (None, Some(caller)) if !conn.is_person() && caller != s.id => {
            hub.resolve(caller).ok().map(|from| {
                let name = from.meta().name;
                // Which of its agents: a Claude Code subagent's send says so
                // (`prompt_provenance::FROM_SUBAGENT`), within the proven session.
                crate::prompt_provenance::with_subagent(
                    crate::prompt_provenance::session_message(&from.id, &name, &s.id),
                    &params,
                )
            })
        }
        (provenance, _) => provenance,
    };
    // A relay on this machine outside any session (the lane-gh broker) names its sender by
    // the relay record when it gave no `--from`: always another agent's message, never the
    // person's (`prompt_provenance::FROM_RELAY`).
    let relayed = (conn.origin == super::Origin::Local && conn.caller().is_none())
        .then(|| crate::prompt_provenance::relay_sender(&params))
        .flatten()
        .and_then(|sender| sender.relay)
        .map(|relay| relay.name());
    let declared = crate::hub::declared_sender(&params)?.or(relayed);
    // A prompt a peer daemon forwarded names the machine it came from too
    // (`HOST/NAME`): the host that daemon stamped on its proven caller, read only from
    // a peer daemon's own link, as `messageSender` is below.
    let peer_host = (conn.origin == super::Origin::Peer && conn.auth.peer_daemon() && !web)
        .then(|| mux_meta(&params).and_then(|m| m.pointer("/messageSender/host")))
        .flatten()
        .and_then(Value::as_str);
    let declared = declared.map(|name| crate::hub::on_peer_host(name, peer_host));
    // Keep a caller's `--from` label beside authenticated caller provenance. The label
    // is display-only; `fromSessionId` is still stamped below from the caller token.
    let provenance = provenance.map(|provenance| {
        crate::prompt_provenance::stamp_declared(provenance, declared.as_deref())
    });
    // What another agent's message asks of this chat (`prompt_class.rs`).
    let class = crate::prompt_class::declared(&params)?;
    // The inbox thread its sender named (`hub/inbox.rs`).
    let thread = crate::hub::inbox::explicit_thread(mux_meta(&params))?;
    // A sender that named itself, with neither (`--from`, `ACPMUX_FROM`, a peer daemon
    // forwarding its own session's prompt): that agent's message,
    // so the transcript never shows it as the person's. Not a note a session here sends
    // itself; names are each daemon's own, so a peer's `coordinator` is another session.
    let provenance = provenance.or_else(|| {
        let own = s.meta().name;
        let name = declared
            .as_deref()
            .filter(|name| conn.origin == super::Origin::Peer || *name != own)?;
        // An agent harness's own shell says its harness too (`cli/sender.rs`): only its
        // claim (`claimed.fromHarness`); a peer's is bound below instead.
        let named = crate::prompt_provenance::named_sender(name, &s.id);
        let harness = (conn.origin == super::Origin::Local)
            .then(|| crate::prompt_provenance::declared_harness(&params))
            .flatten()
            .and_then(|declared| declared.harness);
        Some(match harness {
            Some(harness) => crate::prompt_provenance::with_claimed(
                named,
                [(crate::prompt_provenance::FROM_HARNESS, harness)],
            ),
            None => named,
        })
    });
    let provenance = stamp_bound_sender(hub, conn, &s.id, &params, provenance, person_message);
    // A Chief's turn names the Chief (manaflow-ai/cmux#27914), by the session's exact id.
    let provenance = provenance.map(|p| {
        crate::prompt_provenance::stamp_chief(p, |id| {
            hub.resolve(id).ok().filter(|from| from.id == id).map(|from| from.meta())
        })
    });
    // Who the daemon knows sent it, apart from what the sender claims
    // (`prompt_provenance.rs` `verified`, `transport`, `claimed`): the proven person's
    // prompt carries none; one no proof attributes is `unverified`, never the person's.
    let transport = transport_of(conn);
    // The owner's own terminal send, or the app's own pane before it proved the person,
    // claiming no agent, harness or relay: the person's prompt again, though it proves no
    // person (`owner_terminal`, `app_pane_unproven`, the trust boundary).
    let unproven_owner = provenance.is_none()
        && !person_admitted(conn, &params)
        && declared.is_none()
        && (owner_terminal(conn, &params) || app_pane_unproven(conn, &params));
    let provenance = match provenance {
        Some(p) => Some(crate::prompt_provenance::observed(p, transport)),
        None if unproven_owner || person_admitted(conn, &params) => None,
        // A proven session's note to itself: that session's, as the daemon knows.
        None if conn.caller() == Some(s.id.as_str()) => {
            let name = hub.session_name(&s.id);
            // A subagent's report to its own lead's chat names that subagent too.
            let note = crate::prompt_provenance::with_subagent(
                crate::prompt_provenance::session_message(&s.id, &name, &s.id),
                &params,
            );
            Some(crate::prompt_provenance::observed(note, transport))
        }
        None => Some(crate::sender_program::on_unverified(
            crate::prompt_provenance::unverified(&s.id, transport, claimed_labels(conn, &params)),
            &params,
        )),
    };
    // A named sender whose send matched this host's sender token is `verified` by it
    // (`sender_token::label`). A label only: nothing above (the person, the owner's
    // terminal, who may do what) read it, and it makes no prompt the person's.
    let token = crate::sender_token::matched(&params);
    let provenance = provenance.map(|p| crate::sender_token::label(p, token));
    // A peer's prompt keeps its sender and names the peer that passed it on beside it.
    let provenance = provenance.map(|p| match conn.origin {
        super::Origin::Peer => {
            let via = mux_meta(&params).and_then(|m| m.get("via")).and_then(Value::as_str);
            let p = crate::prompt_provenance::forwarded_by_peer(p, via);
            // Its outbox sent it again: it waited for this machine to come back, and
            // the chat wakes for it (`prompt_provenance::waited`).
            let resend = mux_meta(&params).and_then(|m| m.get("resend"));
            if conn.auth.peer_daemon() && resend == Some(&Value::Bool(true)) {
                crate::prompt_provenance::mark_waited(p)
            } else {
                p
            }
        }
        _ => p,
    });
    // The sender's own delivery deadline (`acpmux send --within`, `hub/inbox.rs`
    // "Deadlines"), kept on the provenance so the inbox record keeps it.
    let within = crate::prompt_class::within(&params);
    let provenance = provenance.map(|p| crate::prompt_provenance::mark_within(p, within));
    // Another agent's message with no provenance (`hub/digest.rs`): one that names its
    // sender, or one from a connection that proved it runs in an acpmux session.
    let agent = notice_sender
        .or(declared)
        .or_else(|| conn.caller().map(|id| hub.session_name(id)))
        .filter(|_| !person_message);
    let flag = |k| mux_meta(&params).and_then(|m| m.get(k)).and_then(Value::as_bool);
    let steer = flag("steer").or_else(|| params.get("steer").and_then(Value::as_bool));
    let steer = steer.unwrap_or(false);
    // An outside producer's message that waits for the chat's cold batch (`acpmux send
    // --gather`, `hub/cold_wake.rs`): refused when it could not wait.
    if flag(crate::hub::cold_wake::GATHER_META) == Some(true) {
        let fire =
            mux_meta(&params).and_then(|m| m.pointer("/notice/severity")).and_then(Value::as_str)
                == Some("fire");
        let wakes_now = flag("interrupt") == Some(true)
            || flag("steerNow") == Some(true)
            || flag("wakeOrFail") == Some(true);
        if let Some(refused) =
            crate::hub::cold_wake::gather_refusal(agent.is_some(), class, fire, wakes_now)
        {
            return Err(refused);
        }
    }
    // A subagent's prompt that starts a turn of a lane of its own lead: that turn's answer
    // reaches the subagent (`hub/lane_report_subagents.rs`), so the receiver is told to end
    // its turn with it rather than send it to the lead (`hub/prompt_attribution.rs`). Not
    // one steered into a running turn: that turn's answer goes where its own prompt's does.
    let provenance = provenance.map(|p| {
        let lane_of_caller = conn
            .caller()
            .is_some_and(|c| c != s.id && hub.lane_report_parent(&s.id).as_deref() == Some(c));
        let steers_in = steer && s.turn().is_some();
        if steers_in || !lane_of_caller {
            return p;
        }
        crate::prompt_provenance::subagent_gets_reply(p)
    });
    let prompt_id = mux_meta(&params)
        .and_then(|m| m.get("promptId"))
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
        .map(str::to_owned);
    let message_id = mux_meta(&params)
        .and_then(|m| m.get("messageId"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned);
    // Only a peer daemon may carry this metadata.  A local or web caller can
    // name arbitrary `_meta` fields, but sender identity is stamped by the
    // proven caller/provenance below; accepting it here would let a client
    // forge durable message records in another session's journal. A paired
    // `client` device is served as a peer too (`pairing::origin_of`), so the
    // proof is the peer token, not the origin.
    let message_sender = (conn.origin == super::Origin::Peer && conn.auth.peer_daemon() && !web)
        .then(|| mux_meta(&params).and_then(|m| m.get("messageSender")))
        .flatten()
        .and_then(|sender| {
            let mut sender: crate::protocol::MessageSender =
                serde_json::from_value(sender.clone()).ok()?;
            sender.display_name = sender.display_name.filter(|n| crate::session_handle::valid(n));
            (!sender.name.is_empty() && !sender.session_id.is_empty())
                .then(|| serde_json::to_value(sender).ok())
                .flatten()
        });
    let mut on_accepted = Some(composer::on_accepted(hub, conn, &s, &params)?);
    // A key replaces its sender's queued prompts (`supersede.rs`), which knows agents and
    // the owner only: a person's prompt neither replaces nor is replaced.
    let supersede = crate::hub::supersede_key(&params)?.filter(|_| !person_message);
    let supersede_set = supersede.is_some();
    let inbox_on = match tokio::time::timeout_at(admission.answer_due(), hub.config.read()).await {
        Ok(config) => config.agent_inbox(),
        Err(_) => return Err(crate::hub::auto_resume::retry_turn::busy()),
    };
    // Files uploaded first and named in the prompt get their bytes back here, before
    // anything reads them (`prompt_uploads.rs`). A prompt id the chat took already goes on
    // to `prompt_with`, which answers with its first run even once its uploads are gone
    // (`turns.rs` reads any left at dispatch, so none reaches an agent without its bytes).
    if crate::prompt_uploads::any(&blocks) {
        let (hub, s, id) = (hub.clone(), s.clone(), prompt_id.clone());
        let resend = flag("resend") == Some(true);
        let resolved = tokio::task::spawn_blocking(move || {
            match crate::prompt_uploads::resolve(&s.id, web, &mut blocks) {
                Err(_) if id.as_deref().is_some_and(|id| hub.knows_prompt(&s, id, resend)) => {
                    Ok(blocks)
                }
                result => result.map(|()| blocks),
            }
        });
        blocks = match tokio::time::timeout_at(admission.answer_due(), resolved).await {
            Ok(result) => result.map_err(|e| RpcError::internal(e.to_string()))??,
            Err(_) => return Err(crate::hub::auto_resume::retry_turn::busy()),
        };
    }
    // Files sent with the message (`acpmux send --attach`), after every check that can
    // refuse it: saved in the session's uploads, and what the agent gets put in their
    // place (`attach.rs`).
    let mut saved = None;
    if crate::attach::any(&blocks) {
        crate::attach::check_wire(&params)?;
        let id = s.id.clone();
        let received = tokio::task::spawn_blocking(move || {
            crate::attach::receive(&id, web, &mut blocks).map(|saved| (blocks, saved))
        });
        (blocks, saved) = match tokio::time::timeout_at(admission.answer_due(), received).await {
            Ok(result) => result.map_err(|e| RpcError::internal(e.to_string()))??,
            Err(_) => return Err(crate::hub::auto_resume::retry_turn::busy()),
        };
    }
    // From here the prompt's own uploads go only if the session refuses it.
    let saved = crate::attach::Saved::with_owned(saved, &s.id, owned.take());
    // Where the send came from, as its harness says and the daemon checked: a record of
    // its own beside the prompt, written once the prompt is kept, never part of who sent
    // it (`sender_harness.rs`). Not from the app or a Web client, which name no harness.
    if matches!(conn.origin, super::Origin::Local | super::Origin::Peer)
        && let Some(claim) = crate::sender_harness::recorded(&params, prompt_id.as_deref())
    {
        let (hub, s) = (hub.clone(), s.clone());
        let write = move |claim: Value| {
            hub.append(&s, "mux", crate::sender_harness::RECORD_KIND, claim);
        };
        on_accepted = crate::sender_harness::on_kept(claim, write, on_accepted);
    }
    // The caller waits for this prompt's reply and prints it (`readsReply`, `acpmux run`,
    // `acpmux send --wait`): when the session a lane reports to sent it, that turn is
    // read, and no lane report of it goes to the same session again
    // (`hub/lane_report_reads.rs`). Held until this request returns.
    // It reads while its connection is open and it has not cancelled this request: a
    // cancel revokes it (`prompt_cancel.rs`, review F2 of #41361).
    let reads_reply = flag(crate::cli::output::READS_REPLY_META) == Some(true);
    let reader = (reads_reply || flag("wakeOrFail") == Some(true))
        .then(|| super::prompt_cancel::ReaderGone::new(hub, conn.ended.subscribe()));
    let reply_reader = reader
        .as_ref()
        .filter(|_| reads_reply)
        .and_then(|r| hub.lane_report_reply_reader(conn.caller(), &s.id, r.subscribe()));
    if let Some(reader) = &reply_reader {
        on_accepted = Some(reader.watch(on_accepted));
    }
    let cloud_turn: Option<crate::cloud_rewind::CloudTurnEnvelope> = match params.get("cloud_turn")
    {
        Some(value) => Some(
            serde_json::from_value(value.clone())
                .map_err(|_| RpcError::invalid_params("cloud_turn is malformed"))?,
        ),
        None => None,
    };
    if let Some(envelope) = cloud_turn.as_ref() {
        if *conn.ended.borrow()
            || envelope.purpose != "execute"
            || envelope.session != s.id
            || prompt_id.as_deref() != Some(envelope.turn.as_str())
        {
            return Err(RpcError::invalid_params("cloud execution does not match this prompt"));
        }
        s.validate_prepared(
            envelope.turn.as_str(),
            envelope.turn.as_str(),
            envelope.generation,
            &envelope.attempt_id,
            Some(&conn.id),
        )
        .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    }
    let on_accepted = super::felt::time_ack(felt_started, on_accepted);
    let mut opts = crate::hub::PromptOptions {
        race_guard: None,
        admission: Some(admission),
        cloud_turn,
        prompt_id,
        message_id,
        message_sender,
        on_accepted: match &saved {
            Some(saved) => saved.watch(on_accepted),
            None => on_accepted,
        },
        resend: flag("resend") == Some(true),
        control: super::remote_guard::control_of(conn.origin, conn.auth, &params),
        cloud_mobile: params.pointer("/_meta/acpmux/via").and_then(Value::as_str)
            == Some("cloud-mobile"),
        trust_gate: super::trust_gate::gated(conn.origin, &params),
        steer_only: flag("steerOnly") == Some(true),
        interrupt: steer && flag("interrupt") == Some(true),
        steer_now: steer && flag("steerNow") == Some(true),
        interrupt_turn: None,
        provenance,
        // The peer's word only on a peer daemon's own link (`person_admitted`): a paired
        // machine's client connection is served as Peer too, and its flag proves nothing.
        human_authenticated: person_message
            && (conn.is_person()
                || (conn.origin == super::Origin::Peer && person_admitted(conn, &params))),
        unproven_owner,
        coach: None,
        agent,
        class,
        after_turn: None,
        fired: None,
        supersede,
        display_parts: {
            let parts = crate::hub::prompt_images::validated_display_parts(
                mux_meta(&params).and_then(|meta| meta.get("inlineParts")),
                &blocks,
            );
            (!parts.is_empty()).then(|| {
                let mut parts: Vec<_> = parts.into_iter().collect();
                parts.sort_by_key(|(index, _)| *index);
                Value::Array(
                    parts
                        .into_iter()
                        .map(|(index, mut part)| {
                            part["blockIndex"] = Value::Number((index as u64).into());
                            part
                        })
                        .collect(),
                )
            })
        },
        full_access_device: super::remote_guard::sending_device(conn, &params),
        no_queue: false,
        admitted: false,
        send_now: false,
        thread,
        wake_or_fail: flag("wakeOrFail") == Some(true),
        // Only a caller that waits for the reply and prints it reads it
        // (`hub/question_replies.rs`); an outbox delivery's open request reads nothing.
        reply_reader: reader.as_ref().map(super::prompt_cancel::ReaderGone::subscribe),
        inbox: inbox_on
            && crate::hub::inbox::plain_send(
                flag("teamMessage") == Some(true),
                supersede_set,
                flag("steerOnly") == Some(true),
                given_provenance,
            ),
    };
    // An unverified prompt names no other sender: its activity is counted as an
    // unnamed prompt's was (`prompt_provenance::is_unverified`).
    let agent_message = opts.provenance.is_some()
        && !crate::prompt_provenance::is_unverified(opts.provenance.as_ref())
        && !person_message;
    super::agent_messages::person_prompt(hub, conn, &s, agent_message).await;
    // The person's own `acpmux send` names the machine it ran on (`cli/sender.rs`): the
    // recorded client says it (`acpmux-cli#…@big-red`), and the transcript shows "via CLI on
    // big-red" under their prompt. An agent's message names its sender instead.
    let host = crate::prompt_provenance::cli_host(&params)
        .filter(|_| !agent_message && opts.agent.is_none());
    let client = match host {
        Some(host) => format!("{}@{host}", conn.label()),
        None => conn.label(),
    };
    // A correction from the person, proven by the connection, never by a label: a send
    // from the owner's terminal (`owner_terminal`) proves nobody (`prompt_coach.rs`).
    if !agent_message && person_admitted(conn, &params) {
        opts.coach = Some(sent_text.clone());
    }
    // The person's answer to the suggestion the chat showed, if any (`suggestion_gate.rs`).
    if !agent_message && person_asks(conn) {
        crate::suggestion_gate::note_prompt(
            &hub.suggestion_gate,
            &s.id,
            &sent_text,
            crate::suggestion_gate::marked_taken(&params),
        );
        crate::memory_inbox::note_prompt(&s.id, &sent_text);
    } else {
        // Another agent's message answers nothing the person was shown.
        crate::suggestion_gate::withdraw(&hub.suggestion_gate, &s.id);
    }
    // A `$/cancel_request` of this request stops its prompt, and the prompt runs on to
    // its turn's end, never dropped half way (`prompt_cancel.rs`).
    let stop = super::prompt_cancel::PromptStop::new(hub, &s, reader);
    opts.on_accepted = stop.watch(opts.on_accepted.take());
    let hub = hub.clone();
    let run = async move {
        let answer = heap(|| hub.prompt_with(&s, blocks, &client, steer, opts)).await;
        // The turn ended (its read was decided) before the answer came back.
        drop(reply_reader);
        if let Some(saved) = saved {
            saved.settle(&hub, &answer).await;
        }
        answer
    };
    super::prompt_cancel::finish_on_cancel(run, stop).await
}

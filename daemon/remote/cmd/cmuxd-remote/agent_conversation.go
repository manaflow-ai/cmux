package main

// agent.* RPC verbs: the normalized agent conversation layer
// (daemon/remote/agentconv, protocol in docs/agent-conversation-protocol.md).
// agent.session.open replays a transcript as a snapshot frame and then tails
// it, pushing {event: "agent.session.event", subscription_id, payload} frames
// until agent.session.close or connection teardown.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/manaflow-ai/cmux/daemon/remote/agentconv"
)

type agentSubscriptionState struct {
	subscription *agentconv.Subscription
}

func (s *rpcServer) handleAgentSessionsList(req rpcRequest) rpcResponse {
	query := agentconv.ListQuery{
		Provider: agentconv.ProviderID(stringParam(req.Params, "provider")),
		Cwd:      stringParam(req.Params, "cwd"),
	}
	if limit, ok := req.Params["limit"].(float64); ok {
		query.Limit = int(limit)
	}
	sessions := agentconv.ListSessions(agentconv.DefaultRoots(), query)
	if sessions == nil {
		sessions = []agentconv.SessionRef{}
	}
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{"sessions": sessions}}
}

func (s *rpcServer) handleAgentSessionOpen(req rpcRequest) rpcResponse {
	provider := agentconv.ProviderID(stringParam(req.Params, "provider"))
	if provider == "" {
		return agentParamError(req, "provider is required")
	}
	transcriptPath := stringParam(req.Params, "transcript_path")
	if transcriptPath == "" {
		sessionID := stringParam(req.Params, "session_id")
		if sessionID == "" {
			return agentParamError(req, "session_id or transcript_path is required")
		}
		resolved, ok := agentconv.ResolveTranscriptPath(
			agentconv.DefaultRoots(), provider, sessionID, stringParam(req.Params, "cwd"))
		if !ok {
			return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{
				Code:    "not_found",
				Message: fmt.Sprintf("no %s transcript found for session %s", provider, sessionID),
			}}
		}
		transcriptPath = resolved
	}
	subscription, session, err := agentconv.Open(agentconv.Config{
		Provider:       provider,
		TranscriptPath: transcriptPath,
	})
	if err != nil {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{
			Code:    "open_failed",
			Message: err.Error(),
		}}
	}

	s.mu.Lock()
	subscriptionID := fmt.Sprintf("agent-%d", s.nextAgentSubID)
	s.nextAgentSubID++
	if s.agentSubs == nil {
		s.agentSubs = map[string]*agentSubscriptionState{}
	}
	s.agentSubs[subscriptionID] = &agentSubscriptionState{subscription: subscription}
	s.mu.Unlock()

	go s.pumpAgentEvents(subscriptionID, subscription)

	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{
		"subscription_id": subscriptionID,
		"session":         session,
	}}
}

func (s *rpcServer) handleAgentSessionClose(req rpcRequest) rpcResponse {
	subscriptionID := stringParam(req.Params, "subscription_id")
	if subscriptionID == "" {
		return agentParamError(req, "subscription_id is required")
	}
	s.mu.Lock()
	state := s.agentSubs[subscriptionID]
	delete(s.agentSubs, subscriptionID)
	s.mu.Unlock()
	if state == nil {
		return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{
			Code:    "not_found",
			Message: "unknown subscription",
		}}
	}
	state.subscription.Close()
	return rpcResponse{ID: req.ID, OK: true, Result: map[string]any{"closed": true}}
}

func (s *rpcServer) pumpAgentEvents(subscriptionID string, subscription *agentconv.Subscription) {
	for event := range subscription.Events {
		payload, err := json.Marshal(event)
		if err != nil {
			continue
		}
		if err := s.frameWriter.writeEvent(rpcEvent{
			Event:          "agent.session.event",
			SubscriptionID: subscriptionID,
			Payload:        payload,
		}); err != nil {
			// The connection is gone; stop tailing.
			s.mu.Lock()
			delete(s.agentSubs, subscriptionID)
			s.mu.Unlock()
			subscription.Close()
			return
		}
	}
}

func (s *rpcServer) closeAgentSubscriptions() {
	s.mu.Lock()
	subscriptions := make([]*agentSubscriptionState, 0, len(s.agentSubs))
	for id, state := range s.agentSubs {
		delete(s.agentSubs, id)
		subscriptions = append(subscriptions, state)
	}
	s.mu.Unlock()
	for _, state := range subscriptions {
		state.subscription.Close()
	}
}

func stringParam(params map[string]any, key string) string {
	value, _ := params[key].(string)
	return strings.TrimSpace(value)
}

func agentParamError(req rpcRequest, message string) rpcResponse {
	return rpcResponse{ID: req.ID, OK: false, Error: &rpcError{
		Code:    "invalid_request",
		Message: message,
	}}
}

package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"time"
)

type wsSignedLeaseClaims struct {
	Version       int    `json:"v"`
	Kind          string `json:"kind"`
	Audience      string `json:"aud"`
	SessionID     string `json:"sid"`
	ExpiresAtUnix int64  `json:"exp"`
	SingleUse     bool   `json:"single_use"`
	JTI           string `json:"jti"`
}

var (
	errWSSignedLeaseUnavailable = errors.New("signed attach auth unavailable")
	errWSSignedLeaseInvalid     = errors.New("signed attach auth rejected")
	wsSignedLeaseMu             sync.Mutex
	wsSignedLeaseUsed           = map[string]int64{}
)

func authorizeWebSocketAuth(cfg wsPTYServerConfig, kind string, auth wsAuthFrame) error {
	if verifySignedWebSocketLease(cfg, kind, auth) == nil {
		return nil
	}

	path := cfg.PTYAuthLeaseFile
	if kind == "rpc" {
		path = cfg.RPCAuthLeaseFile
	}
	return consumeWebSocketLease(path, auth)
}

func verifySignedWebSocketLease(cfg wsPTYServerConfig, kind string, auth wsAuthFrame) error {
	publicKey, err := parseSignedAuthPublicKey(cfg.SignedAuthPublicKey)
	if err != nil {
		return err
	}
	audience, err := readSignedAuthAudience(cfg.SignedAuthAudienceFile)
	if err != nil {
		return err
	}
	payloadPart, signaturePart, ok := strings.Cut(auth.Token, ".")
	if !ok || payloadPart == "" || signaturePart == "" {
		return errWSSignedLeaseInvalid
	}
	signature, err := base64.RawURLEncoding.DecodeString(signaturePart)
	if err != nil {
		return errWSSignedLeaseInvalid
	}
	if !ed25519.Verify(publicKey, []byte(payloadPart), signature) {
		return errWSSignedLeaseInvalid
	}
	payload, err := base64.RawURLEncoding.DecodeString(payloadPart)
	if err != nil {
		return errWSSignedLeaseInvalid
	}
	var claims wsSignedLeaseClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return errWSSignedLeaseInvalid
	}
	if claims.Version != 1 ||
		claims.Kind != kind ||
		claims.Audience != audience ||
		strings.TrimSpace(claims.SessionID) == "" ||
		claims.SessionID != auth.SessionID ||
		strings.TrimSpace(claims.JTI) == "" ||
		claims.ExpiresAtUnix <= time.Now().Unix() {
		return errWSSignedLeaseInvalid
	}
	if kind == "pty" && !claims.SingleUse {
		return errWSSignedLeaseInvalid
	}
	if claims.SingleUse {
		return consumeSignedLeaseJTI(claims.JTI, claims.ExpiresAtUnix)
	}
	return nil
}

func parseSignedAuthPublicKey(text string) (ed25519.PublicKey, error) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return nil, errWSSignedLeaseUnavailable
	}
	decoded, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		decoded, err = base64.RawStdEncoding.DecodeString(trimmed)
	}
	if err != nil {
		decoded, err = base64.RawURLEncoding.DecodeString(trimmed)
	}
	if err != nil {
		decoded, err = base64.URLEncoding.DecodeString(trimmed)
	}
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errWSSignedLeaseUnavailable
	}
	return ed25519.PublicKey(decoded), nil
}

func readSignedAuthAudience(path string) (string, error) {
	trimmedPath := strings.TrimSpace(path)
	if trimmedPath == "" {
		return "", errWSSignedLeaseUnavailable
	}
	data, err := os.ReadFile(trimmedPath)
	if err != nil {
		return "", errWSSignedLeaseUnavailable
	}
	audience := strings.TrimSpace(string(data))
	if audience == "" {
		return "", errWSSignedLeaseUnavailable
	}
	return audience, nil
}

func consumeSignedLeaseJTI(jti string, expiresAtUnix int64) error {
	now := time.Now().Unix()
	wsSignedLeaseMu.Lock()
	defer wsSignedLeaseMu.Unlock()
	for used, expiry := range wsSignedLeaseUsed {
		if expiry <= now {
			delete(wsSignedLeaseUsed, used)
		}
	}
	if _, exists := wsSignedLeaseUsed[jti]; exists {
		return errWSSignedLeaseInvalid
	}
	wsSignedLeaseUsed[jti] = expiresAtUnix
	return nil
}

package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
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
	wsSignedLeaseUsedDir        = "/tmp/cmux/signed-attach-jti"
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
	if err := cleanupSignedLeaseJTIFiles(now); err != nil {
		return errWSSignedLeaseInvalid
	}
	path := signedLeaseJTIPath(jti)
	if existing, err := os.ReadFile(path); err == nil {
		expiry, parseErr := strconv.ParseInt(strings.TrimSpace(string(existing)), 10, 64)
		if parseErr == nil && expiry > now {
			return errWSSignedLeaseInvalid
		}
		_ = os.Remove(path)
	} else if !errors.Is(err, os.ErrNotExist) {
		return errWSSignedLeaseInvalid
	}
	if err := os.MkdirAll(wsSignedLeaseUsedDir, 0o700); err != nil {
		return errWSSignedLeaseInvalid
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return errWSSignedLeaseInvalid
	}
	_, writeErr := file.WriteString(strconv.FormatInt(expiresAtUnix, 10) + "\n")
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(path)
		return errWSSignedLeaseInvalid
	}
	return nil
}

func cleanupSignedLeaseJTIFiles(now int64) error {
	entries, err := os.ReadDir(wsSignedLeaseUsedDir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		path := filepath.Join(wsSignedLeaseUsedDir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		expiry, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
		if err == nil && expiry <= now {
			_ = os.Remove(path)
		}
	}
	return nil
}

func signedLeaseJTIPath(jti string) string {
	sum := sha256.Sum256([]byte(jti))
	return filepath.Join(wsSignedLeaseUsedDir, hex.EncodeToString(sum[:]))
}

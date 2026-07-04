package main

import (
	"context"
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

const (
	wsSignedLeaseJTIBucketSeconds    int64 = 60
	wsSignedLeaseJTICleanupFrequency       = time.Minute
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
	wsSignedLeaseMu.Lock()
	defer wsSignedLeaseMu.Unlock()
	bucketDir := signedLeaseJTIBucketDir(expiresAtUnix)
	if err := os.MkdirAll(bucketDir, 0o700); err != nil {
		return errWSSignedLeaseInvalid
	}
	path := signedLeaseJTIPath(jti, expiresAtUnix)
	if _, err := os.Stat(path); err == nil {
		return errWSSignedLeaseInvalid
	} else if !errors.Is(err, os.ErrNotExist) {
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

func startSignedLeaseJTICleanup(ctx context.Context) {
	cleanupExpiredSignedLeaseJTIBuckets(time.Now().Unix())
	ticker := time.NewTicker(wsSignedLeaseJTICleanupFrequency)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				cleanupExpiredSignedLeaseJTIBuckets(now.Unix())
			}
		}
	}()
}

func cleanupExpiredSignedLeaseJTIBuckets(now int64) {
	currentBucket := signedLeaseJTIBucket(now)
	entries, err := os.ReadDir(wsSignedLeaseUsedDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		bucket, err := strconv.ParseInt(entry.Name(), 10, 64)
		if err != nil || bucket >= currentBucket {
			continue
		}
		_ = os.RemoveAll(filepath.Join(wsSignedLeaseUsedDir, entry.Name()))
	}
}

func signedLeaseJTIPath(jti string, expiresAtUnix int64) string {
	sum := sha256.Sum256([]byte(jti))
	return filepath.Join(signedLeaseJTIBucketDir(expiresAtUnix), hex.EncodeToString(sum[:]))
}

func signedLeaseJTIBucketDir(expiresAtUnix int64) string {
	return filepath.Join(wsSignedLeaseUsedDir, strconv.FormatInt(signedLeaseJTIBucket(expiresAtUnix), 10))
}

func signedLeaseJTIBucket(unixSeconds int64) int64 {
	if unixSeconds <= 0 {
		return 0
	}
	return unixSeconds / wsSignedLeaseJTIBucketSeconds
}

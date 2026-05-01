package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

var (
	ErrMalformedTicket  = errors.New("malformed ticket")
	ErrInvalidSignature = errors.New("invalid ticket signature")
	ErrExpiredTicket    = errors.New("ticket expired")
	ErrWrongServer      = errors.New("ticket server mismatch")
)

type TicketClaims struct {
	ServerID     string   `json:"server_id"`
	TeamID       string   `json:"team_id"`
	SessionID    string   `json:"session_id"`
	AttachmentID string   `json:"attachment_id"`
	Capabilities []string `json:"capabilities"`
	ExpiresAt    int64    `json:"exp"`
	Nonce        string   `json:"nonce"`
}

func SignTicket(claims TicketClaims, secret []byte) (string, error) {
	payload, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}

	encodedPayload := base64.RawURLEncoding.EncodeToString(payload)
	signature := sign([]byte(encodedPayload), secret)
	encodedSignature := base64.RawURLEncoding.EncodeToString(signature)
	return encodedPayload + "." + encodedSignature, nil
}

func VerifyTicket(token string, secret []byte, expectedServerID string) (TicketClaims, error) {
	var claims TicketClaims

	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return claims, ErrMalformedTicket
	}

	expectedSignature := sign([]byte(parts[0]), secret)
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return claims, ErrMalformedTicket
	}
	if !hmac.Equal(signature, expectedSignature) {
		return claims, ErrInvalidSignature
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return claims, ErrMalformedTicket
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return claims, ErrMalformedTicket
	}
	if claims.ExpiresAt <= time.Now().Unix() {
		return claims, ErrExpiredTicket
	}
	if expectedServerID != "" && claims.ServerID != expectedServerID {
		return claims, ErrWrongServer
	}

	return claims, nil
}

func sign(payload, secret []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write(payload)
	return mac.Sum(nil)
}

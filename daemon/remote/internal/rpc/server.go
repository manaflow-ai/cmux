package rpc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

type Handler func(Request) Response

type Server struct {
	handler Handler
}

func NewServer(handler Handler) *Server {
	return &Server{handler: handler}
}

func (s *Server) Serve(stdin io.Reader, stdout io.Writer) error {
	reader := bufio.NewReaderSize(stdin, 64*1024)
	writer := bufio.NewWriter(stdout)
	defer writer.Flush()

	for {
		line, oversized, readErr := ReadFrame(reader, MaxFrameBytes)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
		if oversized {
			if err := WriteResponse(writer, Response{
				OK: false,
				Error: &Error{
					Code:    "invalid_request",
					Message: "request frame exceeds maximum size",
				},
			}); err != nil {
				return err
			}
			continue
		}

		line = bytes.TrimSuffix(line, []byte{'\n'})
		line = bytes.TrimSuffix(line, []byte{'\r'})
		if len(line) == 0 {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			if err := WriteResponse(writer, Response{
				OK: false,
				Error: &Error{
					Code:    "invalid_request",
					Message: "invalid JSON request",
				},
			}); err != nil {
				return err
			}
			continue
		}

		if err := WriteResponse(writer, s.handler(req)); err != nil {
			return err
		}
	}
}

package rpc

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
)

const MaxFrameBytes = 4 * 1024 * 1024

type Request struct {
	ID     any            `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Response struct {
	ID     any    `json:"id,omitempty"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  *Error `json:"error,omitempty"`
}

func ReadFrame(reader *bufio.Reader, maxBytes int) ([]byte, bool, error) {
	frame := make([]byte, 0, 1024)
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(chunk) > 0 {
			if len(frame)+len(chunk) > maxBytes {
				if errors.Is(err, bufio.ErrBufferFull) {
					if drainErr := discardUntilNewline(reader); drainErr != nil && !errors.Is(drainErr, io.EOF) {
						return nil, false, drainErr
					}
				}
				return nil, true, nil
			}
			frame = append(frame, chunk...)
		}

		if err == nil {
			return frame, false, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) {
			if len(frame) == 0 {
				return nil, false, io.EOF
			}
			return frame, false, nil
		}
		return nil, false, err
	}
}

func WriteResponse(writer *bufio.Writer, resp Response) error {
	payload, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	if _, err := writer.Write(payload); err != nil {
		return err
	}
	if err := writer.WriteByte('\n'); err != nil {
		return err
	}
	return writer.Flush()
}

func discardUntilNewline(reader *bufio.Reader) error {
	for {
		_, err := reader.ReadSlice('\n')
		if err == nil || errors.Is(err, io.EOF) {
			return err
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return err
	}
}

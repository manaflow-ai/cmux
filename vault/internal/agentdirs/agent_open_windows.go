//go:build windows

package agentdirs

import (
	"fmt"
	"os"
)

func OpenRegularFileNoSymlink(path string) (*os.File, os.FileInfo, error) {
	return nil, nil, fmt.Errorf("symlink-safe transcript reads are not supported on windows: %s", path)
}

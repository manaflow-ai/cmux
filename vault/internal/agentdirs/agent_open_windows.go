//go:build windows

package agentdirs

import (
	"fmt"
	"os"
	"syscall"
)

func OpenRegularFileNoSymlink(path string) (*os.File, os.FileInfo, error) {
	pathp, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, nil, err
	}
	handle, err := syscall.CreateFile(
		pathp,
		syscall.GENERIC_READ,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil,
		syscall.OPEN_EXISTING,
		syscall.FILE_ATTRIBUTE_NORMAL|syscall.FILE_FLAG_OPEN_REPARSE_POINT,
		0,
	)
	if err != nil {
		return nil, nil, err
	}
	file := os.NewFile(uintptr(handle), path)
	if file == nil {
		_ = syscall.CloseHandle(handle)
		return nil, nil, fmt.Errorf("failed to open %s", path)
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		_ = file.Close()
		return nil, nil, fmt.Errorf("%s is a symlink", path)
	}
	if data, ok := info.Sys().(*syscall.Win32FileAttributeData); ok &&
		data.FileAttributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		_ = file.Close()
		return nil, nil, fmt.Errorf("%s is a reparse point", path)
	}
	if !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, nil, fmt.Errorf("%s is not a regular file", path)
	}
	return file, info, nil
}

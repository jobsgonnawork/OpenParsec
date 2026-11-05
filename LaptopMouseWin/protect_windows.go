package main

import (
	"encoding/base64"
	"unsafe"

	"golang.org/x/sys/windows"
)

// the Parsec session is a credential, so it is kept encrypted for this Windows user (DPAPI)

func protectSecret(plain string) (string, error) {
	in := windows.DataBlob{Size: uint32(len(plain)), Data: unsafe.StringData(plain)}
	var out windows.DataBlob
	if err := windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return "", err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return base64.StdEncoding.EncodeToString(unsafe.Slice(out.Data, out.Size)), nil
}

func unprotectSecret(stored string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(stored)
	if err != nil || len(raw) == 0 {
		return "", err
	}
	in := windows.DataBlob{Size: uint32(len(raw)), Data: &raw[0]}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return "", err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return string(unsafe.Slice(out.Data, out.Size)), nil
}

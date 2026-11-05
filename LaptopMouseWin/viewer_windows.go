package main

/*
#cgo CFLAGS: -I${SRCDIR}/sdk -O2
#cgo LDFLAGS: -ld3d11 -ldxgi -ldxguid -luuid -lgdi32 -luser32
#include <stdlib.h>
#include "viewer.h"
*/
import "C"

import (
	"bytes"
	_ "embed"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"unsafe"
)

// fetched by sdk/fetch.sh, Parsec SDK 6.0 for Windows x64
//
//go:embed sdk/parsec.dll
var parsecDLL []byte

type viewer struct {
	mu      sync.Mutex
	ready   bool
	initErr error
	cfg     *videoConfigState
	onState func(status int32)
	// from open until the window's thread ends, so two opens can't race to make two windows
	running atomic.Bool
}

var screen = &viewer{cfg: &videoConfigState{}}

// writes the embedded parsec.dll next to the settings and loads it, once
func (v *viewer) init() error {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.ready || v.initErr != nil {
		return v.initErr
	}
	path := filepath.Join(configDir(), "parsec.dll")
	if old, err := os.ReadFile(path); err != nil || !bytes.Equal(old, parsecDLL) {
		if err := os.WriteFile(path, parsecDLL, 0o600); err != nil {
			v.initErr = fmt.Errorf("can't write %s: %w", path, err)
			return v.initErr
		}
	}
	cDir := C.CString(configDir())
	defer C.free(unsafe.Pointer(cDir))
	if r := C.viewer_init(cDir); r != 0 {
		v.initErr = fmt.Errorf("can't load the Parsec SDK (%d)", int(r))
		return v.initErr
	}
	v.ready = true
	return nil
}

// open shows the 2nd screen, connecting with the saved session; it does nothing if it is open
func (v *viewer) open(session, peer, display string, width, height int) {
	if err := v.init(); err != nil {
		log.Printf("viewer: %v", err)
		showMessage("The 2nd screen can't start: " + err.Error())
		return
	}
	if !v.running.CompareAndSwap(false, true) {
		return
	}
	v.cfg.reset(display, width, height)
	cSession, cPeer := C.CString(session), C.CString(peer)
	started := make(chan struct{})
	go func() {
		// the window and its message loop belong to this thread
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer C.free(unsafe.Pointer(cSession))
		defer C.free(unsafe.Pointer(cPeer))
		defer v.running.Store(false)
		close(started)
		C.viewer_run(cSession, cPeer)
	}()
	<-started
}

func (v *viewer) close()       { C.viewer_close() }
func (v *viewer) isOpen() bool { return v.running.Load() }

// stream 1 has drawn a frame
func (v *viewer) isShowing() bool { return C.viewer_state() == 2 }
func (v *viewer) cursorAway()     { C.viewer_cursor_away() }

func sendUserData(id uint32, msg string) {
	c := C.CString(msg)
	defer C.free(unsafe.Pointer(c))
	C.viewer_send_user_data(C.uint32_t(id), c)
}

//export goViewerLog
func goViewerLog(msg *C.char) {
	log.Print("[screen] ", C.GoString(msg))
}

//export goViewerUserData
func goViewerUserData(id C.uint32_t, msg *C.char) {
	if reply, ok := screen.cfg.handle(uint32(id), C.GoString(msg)); ok {
		log.Printf("[screen] video config sent: %s", reply)
		sendUserData(userDataSetVideoConfig, reply)
	}
}

//export goViewerStatus
func goViewerStatus(status C.int32_t) {
	if screen.onState != nil {
		screen.onState(int32(status))
	}
}

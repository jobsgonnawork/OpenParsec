package main

import (
	"syscall"
	"unsafe"
)

var (
	user32               = syscall.NewLazyDLL("user32.dll")
	procSendInput        = user32.NewProc("SendInput")
	procGetCursorPos     = user32.NewProc("GetCursorPos")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	procSetDPIAware      = user32.NewProc("SetProcessDPIAware")
)

const (
	inputMouse = 0

	mouseMove       = 0x0001
	mouseLeftDown   = 0x0002
	mouseLeftUp     = 0x0004
	mouseRightDown  = 0x0008
	mouseRightUp    = 0x0010
	mouseMiddleDown = 0x0020
	mouseMiddleUp   = 0x0040
	mouseXDown      = 0x0080
	mouseXUp        = 0x0100
	mouseWheel      = 0x0800
	mouseHWheel     = 0x1000
	mouseAbsolute   = 0x8000

	smCxScreen = 0
	smCyScreen = 1
)

// INPUT with a MOUSEINPUT, as laid out on 64-bit Windows
type mouseInputEvent struct {
	kind      uint32
	_         uint32
	dx, dy    int32
	mouseData uint32
	flags     uint32
	time      uint32
	extraInfo uintptr
}

type point struct{ x, y int32 }

type winMouse struct{}

func newMouse() mouse {
	// real pixels, not the DPI scaled ones a plain process sees
	procSetDPIAware.Call()
	return winMouse{}
}

func (winMouse) screen() (int, int) {
	w, _, _ := procGetSystemMetrics.Call(smCxScreen)
	h, _, _ := procGetSystemMetrics.Call(smCyScreen)
	return int(w), int(h)
}

func (winMouse) position() (int, int) {
	var p point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&p)))
	return int(p.x), int(p.y)
}

func send(e mouseInputEvent) {
	e.kind = inputMouse
	procSendInput.Call(1, uintptr(unsafe.Pointer(&e)), unsafe.Sizeof(e))
}

// absolute moves are real input the Parsec window sees, and skip Windows pointer acceleration
func (m winMouse) moveTo(x, y int) {
	w, h := m.screen()
	if w < 2 || h < 2 {
		return
	}
	send(mouseInputEvent{
		dx:    int32(x * 65535 / (w - 1)),
		dy:    int32(y * 65535 / (h - 1)),
		flags: mouseMove | mouseAbsolute,
	})
}

func (winMouse) button(b byte, pressed bool) {
	var flags, data uint32
	switch b {
	case 1:
		flags = pick(pressed, mouseLeftDown, mouseLeftUp)
	case 2:
		flags = pick(pressed, mouseMiddleDown, mouseMiddleUp)
	case 3:
		flags = pick(pressed, mouseRightDown, mouseRightUp)
	case 4, 5:
		flags = pick(pressed, mouseXDown, mouseXUp)
		data = uint32(b - 3)
	default:
		return
	}
	send(mouseInputEvent{flags: flags, mouseData: data})
}

// Parsec's negative y scrolls up, Windows' positive mouseData does
func (winMouse) wheel(dx, dy int) {
	if dy != 0 {
		send(mouseInputEvent{flags: mouseWheel, mouseData: uint32(int32(-dy))})
	}
	if dx != 0 {
		send(mouseInputEvent{flags: mouseHWheel, mouseData: uint32(int32(dx))})
	}
}

func pick(pressed bool, down, up uint32) uint32 {
	if pressed {
		return down
	}
	return up
}

//go:build !windows

package main

import "log"

// lets the receiver build and run elsewhere for testing, it only logs what it would do
type logMouse struct{ x, y int }

func newMouse() mouse { return &logMouse{x: 960, y: 540} }

func (m *logMouse) screen() (int, int)   { return 1920, 1080 }
func (m *logMouse) position() (int, int) { return m.x, m.y }
func (m *logMouse) moveTo(x, y int)      { m.x, m.y = x, y }

func (m *logMouse) button(b byte, pressed bool) { log.Printf("button %d pressed=%v", b, pressed) }
func (m *logMouse) wheel(dx, dy int)            { log.Printf("wheel %d %d", dx, dy) }

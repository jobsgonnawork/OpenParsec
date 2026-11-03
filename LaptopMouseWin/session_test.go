package main

import (
	"encoding/binary"
	"testing"
)

type fakeMouse struct {
	x, y    int
	buttons []string
}

func (m *fakeMouse) screen() (int, int)   { return 1921, 1081 }
func (m *fakeMouse) position() (int, int) { return m.x, m.y }
func (m *fakeMouse) moveTo(x, y int)      { m.x, m.y = x, y }
func (m *fakeMouse) button(b byte, pressed bool) {
	if pressed {
		m.buttons = append(m.buttons, "down")
	} else {
		m.buttons = append(m.buttons, "up")
	}
}
func (m *fakeMouse) wheel(dx, dy int) {}

func move(dx, dy int16) packet {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint16(b, uint16(dx))
	binary.LittleEndian.PutUint16(b[2:], uint16(dy))
	return packet{kind: typeMove, payload: b}
}

func enter(side byte, along float32, seq uint32) packet {
	return packet{kind: typeEnter, payload: append(append([]byte{side}, putF32(along)...), putU32(seq)...)}
}

func TestEnterMoveReturn(t *testing.T) {
	m := &fakeMouse{}
	s := &session{m: m, speed: 1, held: map[byte]bool{}}

	reply := s.handle(enter(sideLeft, 0.5, 7), "tok")
	got, err := parse(reply, "tok")
	if err != nil || got.kind != typeAck || u32(got.payload, 0) != 7 {
		t.Fatalf("enter reply = %v %v", got, err)
	}
	if m.x != 0 || m.y != 540 {
		t.Fatalf("entered at %d,%d", m.x, m.y)
	}

	if r := s.handle(move(100, -40), "tok"); r != nil {
		t.Fatalf("move inside replied")
	}
	if m.x != 100 || m.y != 500 {
		t.Fatalf("moved to %d,%d", m.x, m.y)
	}

	s.handle(packet{kind: typeButton, payload: []byte{1, 1}}, "tok")
	reply = s.handle(move(-150, 0), "tok")
	got, err = parse(reply, "tok")
	if err != nil || got.kind != typeReturn {
		t.Fatalf("leaving reply = %v %v", got, err)
	}
	if along := f32(got.payload, 0); along < 0.46 || along > 0.47 {
		t.Fatalf("returned along %v", along)
	}
	if s.active || len(m.buttons) != 2 || m.buttons[1] != "up" {
		t.Fatalf("after return active=%v buttons=%v", s.active, m.buttons)
	}
	if r := s.handle(move(10, 10), "tok"); r != nil || m.x != 100 {
		t.Fatalf("moved while inactive")
	}
}

func TestBadToken(t *testing.T) {
	if _, err := parse(build(typeMove, "a", nil), "b"); err != errBadToken {
		t.Fatalf("err = %v", err)
	}
}

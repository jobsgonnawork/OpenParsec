package main

import (
	"encoding/binary"
	"errors"
	"math"
)

// Packet layout, little endian:
//
//	"OPK1" | type u8 | token length u8 | token | payload
//
// iPad to laptop:
//
//	typeEnter  side u8, along f32, seq u32  cursor arrives through this edge of the laptop screen, along 0..1
//	typeMove   dx i16, dy i16               points, already scaled by the iPad's mouse sensitivity
//	typeButton button u8, pressed u8        Parsec numbering: 1 left, 2 middle, 3 right, 4 X1, 5 X2
//	typeWheel  dx i16, dy i16               Parsec wheel units, negative y scrolls up
//	typeLeave                               the iPad took the cursor back
//
// laptop to iPad:
//
//	typeAck    seq u32                      answer to an enter
//	typeReturn along f32                    the cursor left through the edge it came in by
const (
	typeEnter  = 1
	typeMove   = 2
	typeButton = 3
	typeWheel  = 4
	typeLeave  = 5
	typeAck    = 0x81
	typeReturn = 0x82
)

const (
	sideLeft   = 0
	sideRight  = 1
	sideTop    = 2
	sideBottom = 3
)

var magic = []byte("OPK1")

type packet struct {
	kind    byte
	payload []byte
}

var errBadPacket = errors.New("bad packet")
var errBadToken = errors.New("bad token")

func parse(data []byte, token string) (packet, error) {
	if len(data) < 6 || string(data[:4]) != string(magic) {
		return packet{}, errBadPacket
	}
	n := int(data[5])
	if len(data) < 6+n {
		return packet{}, errBadPacket
	}
	if string(data[6:6+n]) != token {
		return packet{}, errBadToken
	}
	return packet{kind: data[4], payload: data[6+n:]}, nil
}

func build(kind byte, token string, payload []byte) []byte {
	out := make([]byte, 0, 6+len(token)+len(payload))
	out = append(out, magic...)
	out = append(out, kind, byte(len(token)))
	out = append(out, token...)
	return append(out, payload...)
}

func i16(b []byte, at int) int16 { return int16(binary.LittleEndian.Uint16(b[at:])) }

func f32(b []byte, at int) float32 { return math.Float32frombits(binary.LittleEndian.Uint32(b[at:])) }

func u32(b []byte, at int) uint32 { return binary.LittleEndian.Uint32(b[at:]) }

func putU32(v uint32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, v)
	return b
}

func putF32(v float32) []byte { return putU32(math.Float32bits(v)) }

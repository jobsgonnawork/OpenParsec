// LaptopMouse moves this laptop's real mouse with input sent by OpenParsec on the iPad, over the
// local network. With a Parsec window for the host's 2nd display full screen here, the cursor then
// shows with no stream delay, because the Parsec client draws it locally like any mouse.
package main

import (
	"flag"
	"fmt"
	"log"
	"math"
	"net"
	"time"
)

// mouse is the part that touches the OS, so the protocol logic builds and tests anywhere
type mouse interface {
	screen() (w, h int)
	position() (x, y int)
	moveTo(x, y int)
	button(parsecButton byte, pressed bool)
	wheel(dx, dy int)
}

type session struct {
	m        mouse
	speed    float64
	wheelMul float64
	active   bool
	side     byte
	// sub-pixel remainder, the iPad sends whole points
	rx, ry float64
	// buttons held on this side, released if the cursor leaves
	held map[byte]bool
}

// handle applies one packet and returns a reply to send back, if any
func (s *session) handle(p packet, token string) []byte {
	switch p.kind {
	case typeEnter:
		if len(p.payload) < 9 {
			return nil
		}
		s.side = p.payload[0]
		along := clamp01(float64(f32(p.payload, 1)))
		seq := u32(p.payload, 5)
		w, h := s.m.screen()
		var x, y float64
		switch s.side {
		case sideLeft:
			x, y = 0, along*float64(h-1)
		case sideRight:
			x, y = float64(w-1), along*float64(h-1)
		case sideTop:
			x, y = along*float64(w-1), 0
		default:
			x, y = along*float64(w-1), float64(h-1)
		}
		s.active, s.rx, s.ry = true, 0, 0
		s.m.moveTo(int(x), int(y))
		log.Printf("cursor in through the %s edge at %.2f", sideName(s.side), along)
		return build(typeAck, token, putU32(seq))
	case typeMove:
		if !s.active || len(p.payload) < 4 {
			return nil
		}
		return s.move(float64(i16(p.payload, 0)), float64(i16(p.payload, 2)), token)
	case typeButton:
		if !s.active || len(p.payload) < 2 {
			return nil
		}
		pressed := p.payload[1] != 0
		s.held[p.payload[0]] = pressed
		s.m.button(p.payload[0], pressed)
	case typeWheel:
		if !s.active || len(p.payload) < 4 {
			return nil
		}
		s.m.wheel(int(float64(i16(p.payload, 0))*s.wheelMul), int(float64(i16(p.payload, 2))*s.wheelMul))
	case typeLeave:
		if s.active {
			s.release()
			s.active = false
			log.Printf("the iPad took the cursor back")
		}
	}
	return nil
}

func (s *session) move(dx, dy float64, token string) []byte {
	w, h := s.m.screen()
	cx, cy := s.m.position()
	// start from where the cursor is, so this laptop's own trackpad and the iPad don't fight
	tx := float64(cx) + dx*s.speed + s.rx
	ty := float64(cy) + dy*s.speed + s.ry
	nx, ny := math.Trunc(tx), math.Trunc(ty)
	s.rx, s.ry = tx-nx, ty-ny

	maxX, maxY := float64(w-1), float64(h-1)
	var out bool
	var along float64
	switch s.side {
	case sideLeft:
		out, along = nx < 0, ny/maxY
	case sideRight:
		out, along = nx > maxX, ny/maxY
	case sideTop:
		out, along = ny < 0, nx/maxX
	default:
		out, along = ny > maxY, nx/maxX
	}
	if out {
		s.release()
		s.active = false
		log.Printf("cursor out through the %s edge at %.2f, back to the iPad", sideName(s.side), clamp01(along))
		return build(typeReturn, token, putF32(float32(clamp01(along))))
	}
	s.m.moveTo(int(math.Max(0, math.Min(nx, maxX))), int(math.Max(0, math.Min(ny, maxY))))
	return nil
}

func (s *session) release() {
	for b, down := range s.held {
		if down {
			s.m.button(b, false)
		}
	}
	s.held = map[byte]bool{}
}

func clamp01(v float64) float64 { return math.Max(0, math.Min(1, v)) }

func sideName(side byte) string {
	switch side {
	case sideLeft:
		return "left"
	case sideRight:
		return "right"
	case sideTop:
		return "top"
	default:
		return "bottom"
	}
}

func main() {
	port := flag.Int("port", 26510, "UDP port to listen on")
	token := flag.String("token", "", "shared token, the same as in OpenParsec's settings (required)")
	speed := flag.Float64("speed", 1.0, "multiplier for the iPad's moves")
	wheelMul := flag.Float64("wheel", 20, "multiplier from Parsec wheel units to Windows wheel units (120 per notch)")
	flag.Parse()
	if *token == "" || len(*token) > 255 {
		log.Fatal("-token is required, at most 255 characters")
	}

	conn, err := net.ListenUDP("udp", &net.UDPAddr{Port: *port})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("LaptopMouse listening on UDP %d, local addresses:\n", *port)
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if ip, ok := a.(*net.IPNet); ok && ip.IP.To4() != nil && !ip.IP.IsLoopback() {
				fmt.Printf("  %s\n", ip.IP)
			}
		}
	}

	s := &session{m: newMouse(), speed: *speed, wheelMul: *wheelMul, held: map[byte]bool{}}
	buf := make([]byte, 2048)
	lastBad := time.Time{}
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("read: %v", err)
			continue
		}
		p, err := parse(buf[:n], *token)
		if err != nil {
			if time.Since(lastBad) > 5*time.Second {
				log.Printf("ignored a packet from %s: %v", from, err)
				lastBad = time.Now()
			}
			continue
		}
		if reply := s.handle(p, *token); reply != nil {
			if _, err := conn.WriteToUDP(reply, from); err != nil {
				log.Printf("reply: %v", err)
			}
		}
	}
}

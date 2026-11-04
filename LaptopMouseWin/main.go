// LaptopMouse moves this laptop's real mouse with input sent by OpenParsec on the iPad, over the
// local network. With a Parsec window for the host's 2nd display full screen here, the cursor then
// shows with no stream delay, because the Parsec client draws it locally like any mouse.
package main

import (
	"fmt"
	"log"
	"math"
	"net"
	"os"
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
	// same for the wheel, when -wheel scales it down
	wx, wy float64
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
		s.wx += float64(i16(p.payload, 0)) * s.wheelMul
		s.wy += float64(i16(p.payload, 2)) * s.wheelMul
		dx, dy := math.Trunc(s.wx), math.Trunc(s.wy)
		s.wx, s.wy = s.wx-dx, s.wy-dy
		s.m.wheel(int(dx), int(dy))
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
	opts, fresh, err := loadOptions(os.Args[1:])
	if err != nil {
		fail("LaptopMouse can't read or save its settings in %s:\n%v", configDir(), err)
	}
	setUpLog()

	conn, err := net.ListenUDP("udp", &net.UDPAddr{Port: opts.Port})
	if err != nil {
		fail("LaptopMouse is probably already running (look for it next to the clock).\n\nUDP port %d: %v", opts.Port, err)
	}
	addrs := localAddresses()
	log.Printf("listening on UDP %d, addresses %v, settings in %s", opts.Port, addrs, configPath())

	go serve(conn, opts)
	runUI(opts, addrs, fresh)
}

func serve(conn *net.UDPConn, opts options) {
	s := &session{m: newMouse(), speed: opts.Speed, wheelMul: opts.Wheel, held: map[byte]bool{}}
	buf := make([]byte, 2048)
	lastBad := time.Time{}
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("read: %v", err)
			continue
		}
		p, err := parse(buf[:n], opts.Token)
		if err != nil {
			if time.Since(lastBad) > 5*time.Second {
				log.Printf("ignored a packet from %s: %v", from, err)
				lastBad = time.Now()
			}
			continue
		}
		if reply := s.handle(p, opts.Token); reply != nil {
			if _, err := conn.WriteToUDP(reply, from); err != nil {
				log.Printf("reply: %v", err)
			}
		}
	}
}

// the addresses worth typing on the iPad: Tailscale first, then the local network
func localAddresses() []string {
	var tailscale, local []string
	addrs, _ := net.InterfaceAddrs()
	_, cgnat, _ := net.ParseCIDR("100.64.0.0/10")
	for _, a := range addrs {
		ip, ok := a.(*net.IPNet)
		if !ok || ip.IP.To4() == nil || ip.IP.IsLoopback() || ip.IP.IsLinkLocalUnicast() {
			continue
		}
		if cgnat.Contains(ip.IP) {
			tailscale = append(tailscale, ip.IP.String()+" (Tailscale)")
		} else {
			local = append(local, ip.IP.String())
		}
	}
	return append(tailscale, local...)
}

func fail(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	log.Print(msg)
	showMessage(msg)
	os.Exit(1)
}

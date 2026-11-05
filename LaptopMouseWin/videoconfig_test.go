package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const hostConfig = `{"virtualMicrophone":0,"virtualTablet":0,"video":[
{"encoderFPS":0,"resolutionX":2732,"resolutionY":2048,"fullFPS":false,"hostOS":1,"output":"disp-1","encoderMaxBitrate":20},
{"encoderFPS":0,"resolutionX":0,"resolutionY":0,"fullFPS":false,"hostOS":1,"output":"none","encoderMaxBitrate":20},
{"encoderFPS":0,"resolutionX":0,"resolutionY":0,"fullFPS":false,"hostOS":1,"output":"none","encoderMaxBitrate":20}]}`

const hostDisplays = `[{"name":"Display 1","adapterName":"","id":"disp-1"},{"name":"Display 2","adapterName":"","id":"disp-2"}]`

func TestStream1ConfigKeepsStream0(t *testing.T) {
	s := &videoConfigState{}
	s.reset("", 1920, 1200)
	if _, ok := s.handle(userDataSetVideoConfig, hostConfig); ok {
		t.Fatal("replied before knowing the displays")
	}
	reply, ok := s.handle(userDataDisplays, hostDisplays)
	if !ok {
		t.Fatal("no reply once both are known")
	}
	var got struct {
		Video []map[string]any `json:"video"`
	}
	if err := json.Unmarshal([]byte(reply), &got); err != nil {
		t.Fatal(err)
	}
	v0, v1 := got.Video[0], got.Video[1]
	if v0["output"] != "disp-1" || v0["resolutionX"] != 2732.0 {
		t.Fatalf("stream 0 changed: %v", v0)
	}
	if v1["output"] != "disp-2" || v1["resolutionX"] != 1920.0 || v1["resolutionY"] != 1200.0 || v1["encoderMaxBitrate"] != 20.0 {
		t.Fatalf("stream 1 = %v", v1)
	}

	// the host echoing it back needs no answer
	if _, ok := s.handle(userDataSetVideoConfig, reply); ok {
		t.Fatal("answered a matching echo")
	}
	// but a config that lost stream 1 gets it again, not too often
	if _, ok := s.handle(userDataSetVideoConfig, hostConfig); ok {
		t.Fatal("answered again within 2 s")
	}
	s.lastSent = time.Now().Add(-3 * time.Second)
	if _, ok := s.handle(userDataSetVideoConfig, hostConfig); !ok {
		t.Fatal("didn't restore stream 1")
	}
}

func TestStream1ConfiguredDisplay(t *testing.T) {
	s := &videoConfigState{}
	s.reset("disp-3", 1280, 800)
	s.handle(userDataDisplays, hostDisplays)
	reply, ok := s.handle(userDataSetVideoConfig, hostConfig)
	if !ok {
		t.Fatal("no reply")
	}
	var got struct {
		Video []map[string]any `json:"video"`
	}
	json.Unmarshal([]byte(reply), &got)
	if got.Video[1]["output"] != "disp-3" {
		t.Fatalf("output %v", got.Video[1]["output"])
	}
}

func TestChooseDisplay(t *testing.T) {
	s := &videoConfigState{}
	s.reset("", 1920, 1200)
	s.handle(userDataDisplays, `[{"name":"iPad","id":"a"},{"name":"Physical","id":"b"},{"name":"Laptop","id":"c"}]`)
	s.handle(userDataSetVideoConfig, strings.Replace(hostConfig, "disp-1", "a", 1))
	if _, shown, ipad := s.state(); shown != "b" || ipad != "a" {
		t.Fatalf("shown %q ipad %q", shown, ipad)
	}
	reply, ok := s.choose("c")
	if !ok || !strings.Contains(reply, `"output":"c"`) {
		t.Fatalf("choose = %v %s", ok, reply)
	}
	if _, shown, _ := s.state(); shown != "c" {
		t.Fatalf("shown %q", shown)
	}
}

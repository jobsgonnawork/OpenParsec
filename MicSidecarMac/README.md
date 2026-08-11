# MicSidecarMac

macOS UDP receiver for OpenParsec Sidecar mic transport.

## What it does

- Listens for Sidecar UDP mic packets from OpenParsec.
- Validates shared token.
- Parses PCM16LE audio payload.
- Plays audio through macOS default output device.

For BlackHole workflow, set macOS default output to BlackHole 2ch before starting the receiver.

## Build

```bash
cd MicSidecarMac
swift build -c release
To auto-target BlackHole by name at startup:

```bash
swift run MicSidecarReceiver --port 26500 --token YOUR_SHARED_TOKEN --output-device "BlackHole"
```
```

- `--output-device <name-substring>`: Optional. Attempts to set macOS default output to the first matching device name
swift run MicSidecarReceiver --port 26500 --token YOUR_SHARED_TOKEN
```


- `--port <udp-port>`: UDP listen port. Default: `26500`
- `--token <shared-token>`: Required token used by OpenParsec Sidecar sender
- `--verbose`: Print packet-level logs

## Packet format (v1)

Header (32 bytes total):

- 4 bytes: magic `OPM1`
- 1 byte: version
- 1 byte: flags
- 4 bytes: sequence (LE)
- 8 bytes: timestamp ns (LE)
- 4 bytes: sample rate (LE)
- 1 byte: channels
- 1 byte: reserved
- 2 bytes: frame count (LE)
- 2 bytes: token length (LE)
- 4 bytes: payload length (LE)

Then:

- token bytes (UTF-8)
- payload bytes (PCM16LE)

## Notes

- Current iOS sender is mono-first. Stereo payloads are downmixed to mono by the receiver.
- Receiver prints rolling stats every 5 seconds.

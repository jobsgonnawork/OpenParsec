# LaptopMouseWin

A Windows receiver that lets OpenParsec on the iPad drive the laptop's real mouse over the local network, when the laptop shows the host's 2nd display.

## Why

In this setup the iPad shows display 1 and a Windows laptop shows display 2, through the desktop client's **Add Screens**. When the cursor is handed to the host, it reaches display 2 but the laptop shows it late or not at all. Parsec clients only draw the cursor for the guest who is moving it.

With LaptopMouse running, the iPad sends its mouse to the laptop instead, from the moment it crosses the edge. The laptop's mouse moves straight away. The Parsec window for display 2 sees that mouse like any other, draws the cursor locally with no stream delay, and forwards the moves and clicks to the host. When the cursor leaves the laptop through the edge it came in by, LaptopMouse hands it back to the iPad.

## Setup

1. Get `LaptopMouse.exe` (`LaptopMouse-arm64.exe` for ARM laptops) from the **LaptopMouse** artifact of the GitHub Actions run, or build it on any machine with Go:

   ```bash
   GOOS=windows GOARCH=amd64 go build -o LaptopMouse.exe .
   ```

2. On the laptop, open the Parsec window for display 2 full screen on the laptop's main display, then run:

   ```
   LaptopMouse.exe -token pick-a-secret
   ```

   Allow it through Windows Firewall on private networks. It prints the laptop's local addresses.

3. On the iPad, in OpenParsec:
   - **Settings → 2nd Screen on a Laptop**: enter one of those addresses, port `26510`, and the same token.
   - **2nd Screen menu during a stream**: turn on **On Another Device**, and set **Position** to match the display arrangement on the host.
   - The first time, iOS asks for local network access. Allow it.

## Options

- `-port 26510`: UDP port.
- `-speed 1.0`: multiplies the iPad's moves, if the cursor feels too slow or too fast on the laptop.
- `-wheel 20`: converts Parsec wheel units to Windows ones (120 per notch).

## Notes

- Only the mouse goes to the laptop. The keyboard still goes from the iPad to the host, which makes no difference to latency.
- The laptop's own trackpad keeps working, and both move the same cursor.
- If the laptop doesn't answer within 0.6 s of a handoff, the cursor stays on the iPad. The iPad's connection log then shows `[laptop] no answer`.

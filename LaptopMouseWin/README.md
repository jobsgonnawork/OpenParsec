# LaptopMouseWin

A Windows receiver that lets OpenParsec on the iPad drive the laptop's real mouse over the local network, when the laptop shows the host's 2nd display.

## Why

In this setup the iPad shows display 1 and a Windows laptop shows display 2, through the desktop client's **Add Screens**. When the cursor is handed to the host, it reaches display 2 but the laptop shows it late or not at all. Parsec clients only draw the cursor for the guest who is moving it.

With LaptopMouse running, the iPad sends its mouse to the laptop instead, from the moment it crosses the edge. The laptop's mouse moves straight away. The Parsec window for display 2 sees that mouse like any other, draws the cursor locally with no stream delay, and forwards the moves and clicks to the host. When the cursor leaves the laptop through the edge it came in by, LaptopMouse hands it back to the iPad.

## Setup

1. Get `LaptopMouse.exe` (`LaptopMouse-arm64.exe` for ARM laptops) from the **LaptopMouse** artifact of the GitHub Actions run, or build it on any machine with Go:

   ```bash
   GOOS=windows GOARCH=amd64 go build -ldflags "-H=windowsgui" -o LaptopMouse.exe .
   ```

2. Put it somewhere it can stay, such as Documents, and double-click it. It has no window: it sits next to the clock. The first time, it makes up a token, sets itself to start with Windows, and shows the address and token to enter on the iPad. Allow it through Windows Firewall if asked.

   The tray menu shows the addresses and the token (click it to copy), and turns **Start with Windows** on or off. If the iPad can't reach the laptop, for example on Wi-Fi that keeps devices apart, install Tailscale on both and use the laptop's `100.x` address.

   On the laptop, open the Parsec window for display 2 full screen on the laptop's main display.

3. On the iPad, in OpenParsec:
   - **Settings → 2nd Screen on a Laptop**: enter one of those addresses, port `26510`, and the same token.
   - **2nd Screen menu during a stream**: turn on **On Another Device**, and set **Position** to match the display arrangement on the host.
   - The first time, iOS asks for local network access. Allow it.

## Settings

They are saved in `%APPDATA%\LaptopMouse\config.json` (**Edit settings** in the tray menu). Quit and start LaptopMouse again after changing them. The same flags set them from a terminal, and are saved for next time:

- `-token`: the token the iPad sends.
- `-port 26510`: UDP port.
- `-speed 1`: multiplies the iPad's moves, if the cursor feels too slow or too fast on the laptop.
- `-wheel 1`: multiplies the iPad's scroll, which already comes in Windows units (120 per notch). Lower it, e.g. `0.5`, if scrolling feels too fast.

The log is in `%APPDATA%\LaptopMouse\laptopmouse.log` (**Open log**).

## Notes

- Only the mouse goes to the laptop. The keyboard still goes from the iPad to the host, which makes no difference to latency.
- The laptop's own trackpad keeps working, and both move the same cursor.
- If the laptop doesn't answer within 0.6 s of a handoff, the cursor stays on the iPad. The iPad's connection log then shows `[laptop] no answer`.

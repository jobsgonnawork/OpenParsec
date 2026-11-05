# LaptopMouseWin

A Windows app that turns a laptop into the 2nd screen of OpenParsec on the iPad: it shows the Parsec host's 2nd display full screen, and the iPad's mouse moves onto it with no delay.

## How it works

The iPad shows display 1 (stream 0). LaptopMouse connects to the same host with the Parsec SDK and shows only display 2 (stream 1), full screen, with nothing else to open or arrange.

When the iPad's cursor crosses the edge, the iPad sends its mouse to the laptop over the network, and LaptopMouse moves the laptop's own cursor. The 2nd screen window sends that mouse to the host and the cursor is drawn locally, so it moves with no stream delay. When the cursor leaves through the edge it came in by, LaptopMouse hands it back to the iPad. The laptop's own trackpad works on the 2nd screen too.

## Setup

1. Get `LaptopMouse.exe` from the **LaptopMouse** artifact of the GitHub Actions run, or build it with Go and a MinGW-w64 C compiler:

   ```bash
   sdk/fetch.sh
   CGO_ENABLED=1 CC=x86_64-w64-mingw32-gcc GOOS=windows GOARCH=amd64 go build -ldflags "-H=windowsgui" -o LaptopMouse.exe .
   ```

   `sdk/fetch.sh` downloads Parsec SDK 6.0 for Windows, which is built into the exe.

2. Put it somewhere it can stay, such as Documents, and double-click it. It sits next to the clock and starts with Windows (in the tray only).
   - The first time, it shows the address and token to enter on the iPad, then asks for your Parsec account and the computer to connect to, in a console window. The password goes only to Parsec; the session is kept encrypted for your Windows user.
   - Allow it through Windows Firewall if asked. If the iPad can't reach the laptop, for example on Wi-Fi that keeps devices apart, install Tailscale on both and use the laptop's `100.x` address.

3. On the iPad, in OpenParsec:
   - **Settings → 2nd Screen on a Laptop**: enter one of those addresses, port `26510`, and the same token.
   - **2nd Screen menu during a stream**: turn on **On Another Device**, and set **Position** to match the display arrangement on the host.
   - The first time, iOS asks for local network access. Allow it.

## Use

- **Open the 2nd screen**: double-click LaptopMouse, choose **Open 2nd screen** in the tray menu, or just move the iPad's cursor over.
- **Leave full screen**: Shift+Esc minimises it; **Close 2nd screen** in the tray disconnects.
- **Another account or computer**: **Sign in or change computer…** in the tray.

## Settings

They are saved in `%APPDATA%\LaptopMouse\config.json` (**Edit settings** in the tray menu). Quit and start LaptopMouse again after changing them. The same flags set them from a terminal, and are saved for next time:

- `-token`: the token the iPad sends.
- `-port 26510`: UDP port.
- `-speed 1`: multiplies the iPad's moves, if the cursor feels too slow or too fast on the laptop.
- `-wheel 1`: multiplies the iPad's scroll, which already comes in Windows units (120 per notch). Lower it, e.g. `0.5`, if scrolling feels too fast.
- `display` (settings file only): the host display to show, by id, as listed in the log. Empty shows the first display the iPad isn't on.

The log is in `%APPDATA%\LaptopMouse\laptopmouse.log` (**Open log**).

## Notes

- Only the mouse goes to the laptop. The keyboard still goes from the iPad to the host, which makes no difference to latency.
- The laptop's own trackpad keeps working, and both move the same cursor.
- If the laptop doesn't answer within 0.6 s of a handoff, the cursor stays on the iPad. The iPad's connection log then shows `[laptop] no answer`.

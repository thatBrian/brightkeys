# brightkeys

Make the Mac brightness keys control whichever display the mouse is on: the built-in screen as usual, or an external monitor over DDC/CI.

That's the whole tool. It's one Swift file of about 300 lines, with no app, no menu bar icon and no settings window.

## Why this exists

I have an LG UltraFine 6K (32U990A). The brightness keys on my Mac don't control it unless you install **LG Switch**, and I didn't want to:

1. **I don't trust LG's software.** I'm not putting a vendor's background app with broad system access on my machine just to change brightness.
2. **I didn't need the bells and whistles.** [MonitorControl](https://github.com/MonitorControl/MonitorControl) is great and does far more than this: volume, sliders, OSD, syncing and lots of preferences. I wanted one behaviour, in code short enough to read in one sitting.

So brightkeys does one thing:

- The mouse is on the **built-in display**: the key press goes to macOS untouched.
- The mouse is on an **external display**: the key press is swallowed and a DDC luminance command goes to that monitor. It moves in 16 steps, the same as the built-in screen.

It should work with any DDC/CI-capable monitor connected over USB-C, Thunderbolt or DisplayPort on Apple Silicon. I've only tested it on the UltraFine 6K over Thunderbolt with an M3 MacBook Air on macOS 26.

## Install

Requires Apple Silicon and the Xcode command line tools (`xcode-select --install`).

```sh
make probe     # optional: read-only check that your monitor answers DDC
make install   # builds, installs to ~/.local/bin, starts a LaunchAgent
```

macOS will ask you to grant **Accessibility** to `~/.local/bin/brightkeys`. Do that in System Settings → Privacy & Security → Accessibility. brightkeys checks for the permission every 10 seconds and starts working within about 10 seconds of the grant. The LaunchAgent starts it at login and restarts it if it ever exits.

```sh
make logs       # tail ~/Library/Logs/brightkeys.log
make uninstall  # stop the agent and remove everything
```

> **Rebuilds reset the permission.** The binary is ad-hoc signed, so macOS treats each rebuild as a new app. After `make install` with changed code, remove the old brightkeys entry from Accessibility and grant it again.

## How it works

- A `CGEventTap` watches system-defined events and picks out the brightness up and down keys (`NX_KEYTYPE_BRIGHTNESS_UP/DOWN`). Swallowing events is why Accessibility is needed.
- `CGGetDisplaysWithPoint` at the cursor location decides which display the key press is for.
- For external displays, the display ID is mapped to its `DCPAVServiceProxy` in the IORegistry. A standard DDC/CI "Set VCP Feature" command for luminance (VCP `0x10`) is then written over I2C with the private `IOAVServiceWriteI2C`. That runs on a background queue so the key press never waits on the monitor.
- The current brightness is read from the monitor when it hasn't been touched for 10 seconds, so changes made with the monitor's own buttons are picked up.

It makes no network calls, writes no files (apart from the log the LaunchAgent sets up) and doesn't run as root.

## Credits

The DDC-over-IOAVService approach and packet format come from [m1ddc](https://github.com/waydabber/m1ddc) (MIT), which I read through and used to confirm my monitor supported DDC before writing this.

## License

MIT

# ELRS Finder Pro

A lost-model finder for **ExpressLRS** transmitters on **EdgeTX** radios. It shows live
signal strength with a beep that speeds up as the model gets closer. It lowers
transmit power automatically as the model closes in and restores the original power
setting on exit.

## What it does

- Shows signal strength as a number, plus a bar meter.
- Lowers `Max Power` step by step as signal strength increases. Never raises power on
  its own.
- Scrolling to set power manually stops the automatic lowering for the rest of that
  session.
- Restores the original power setting on exit with `RTN`.

## Installing

1. Copy `ELRS-Finder-Pro.lua` to `/SCRIPTS/TOOLS/` on the radio's SD card.
2. Open the model's **Tools** page. Select **ELRS Finder Pro**.
3. Power on the ELRS TX module. A bound model is not required.

## Using it

The tool scans the TX module's settings on start. This takes a few seconds; a
**Scanning** screen shows during the wait.

After the scan, the finder screen shows:

- Signal number and bar meter.
- Beep rate: faster means closer.
- **Power row**: the current power setting.
- **`[RTN]:exit [ENT]:edit power`**: press `RTN` to exit and restore power. Press
  `ENT` to edit power.

### Adjusting power manually

1. Press `ENT`. The value blinks. It is not applied yet.
2. Scroll to change the value.
3. Press `ENT` to apply it, or `RTN` to cancel and keep the previous value.

This stops the automatic power lowering for the rest of the session.

## Exiting

Press `RTN` once, briefly. This restores the original power setting before exit.

Two actions skip that restore step. Neither can be prevented by this tool, or any
similar tool:

- Turning the radio off without pressing `RTN` first.
- Holding `RTN` down. A long press is EdgeTX's own force-quit action. It closes the
  tool immediately, before it can restore anything. The default threshold is short,
  around 0.5 seconds, and easy to trigger by accident.

If either happens, the transmitter stays at whatever power the tool last set. Verify
the power setting before the next flight after an unclean exit. The screen also shows
this warning: `PwrOff/RTNhold=no restore`.

## Compatibility

Tested: EdgeTX v2.12.3, ExpressLRS v3.6.4, Radiomaster Boxer. No other version is
verified.

The CRSF protocol matches the current official ExpressLRS Lua scripts on both the 3.x
and 4.x branches, so other versions are expected to work. Report results on other
versions as a GitHub issue.

- EdgeTX radios with a 128x64 or 212x64 monochrome screen, or a color screen.
- ExpressLRS TX modules on 3.x or 4.x firmware.

## Why a standalone tool

This builds on the [ELRS_Finder.lua](https://github.com/iamsunilchahal/edgetx-lua-scripts-bw)
signal-beep concept, with automatic power management added. It stays a standalone
tool for now, rather than a patch to the official ExpressLRS Lua scripts.

## Feedback / issues

Report problems or suggestions as a GitHub issue on this repo.

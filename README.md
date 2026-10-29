# iDVolume

iDVolume makes the Mac's volume keys work with an Audient iD14 MkII audio interface.

macOS drives the iD14 with its built-in USB audio driver, and the interface reports no
volume or mute control to it. The monitor level is set digitally inside the iD14, and
only the endless knob on the front moves it. So while the iD14 is the output, the volume
keys show a crossed-out speaker and do nothing.

iDVolume is a small background app. While an Audient is the default output, it catches
the volume keys and changes the iD14's own monitor level, the same value the front knob
changes. You can use the knob and the keys interchangeably: turn the knob, press a key,
and the key starts from where the knob left the level. Nothing is added to the audio
path: no virtual device, no software gain, no extra latency.

## What it does

- **Volume Up / Down** change the monitor level by 2 dB per press, **Shift+Option+key**
  by 0.5 dB.
- Quick presses speed up, like the knob turned fast: each press that follows the last one
  within 0.35 s goes 1 dB further, up to 5 dB per press. Holding a key does the same,
  one step at most every 0.15 s. The fine step never speeds up.
- **Mute** turns the monitor mute on and off. Like in macOS, any volume key turns mute
  off.
- **Option+volume key** still opens Sound settings.
- A small panel in the top right corner shows the level in dB for a second and a half.
- It only acts while an Audient device is the default output. For the built-in speakers,
  AirPods and everything else, the keys reach macOS untouched.
- If the interface can't be reached, the key goes through to macOS as usual.

## How it works

The iD's control protocol was reverse engineered by the Linux projects MixiD and
[BiD](https://github.com/baakhoff/BiD) (see its `docs/PROTOCOL.md`). The interface has a
spare DFU interface (number 4) that no macOS driver claims. iDVolume sends UAC2-style
class requests to it through `IOUSBHost`:

| Control | Entity | Selector | Value |
|---|---|---|---|
| Monitor level | `0x36` | `0x12` | `int16` in 1/256 dB, `0x8000` is silence |
| Monitor mute | `0x36` | `0x04` | 1 byte, 0 or 1 |

Sound keeps playing because the audio interfaces themselves are never touched, and no
root access is needed. iDVolume opens the interface only for one change, well under a
millisecond, so it never blocks the official iD app, replugging or sleep. Before every
change it reads the current level from the device, which is how the keys keep up with
the knob.

The keys are caught with a `CGEvent` tap on system-defined events, which needs the
Accessibility permission.

All of it is one file, [main.swift](main.swift), about 370 lines.

## Requirements

- macOS 13 or later.
- Xcode or the Command Line Tools, for `swiftc`.
- Tested only with an iD14 MkII on macOS 27. The other iD models may use the same
  protocol, but they haven't been tried.

## Install

```
git clone https://github.com/andwhy/iDVolume.git
cd iDVolume
./install.sh
```

`install.sh` builds the app, copies it to `~/Applications/iDVolume.app` and adds a login
agent, so it starts at every login and restarts if it quits. On the first launch macOS
asks for Accessibility: turn on iDVolume in **System Settings → Privacy & Security →
Accessibility**. The keys start working about two seconds later, no relaunch needed.

The app has an ad hoc signature, so after every rebuild macOS sees a new app and the
Accessibility permission has to be given again. That's why `install.sh` reuses an
existing build. To update, run `./build.sh`, then `./install.sh`.

The log is at `~/Library/Logs/iDVolume.log`.

## Uninstall

```
./uninstall.sh
```

This stops the app and removes it and its login agent. The Accessibility entry stays in
System Settings until you delete it there.

## Limitations

- The protocol is unofficial. A firmware update from Audient may change it. Then the
  keys just go back to the usual macOS behaviour.
- On the MkII one knob controls both the monitors and the headphones. The keys change
  the main mix level. The headphones follow it only when they get the main mix, not a
  cue mix.
- Turning the knob doesn't show the panel. That would need constant polling of the
  device, and the BiD authors warn that frequent requests can hang the iD's control
  interface.
- The panel is iDVolume's own, not the system volume indicator. On recent macOS only
  Apple's own processes can show that one.
- The panel's "muted" label is in Russian ("выкл").

## License

MIT, see [LICENSE](LICENSE).

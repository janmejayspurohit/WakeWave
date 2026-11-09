# WakeWave

A tiny macOS menu bar app that keeps your speakers from falling asleep.

Many speakers switch themselves off after a few minutes of silence. WakeWave plays a 20 Hz tone at
-30 dBFS: practically inaudible, but a real signal on the line, so the speaker stays on. It can play
to any macOS output: the headphone jack, USB, HDMI/DisplayPort or Bluetooth.

## Features

- **On/off switch** in the menu. The menu bar icon turns green while WakeWave is running.
- **Turn On for** 15 minutes up to 8 hours, or indefinitely. It turns itself off when the time is up.
- **Speaker**: *Automatic* follows whichever output macOS is using, or pick a specific device.
  A picked device is remembered, and WakeWave resumes on its own when that device comes back.
- **Light**: no polling. It reacts only to Core Audio device changes and system wake, and idles at
  about 0% CPU.
- No Dock icon and no login item. It runs only when you open it.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools, to build (`xcode-select --install`)

## Build and install

```sh
git clone https://github.com/janmejayspurohit/WakeWave.git
cd WakeWave
./build.sh
open ~/Applications/WakeWave.app
```

`build.sh` compiles `WakeWave.swift`, assembles `WakeWave.app` in `~/Applications` and signs it ad
hoc. To install somewhere else, set `APP_DEST`, for example `APP_DEST=/Applications ./build.sh`.

To start WakeWave at login, add it under Login Items in System Settings.

## How it works

WakeWave registers a Core Audio IOProc on the chosen output device and fills each buffer from a
one-cycle sine table computed once at start, so the audio thread only copies samples. It asks for a
4096-frame buffer, about 12 callbacks per second at 48 kHz. Property listeners on the device list,
the default output device, and the active device's availability and sample rate keep it on the right
device. The only timer is the one-shot end of a timed session.

It writes only to outputs whose stream format is 32-bit float, mixes with your other audio instead of
replacing it, and never touches the system volume.

## Notes

- While WakeWave is playing, macOS counts audio as active, so the Mac will not idle-sleep (the
  display still sleeps). Turn WakeWave off when you want the Mac to sleep on its own.
- If your speaker still turns off, it may need a stronger signal: raise `toneAmplitude` in
  `WakeWave.swift` and rebuild.

## Testing

```sh
swiftc -O -o /tmp/wakewave WakeWave.swift
/tmp/wakewave --selftest   # checks the tone: level, frequency, seamless buffer joins (no audio)
/tmp/wakewave --list       # lists output devices; * marks the default output
/tmp/wakewave --probe 2    # plays to the default output for 2 s and reports the callbacks
```

## License

MIT. See [LICENSE](LICENSE).

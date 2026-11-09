# WakeWave

A tiny macOS menu bar app that keeps your speakers from falling asleep.

Many speakers switch themselves off after a few minutes of silence. WakeWave plays a 20 Hz tone at
-30 dBFS: practically inaudible, but a real signal on the line, so the speaker stays on. It can play
to any macOS output: the headphone jack, USB, HDMI/DisplayPort or Bluetooth.

## Install

1. Download **WakeWave.dmg** from the [latest release](https://github.com/janmejayspurohit/WakeWave/releases/latest).
2. Open it and drag **WakeWave** onto **Applications**.
3. Open WakeWave. It isn't notarized by Apple, so macOS blocks the first launch: go to
   **System Settings > Privacy & Security**, scroll down, click **Open Anyway** next to WakeWave
   and confirm. This is needed only once; updates install without asking.

Requires macOS 13 Ventura or later, on Apple silicon or Intel.

## Features

- **On/off switch** in the menu. The menu bar icon turns green while WakeWave is running.
- **Turn On for** 15 minutes up to 8 hours, or indefinitely. It turns itself off when the time is up.
- **Speaker**: *Automatic* follows whichever output macOS is using, or pick a specific device.
  A picked device is remembered, and WakeWave resumes on its own when that device comes back.
- **Settings** (⌘,): menu bar icon and color for on and off, signal strength, launch at login, and
  updates.
- **Automatic updates**, verified before they are installed.
- **Light**: no polling. It reacts only to Core Audio device changes and system wake, and idles at
  about 0% CPU.

## Updates

WakeWave checks GitHub for a new release when it starts, after the Mac wakes (at most every 12
hours), and when you click **Check Now** in Settings. A new version is installed only if its
signature matches the key built into the app. WakeWave then relaunches in the same state: on, off,
or with the time left on a timer. Turn off **Install updates automatically** to install them
yourself from the menu instead.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/janmejayspurohit/WakeWave.git
cd WakeWave
./build.sh
open ~/Applications/WakeWave.app
```

`build.sh` compiles `WakeWave.swift`, assembles `WakeWave.app` in `~/Applications` (set `APP_DEST`
to change that) and signs it ad hoc. Local builds are versioned `dev` and never update themselves.
`VERSION=1.2.0` sets a release version and `ARCHS="arm64 x86_64"` builds a universal app.

## Releasing

Push a version tag:

```sh
git tag v1.1.0
git push origin v1.1.0
```

The [Release workflow](.github/workflows/release.yml) builds a universal app, runs the self-test,
packages `WakeWave.dmg`, signs it and publishes the GitHub release. Installed copies pick it up on
their next check. Signing uses the `UPDATE_SIGNING_KEY` repository secret: a base64 Ed25519 private
key whose public half is listed in `updatePublicKeys` in `WakeWave.swift`. The workflow refuses to
sign with a key that isn't listed.

To create a key pair (keep the private key secret and backed up):

```sh
openssl genpkey -algorithm ed25519 -out key.pem
openssl pkey -in key.pem -outform DER | tail -c 32 | base64          # private: UPDATE_SIGNING_KEY
openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | base64  # public: updatePublicKeys
```

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
- If your speaker still turns off, raise **Signal strength** in Settings.

## Testing

```sh
swiftc -O -o /tmp/wakewave WakeWave.swift
/tmp/wakewave --selftest   # tone level, frequency and buffer joins; update version and signature checks
/tmp/wakewave --list       # lists output devices; * marks the default output
/tmp/wakewave --probe 2    # plays to the default output for 2 s and reports the callbacks
```

## License

MIT. See [LICENSE](LICENSE).

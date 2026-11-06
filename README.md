# LupedSmartwatchKit

A Loop `SmartwatchManager` plugin that shows Loop's glucose on a Pebble running the
[Luped CGM watchface](https://github.com/dabear/LupedPebbleWatchFace),
over [elbbepTransport](https://github.com/dabear/elbbepTransport)'s direct
Bluetooth link (no PebbleKit JS, no phone-side Pebble SDK).

It is the first plugin for the `SmartwatchManager` plugin type. Loop sends the
plugin a `SmartwatchStatusSnapshot` as soon as a new glucose reading is stored
and again after the loop runs, and forwards its glucose alerts; the plugin
pushes both to the watch. The watch has no thresholds of its own: it buzzes and
colours its ring from Loop's alerts.

## Targets

| Target | What it holds |
|---|---|
| `LupedSmartwatchKit` | `LupedSmartwatchManager: SmartwatchManager`. Turns snapshots into LupedKit payloads, keeps Luped's settings in `rawState`, and forwards the watch communication log to Loop's device log. Re-exports `LupedKit`. |
| `LupedSmartwatchKitUI` | `SmartwatchManagerUI` conformance and the Settings → Devices → Pebble screens: status, display (layout, status line, last loop), alarms, diagnostics, communication log, watchface UUID. |
| `LupedSmartwatchPlugin` | The `.loopplugin` principal class and Info.plist keys (`com.loopkit.Loop.SmartwatchManagerIdentifier`). |
| `LupedSmartwatchKitTests` | Unit tests, including the device-log mapping. |

Capabilities: `.glucose`, `.history`, `.alerts`, `.loopStatus`, `.therapy`. The
plugin requests only what its Display settings need (`requestedCapabilities`).

## On the watch

- The watch colours its ring from the host's active glucose alert (red for lows,
  amber for high) and buzzes each time the host fires or repeats one. It has no
  thresholds of its own, so it follows the host's alert settings and timing,
  such as Loop's Delay 1st Alert for highs.
- Active alerts are saved in `rawState`, so a relaunch during an alert keeps the
  ring's colour; the host's later retraction clears it. A watch added again
  starts at a random alert event, so its first alert always buzzes.
- Only what the chosen display needs is sent. Large Glucose sends only readings
  and alerts.
- Each message names the app sending it ("Loop", "Trio"). The Luped watchface
  follows the first app it hears from after it starts; if another app sends
  data later, it stops showing data and asks for a watchface restart, and it does
  the same for data in a newer protocol version than it knows.
- Supported watches: Core Devices' Pebble Time 2 and Pebble Round 2. The link is
  encrypted (LE Secure Connections). Remove the Pebble from any other diabetes
  app that has it added as a watch: two such apps would publish the same
  Bluetooth service, and the watch follows whichever it connects to.

## Messages and battery (elbbepTransport)

- One message per reading: a new reading waits for the loop's result (at most
  10 s), then 6 s for its dose to be stored, so IOB goes in the same message.
- An alarm goes out at once, with the previous reading (the host alerts before
  its snapshot has the new one); the alarm's own reading follows at once.
- Data the watch already has, or is about to get, isn't sent again; a quick
  A, B, A setting change still ends with A.
- A watchface start is answered once, though Luped asks twice (Alloy's ready
  handshake, then its own `refresh`).

## Requests from Luped Remote

Luped Remote, a separate watchapp, sends the requests; the watchface sends
none. The plugin passes them to the host: alert mute (and ending it), carbs,
bolus, a bolus recommendation, and override and temp target presets. It declares
the matching remote capabilities (`LupedSmartwatchManager.remoteCapabilities`),
and the host still checks its own Watch Permissions and rules for every request.

Luped Remote is offered only while at least one remote capability is declared
(`offersLupedRemote`). With `remoteCapabilities` empty, its Watch App section and its
UUID in Advanced are hidden, a saved Luped Remote switch is ignored, and its
watch session is never opened.

Boluses are only ever signed (elbbepTransport):

- On every watchface start and Bluetooth session, and only while remote bolus is
  allowed, the phone gives the watch a random 256-bit session key
  (`COMMAND auth:v1:<sid>:<key>`). The watch keeps it in memory only.
- The watch sends `signedbolus:<units>[:<grams>[:<absorption>]]`
  with `@<confirmedAt>#<sid>.<seq>.<mac>`: HMAC-SHA256 over every field,
  truncated to 16 bytes.
- LupedKit checks the key, session, MAC (constant time), sequence, and that the
  request is at most 30 s old and at most 5 s ahead, then passes it to the
  plugin once. A resend gets the same results again.
- With carbs, the plugin adds the carbs first, then checks the bolus against the
  host's next bolus context, which counts them. No carbs, no bolus.
- The signature proves the request is unchanged and comes from the watchface run
  that got the key. It doesn't prove who wears the watch; the host's own checks
  always apply.

## Device log

Every line LupedKit writes to its communication log also goes to
`SmartwatchManagerDelegate.smartwatchManager(_:didLogEvent:)`,
keyed by the watchface UUID, so it appears in Loop's issue report and critical
event log export:

| LupedKit kind | Device log type |
|---|---|
| `toWatch` | `.send` |
| `fromWatch` | `.receive` |
| `error` | `.error` |
| `info` | `.connection` |

## Building

The plugin needs a LoopKit and Loop that include the `SmartwatchManager` plugin type,
and builds inside a LoopWorkspace. The `smartwatch-manager-review` branch of
[dabear/LoopWorkspace](https://github.com/dabear/LoopWorkspace/tree/smartwatch-manager-review)
has everything wired up:

```sh
git clone --branch smartwatch-manager-review --recurse-submodules https://github.com/dabear/LoopWorkspace.git
cd LoopWorkspace
xed LoopWorkspace.xcworkspace
```

Build the `LoopWorkspace` scheme. To run the plugin's tests:

```sh
xcodebuild test -workspace LoopWorkspace.xcworkspace -scheme LupedSmartwatchKit \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

## Adding the watch

The Pebble app already pairs the watch, so there is nothing to pair in Loop. In
Loop, open Settings → Devices → Add Watch → Pebble:

1. **Before you start**: pair the Pebble in the Pebble app, install
   [Luped CGM](https://apps.repebble.com/luped-cgm_d47105a3c7c1489895b067ff),
   and make it the active watchface. Cancel here adds nothing.
2. **Add Pebble**: Loop publishes its Bluetooth service and shows live progress:
   waiting for the watch, connected, and finally the time of the reading the
   watch acknowledged. If Luped isn't the running watchface, the screen says
   so and offers Send Now and the store link.
3. **Done**: closes the screen at any point. Loop keeps connecting in the
   background; Settings → Devices → Pebble shows the same status, and Delete
   Pebble there removes the watch and stops the Bluetooth service.

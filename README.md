# Cone Setter

iPhone app that uses ARKit and the LiDAR scanner to lay out Formula Student / FS-AI test tracks. It shows a ghost cone on the ground for every cone in the layout, guides you to it, and uses each cone you place as a reference for the next ones.

Built for the iPhone 17 Pro Max. Works on any LiDAR iPhone on iOS 18 or later.

## Install with SideStore

Add this source in SideStore (**Sources → +**):

```
https://raw.githubusercontent.com/NB6RULES/ConeSetter/main/source.json
```

Every push to `main` builds a new unsigned IPA on GitHub Actions, publishes it as a release and updates `source.json`, so SideStore shows the update.

## How placing works

1. **Pick a layout.** Skidpad and acceleration are generated from FS dimensions (all editable). Autocross / trackdrive come from a CSV.
2. **Mark two references.** Tape A and B on the ground (e.g. both skidpad circle centres, or the acceleration start and finish line centres). In the app, aim the crosshair at A and tap *Set A*, then the same for B. The app checks the A–B distance against the plan.
3. **Follow the ghost cones.** The panel shows the next cone, an arrow, the distance, and how far the crosshair spot is from the exact position. The crosshair turns green and the phone buzzes inside your tolerance.
4. **Mark the cone.** Put the real cone in the ghost, look down at it, put the crosshair on its tip and tap *Mark placed*. Because the tip sits straight above the base centre, the app gets the base position without seeing under the cone.
5. **Chain mode** (on by default) sets each new cone out from the real cones nearest to it, so ARKit drift doesn't build up down a long straight.

The top-left chips show tracking state, LiDAR mapping, phone GPS accuracy, and the fit RMS across all marked cones. Cones more than 2× tolerance (min 5 cm) from the plan turn red. Tap any cone on the mini-map to (re)do it.

Sessions save the progress, the ARKit world map and a GPS site tag. On a later test day, open the session and walk around: if the saved map is recognised, it carries on; otherwise tap A and B again and it restores the cones you already placed.

## Speed tab (speed logger)

Records the car's speed with timestamps and coordinates, and keeps running with the screen locked.

- **Sensors:** GPS (about 1 Hz) is fused with the IMU (100 Hz) into a **10 Hz** trace, and the barometer gives elevation. Mount the phone firmly in any orientation. The app learns which way is forward from the first launch, braking or corners. When a run stops, the whole run is fused again with the final calibration, so the launch is captured too. If the phone moves or the IMU isn't used, the app falls back to GPS only.
- **Run view:** satellite map with a heatmap path (blue = slow, red = top speed), top / average / moving-average speed, distance, duration, max acceleration, braking and lateral g, 0–100 km/h, 75 m from launch with trap speed, elevation range and climb/descent. Graphs show speed (by time or distance), acceleration (longitudinal and lateral) and elevation. Drag on a graph to see that moment on the map.
- **Skip stops:** hides stationary periods so the graphs close up, with dashed markers where time was cut. **Advanced** sets the speed below which data is skipped, the minimum stop length, and the time kept either side.
- **Excel export (.xlsx):** a Summary sheet with stats plus track and graph images, a Charts sheet with native editable charts (speed, acceleration, speed vs distance, elevation, and the track map coloured by speed band), every sample on the Data sheet, raw GPS fixes, and the series behind the charts. CSV and GPX exports are also available.
- Runs autosave every 30 s. A run cut off by the app closing is recovered the next time the Speed tab opens.

CI runs `Tests/Harness/main.swift`, which simulates laps with noisy GPS, IMU and barometer and an arbitrary phone mount, before every build. Its outputs, including a sample Excel export, are attached to the `ci-test` pre-release.

## CSV format

One cone per row, comma / semicolon / tab separated, metres, `x` forward and `y` left:

```
colour,x,y
refA,0,0
refB,30,0
blue,5,1.5
yellow,5,-1.5
big_orange,0.5,1.5
```

`colour,x,y`, `x,y,colour`, `id,colour,x,y` and FSDS-style `tag,x,y,...` rows are all accepted. If `refA` / `refB` are missing, A is the first cone and B is the farthest cone from it. See `examples/sample_autocross.csv`.

*Export CSV* in the placement screen writes the plan and measured position of every cone, with the error in cm.

## Accuracy notes

- LiDAR measures out to about 5 m. Longer distances rely on ARKit tracking, which drifts. Chain mode, the A–B baseline and the fit RMS are there to keep that in check.
- Plain, smooth concrete tracks worse than textured tarmac.
- Phone GPS (±3–5 m) only tags the site. It can't place cones.
- Check every dimension against the current FS / FS-AI rules and handbook before a real test.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```
brew install xcodegen
xcodegen generate
open ConeSetter.xcodeproj
```

CI: `.github/workflows/build.yml` (macOS runner, unsigned build, release + `source.json` update via `scripts/update_source.py`).

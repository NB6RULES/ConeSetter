# OBRA Run Analyzer (Windows)

Plays back and analyses the speed runs recorded by the phone app.

**Download:** [OBRA-Run-Analyzer.exe](https://github.com/NB6RULES/OBRA-Essentials/releases/download/analyzer-latest/OBRA-Run-Analyzer.exe). This link always gives the newest build. It is a single file with no installer. Windows may show "Windows protected your PC" because the file isn't signed: choose *More info*, then *Run anyway*.

**Updates:** the app checks for a newer build each time it starts. *Update now* downloads it, replaces the .exe and restarts. *Skip this version* stops the prompt until the next build. The version button at the top right checks on demand. GitHub Actions builds the .exe from `desktop/` on every push and writes `desktop/latest.json`, which is what the app reads.

## Using it

1. In the phone app's Speed tab, tap **Select**, tick runs, **Save as zip**, and get the zip onto the PC. A single `.csv`, `.xlsx` or `.gpx` export also works, as does a *Full backup* zip.
2. Drop the file on the window, or **Open runs…**.
3. **Play** (Space) moves the car round the track; the graphs, g-g plot and numbers follow. Click the track or a graph to jump. Left / Right step 0.1 s, with Shift 1 s.
4. **Start / finish:** choose *Click on map* and click the track, or move the car and choose *At car*.
   - Start line only: a circuit. Every crossing ends one lap and starts the next.
   - Start and a separate finish line: each pass from start to finish is timed (acceleration, sprint, autocross).
   - Lines are stored by location, so every run at the same site uses them.
5. **Map:** the track is drawn over satellite imagery (Esri World Imagery). It needs an internet connection the first time a site is opened; after that the images are kept on the PC, so they still show at a track with no signal. Without a connection the map falls back to the plain background. Switch with **Map: Satellite / Plain** at the top.
6. **Car data (MF4 + DBC):** press **Open car log…** and pick the logger's `.mf4` file and the `.dbc` that describes it (or drop both on the window). The **Car data** tab lists every signal by message with its live value; tick signals to plot them under the GPS speed, on the same timeline and cursor as the map and the laps.
   - **Lining up with GPS:** the log is placed using the logger's clock and the phone's GPS time. If the logger's clock is off, click a vehicle-speed or wheel-speed signal and press **Match speed** to line it up on the GPS speed, or type the **Log offset** in seconds.
   - A car log opens on its own too, without a GPS run; there is then no map or laps.
   - Messages that aren't in the DBC are still listed, as raw bytes. The DBC is remembered for next time.
   - MF4 files that hold measured channels instead of CAN frames open without a DBC.
7. **Laps:** click a lap to play only that lap. Ctrl-click several to overlay them in *Lap compare*, with time gained or lost against the fastest of them. *Export laps…* writes a CSV.

Crossing times are interpolated between samples, so lap times resolve finer than the 10 Hz data rate. They are only as accurate as the GPS / IMU positions.

## From source

    pip install -r requirements.txt
    python run_analyzer.py [files]
    python tests/test_core.py

# OBRA Run Analyzer (Windows)

Plays back and analyses the speed runs recorded by the phone app.

**Download:** the newest `OBRA-Run-Analyzer.exe` under [Releases](https://github.com/NB6RULES/ConeSetter/releases) (the entries titled *OBRA Run Analyzer*). It is a single file with no installer. Windows may show "Windows protected your PC" because the file isn't signed: choose *More info*, then *Run anyway*.

## Using it

1. In the phone app's Speed tab, tap **Select**, tick runs, **Save as zip**, and get the zip onto the PC. A single `.csv`, `.xlsx` or `.gpx` export also works.
2. Drop the file on the window, or **Open runs…**.
3. **Play** (Space) moves the car round the track; the graphs, g-g plot and numbers follow. Click the track or a graph to jump. Left / Right step 0.1 s, with Shift 1 s.
4. **Start / finish:** choose *Click on map* and click the track, or move the car and choose *At car*.
   - Start line only: a circuit. Every crossing ends one lap and starts the next.
   - Start and a separate finish line: each pass from start to finish is timed (acceleration, sprint, autocross).
   - Lines are stored by location, so every run at the same site uses them.
5. **Laps:** click a lap to play only that lap. Ctrl-click several to overlay them in *Lap compare*, with time gained or lost against the fastest of them. *Export laps…* writes a CSV.

Crossing times are interpolated between samples, so lap times resolve finer than the 10 Hz data rate. They are only as accurate as the GPS / IMU positions.

## From source

    pip install -r requirements.txt
    python run_analyzer.py [files]
    python tests/test_core.py

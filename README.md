# SimplyWatch

A clean [Garmin Connect IQ](https://developer.garmin.com/connect-iq/) watch face that puts time, activity stats, and a barometric weather forecast on your wrist - no phone connection required.

## Algorithm

### Sager Weathercaster

The forecast engine is based on Raymond Sager's meteorological method (1960s, US Navy). Unlike simpler barometric forecasters, Sager treats **wind direction as a primary forecast dimension** alongside pressure and its trend.

Since a watch face has no compass, the wind direction is genuinely **unknown** rather than calm, and the engine says so: it uses a wind-averaged row instead of asserting a specific wind state. This makes the forecast purely pressure-driven - still useful for detecting approaching fronts, but without the directional refinement available in the companion widget ([SimplyWeather](https://github.com/leonardpitzu/SimplyWeather)), where you point the watch into the wind.

**Inputs** (all derived on-device):
- Current barometric pressure (hPa)
- Pressure trend over the last ~6 hours (rising / steady / falling)
- Current date (for continuous seasonal corrections)
- Hemisphere (north / south, via GPS with Northern fallback)

**How it works:**
1. Three lookup tables (`steadyBase`, `risingBase`, `fallingBase`) produce a base forecast number (0-25).
2. The base number is adjusted by pressure level (±2) - high pressure biases toward fair, low toward unsettled.
3. A seasonal modifier (±1) accounts for summer convective storms and winter clearing patterns, ramping continuously with the date instead of stepping at month boundaries.
4. The final forecast number maps to a condition label (e.g. "Fairly fine, showers likely") and a precipitation probability (0-95%).

**26 forecast conditions** range from *Settled fine* (0) to *Stormy, much rain* (25).

> **Provenance, honestly:** the 26 condition labels are **Zambretti's** vocabulary, not Sager's, and the three lookup tables are hand-built rather than transcribed from Sager's published matrix. Full Sager takes five inputs - wind direction, *wind-direction change*, barometer reading, barometer change and present weather - and this engine feeds it two. The precipitation percentages have no published source. Neither method's original calibration survives that, which is what the measured skill below reflects.

### Barometric Trend Analysis

The rising / steady / falling input to Sager is not a naive "now minus three hours ago" comparison - it comes from a small on-device regression pipeline run over the barometer's stored history during the single-pass iteration:

1. **Mean-sea-level reduction.** Every pressure sample is first reduced to mean sea level using the watch's barometric **elevation history**, so a change in altitude (a climb, a drive uphill, an elevator) cancels out and only genuine weather moves the trend. With no elevation history available it falls back to raw station pressure - identical to the previous behaviour.
2. **Quadratic regression.** A single-pass least-squares parabola is fitted to the sea-level series across the trend window (~6 h). The fitted curve gives the net pressure change over the window, tested against a deadband (default 0.35 hPa/h) to decide rising, steady, or falling. Fitting a parabola rather than a straight line lets a curving pressure profile be read correctly.
3. **Diurnal tide correction.** The atmosphere has a twice-daily pressure tide (~0.6 hPa swing at mid-latitudes). The expected tidal change over the window - amplitude derived from latitude - is subtracted, so the normal daily rhythm is never mistaken for an approaching system.
4. **Short-window front detection.** An **independent** linear fit over only the **last 3 hours** flags a fast-moving front before the longer window catches it. Because it is computed from the recent samples alone, a large pressure wiggle earlier in the window cannot contaminate it.
5. **Hysteresis & front passage.** The trend is quick to raise an alarm and slow to clear it, and a passing front (was falling, now levelling with pressure recovering) is upgraded to rising.

A glitched elevation sample cannot poison the series: the sea-level reduction clamps altitude to a physical range. This pipeline replaces an earlier point-sample second-derivative ("acceleration") trigger that over-reacted to short pressure wiggles and to altitude changes.

### Measured Skill

Earlier revisions of this file quoted accuracy figures of 60-80%. Those were never measured. They have been replaced with a verification against a rain gauge.

Scored over 40 days against a co-located weather station - 926 hourly forecasts, 13.2% of 6-hour windows wet:

| Metric | Value | Reading |
|---|---|---|
| Brier score | 0.159 | climatology scores 0.114 |
| Brier skill score | **-0.39** | negative: worse than always forecasting the average |
| Reliability | 75% stated -> 25% observed | the stated probability is not a probability |
| False-alarm ratio | 0.76 | three in four warnings did not verify |
| Resolution | 0.002 | almost no information about *when* rain arrives |

The barometric tendency carries essentially no 6-hour rain signal at the test site (rank correlation +0.00 against observed rain) but a clear 24-hour one (-0.68), so the forecast horizon is itself under review.

A calibrated replacement is in progress. It is blocked on data rather than on code: 40 days spans a single regime change, so every cross-validation fold trains on a climate the held-out fold does not share.

> **Read the forecast as a barometer readout with a label attached, not as a probability of rain.**

## Features

### Time & Date

Large, easy-to-read digital time in the centre of the display with the full date (`Thu, 20 Feb 2026`) just below.

### Activity Stats

| Stat | Description |
|---|---|
| **Steps** | Daily step count (in thousands), shown with an icon |
| **Distance** | Daily distance (in km), shown with an icon |
| **Notifications** | Unread notification indicator at the top of the screen |
| **Battery** | Estimated battery life remaining in days |

### Weather Forecast

- **Forecast text** - a short condition such as *Settled fine*, *Changeable, showers likely*, or *Stormy, much rain*, with a precipitation probability percentage when applicable.
- **Weather icon** - context-aware by time of day and season (see table below).
- **Hemisphere-aware** - automatically detects your hemisphere via GPS and adjusts seasonal corrections accordingly.
- **Refresh cycle** - the forecast recalculates every 3 hours to balance accuracy with battery life.

### Weather Icons

The watch face selects an icon based on three inputs: the Sager forecast number, time of day, and season.

**Day / night** is determined by a fixed 07:00-19:00 window.

**Season** is hemisphere-aware - Northern: Dec-Feb = cold season; Southern: May-Sep = cold season.

| Forecast | Condition | Warm season | Cold season |
|---|---|---|---|
| 0-1 | Clear / fine | ☀️ Sun (day) / 🌙 Moon (night) | ☀️ Sun (day) / 🌙 Moon (night) |
| 2-6 | Fair / variable | 🌤 Cloud-day / ☁️🌙 Cloud-night | 🌤 Cloud-day / ☁️🌙 Cloud-night |
| 7-21 | Showers -> rain | 🌧 Rainy | 🌨 Snowy |
| 22-25 | Stormy | ⛈ Thunderstorm | 🌨❄️ Snowstorm |

> Note: unlike the companion widget, bands 7-21 are grouped into a single rain/snow icon (no day/night or light/heavy variants) to keep the watch face clean.

## Supported Devices

- Garmin Fenix 8 Solar (47 mm)

> Requires Connect IQ API 5.1.0 or later. Additional devices can be added via `manifest.xml`.

## Permissions

| Permission | Reason |
|---|---|
| **SensorHistory** | Read barometric pressure history to calculate pressure trends |
| **Positioning** | Detect hemisphere (north/south) for seasonal corrections |
| **Notifications** | Show unread notification count on the watch face |

## Install

Build with the Garmin Connect IQ SDK and side-load the `.prg` file to your watch.

### Side-load (manual)

1. Clone or download this repository.
2. Open the project in Visual Studio Code with the [Monkey C extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c).
3. Build for your device (`Monkey C: Build for Device`).
4. Copy the generated `.prg` file to your watch's `GARMIN/APPS` directory.

## Development

### Prerequisites

- [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 5.1.0+
- Visual Studio Code with the Monkey C extension

### Build

```sh
# Build via the VS Code command palette:
#   Monkey C: Build for Device
# or use the Connect IQ CLI:
monkeyc -f monkey.jungle -o SimplyWatch.prg -d fenix8solar47mm
```

### Project Structure

```
source/
  SimplyWatchApp.mc        # Application entry point
  SimplyWatchView.mc       # Watch face layout, rendering & pressure logic
  SimplyWatchForecast.mc   # Sager Weathercaster forecast engine
resources/
  drawables/               # SVG icons (weather, battery, steps, etc.)
  strings/                 # App name
  forecast-strings/        # Forecast condition descriptions (26 outcomes)
```

## Credits

- **Sager Weathercaster**: Based on Raymond Sager's barometric forecasting method (1960s, US Navy)
- **Icon design**: [Freepik](https://www.flaticon.com/authors/freepik) from Flaticon, licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

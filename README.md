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

1. **Mean-sea-level reduction.** Every pressure sample is first reduced to mean sea level using the watch's barometric **elevation history**, gated so that only movement too fast to be weather counts as altitude: a climb, a drive uphill or an elevator cancels out and only genuine weather moves the trend. The pressure shown and the rain model use the same reduction, so the three cannot disagree. With no elevation history the trend falls back to raw station pressure, and the forecaster is told the reading is not a sea-level one.
2. **Quadratic regression.** A single-pass least-squares parabola is fitted to the sea-level series across the trend window (~6 h). The fitted curve gives the net pressure change over the window, tested against a deadband (default 0.17 hPa/h, Sager's "slowly" boundary of 1 hPa in 6 h) to decide rising, steady, or falling. Fitting a parabola rather than a straight line lets a curving pressure profile be read correctly.
3. **Diurnal tide correction.** Pressure rises and falls every day with no weather behind it - about 1-2 hPa at mid-latitudes, more in valleys and basins. The watch learns its own site's daily cycle, in 24 sun-time slots, from the pressure record the barometer keeps whether or not the face is on screen, so it keeps learning through activities and nights, and subtracts it from every window. A latitude climatology stands in only until the record covers a day. Travel more than 200 km and the learned cycle is kept - most of it is solar, and in a traveller simulation across ten sites keeping it halved the leftover daily cycle on the day of arrival against starting over - while the windows that straddle the journey are skipped.
4. **Short-window front detection.** An **independent** linear fit over only the **last 3 hours** flags a fast-moving front before the longer window catches it. Because it is computed from the recent samples alone, a large pressure wiggle earlier in the window cannot contaminate it.
5. **Hysteresis & front passage.** The trend is quick to raise an alarm and slow to clear it, and a passing front (was falling, now levelling with pressure recovering) is upgraded to rising.

A glitched elevation sample cannot poison the series: the sea-level reduction clamps altitude to a physical range. This pipeline replaces an earlier point-sample second-derivative ("acceleration") trigger that over-reacted to short pressure wiggles and to altitude changes.

### Measured Skill

Earlier revisions of this file quoted accuracy figures of 60-80%. Those were never measured. They have been replaced with a verification against a rain gauge.

The engine was replaced in September 2026. The Sager lookup table it used before was scored over 73 days against a co-located weather station and found to separate wet hours from dry ones no better than a coin flip: **area under the ROC curve 0.52**, in every cross-validation fold. Its stated probabilities were not probabilities either - "75%" verified at 13%.

What ships now is a single calibrated feature: tide-free sea-level pressure measured against the site's own recent history, in units of the site's own recent spread. Scored over 73 days, 1400 day-ahead forecasts, 21.4% of 24-hour windows wet:

| Metric | New engine | Old table | Reading |
|---|---|---|---|
| Brier score | **0.158** | 0.226 | climatology scores 0.168 |
| Discrimination (fold AUC) | **0.73** | 0.52 | 0.5 is a coin flip |
| Reliability | 24% stated -> 29% observed | 75% -> 13% | the number now means something |
| Resolution | 0.011 | 0.001 | information about *when* |
| False-alarm ratio | 0.68 | 0.88 | still high; see below |

**What it does and does not do.** It orders hours well - given two hours, it reliably ranks the wetter one higher, and it does so in every fold of the record. It does **not** beat a constant forecast of the local average: out of sample its Brier skill score is +0.02, and a control feature consisting of nothing but "days since the record started" scores +0.03 on the same data. Seventy-three summer days cannot establish what the local average is across a year, so the absolute level is not yet earned. That is why the probabilities are narrow (5% to 60%) and why the descriptions above "Rain at times" are unreachable: a single barometer does not know enough to say *Stormy*.

**Away from home.** The same feature was scored at ten sites on four continents (NOAA ISD 2019-2023 plus the home station), each held out from the fit. The ordering travels to Europe - area under the curve 0.63-0.66 in the Alps, on the Atlantic and on the Black Sea - weakly to the American plains (0.54), and not at all to Sydney or the tropics (0.50-0.52). The level does not travel: the share of wet 24-hour windows runs from 8% in Phoenix to 63% in Brest, and a fit pooled over the other sites did worse on average and worse at home than the home fit. So the percentage is calibrated at home, and on the road it is a ranking: higher means wetter than usual *for where you are*, not a stated chance.

Removing the daily tide from the reading matters because the day means it is compared against have none: left in, the rain chance on the home archive carried a daily swing of its own, 21% at 09:00 sun time against 24% at 16:00; removed, the swing is 0.4 points.

The horizon moved from 6 hours to 24 for the same reason - the barometric signal at this site is a day-ahead one (rank correlation -0.68 at 24 h against +0.00 at 6 h).

The forecaster is shared byte-for-byte with the [simplyweather](https://github.com/leonardpitzu/simplyweather) glance, which verifies that on every run. The old table is used only until 14 days have closed; the first pass closes every day the watch's own record already holds.

> **Read the forecast as a well-ordered barometer readout, not as a calibrated probability of rain.**

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

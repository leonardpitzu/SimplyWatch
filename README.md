# SimplyWatch

A clean [Garmin Connect IQ](https://developer.garmin.com/connect-iq/) watch face that puts time, activity stats, and a barometric weather forecast on your wrist — no phone connection required.

## Algorithm

### Sager Weathercaster

The forecast engine is based on Raymond Sager's meteorological method (1960s, US Navy). Unlike simpler barometric forecasters, Sager treats **wind direction as a primary forecast dimension** alongside pressure and its trend.

Since a watch face has no compass input, wind direction is fixed to calm (octant 0). This makes the forecast purely pressure-driven — still effective for detecting approaching fronts, but without the directional refinement available in the companion widget ([SimplyWeather](https://github.com/leonardpitzu/SimplyWeather)).

**Inputs** (all derived on-device):
- Current barometric pressure (hPa)
- Pressure trend over the last ~3 hours (rising / steady / falling)
- Current month (for seasonal corrections)
- Hemisphere (north / south, via GPS with Northern fallback)

**How it works:**
1. Three lookup tables (`steadyBase`, `risingBase`, `fallingBase`) produce a base forecast number (0–25).
2. The base number is adjusted by pressure level (±2) — high pressure biases toward fair, low toward unsettled.
3. A seasonal modifier (±1) accounts for summer convective storms and winter clearing patterns.
4. The final forecast number maps to a condition label (e.g. "Fairly fine, showers likely") and a precipitation probability (0–95%).

**26 forecast conditions** range from *Settled fine* (0) to *Stormy, much rain* (25).

### Pressure-Change Acceleration

On top of the standard trend, the engine computes the **second derivative** of pressure (P″) using three hourly samples captured during the single-pass pressure iteration:

$$P'' = P_0 - 2 P_{-1} + P_{-2}$$

A 0.15 hPa deadband filters sensor quantisation noise. Three refinement rules modify the trend input to Sager before the forecast lookup:

| Condition | Rule | Effect |
|---|---|---|
| Trend is steady, P″ ≤ −0.5 | Upgrade to falling | Early storm warning — pressure drop is accelerating before the 3 h window catches it |
| Trend is falling, P″ > +0.5 | Downgrade to steady | Front is passing — pressure deceleration means conditions are stabilising |
| Trend is rising, P″ ≤ −1.0 | Keep rising (no flip) | Noise filter — prevents a sensor glitch from overriding a genuine high-pressure build |

Hourly samples are captured by index proximity (sample 12 ≈ −1 h, sample 24 ≈ −2 h at ~5 min spacing) with a ±35 min tolerance window.

### Expected Accuracy

Barometric forecasting precision varies by terrain and weather pattern. Without wind direction input, accuracy is slightly lower than the companion widget:

| Scenario | Accuracy | Lead time | Notes |
|---|---|---|---|
| **Urban / lowland** | ~75% | 2–4 h | Stable environment, pressure patterns read cleanly; acceleration catches convective buildups 30–60 min earlier |
| **Mountain hiking (1500–2500 m)** | ~60% | 1–3 h | Altitude thermals and terrain-funnelled winds add noise. Always cross-check official mountain forecasts. |
| **Coastal / seaside** | ~80% | 3–6 h | Flat terrain, clean pressure gradients — best case for barometric forecasting. Fronts approach predictably. |

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

- **Forecast text** — a short condition such as *Settled fine*, *Changeable, showers likely*, or *Stormy, much rain*, with a precipitation probability percentage when applicable.
- **Weather icon** — context-aware by time of day and season (see table below).
- **Hemisphere-aware** — automatically detects your hemisphere via GPS and adjusts seasonal corrections accordingly.
- **Refresh cycle** — the forecast recalculates every 3 hours to balance accuracy with battery life.

### Weather Icons

The watch face selects an icon based on three inputs: the Sager forecast number, time of day, and season.

**Day / night** is determined by a fixed 07:00–19:00 window.

**Season** is hemisphere-aware — Northern: Dec–Feb = cold season; Southern: May–Sep = cold season.

| Forecast | Condition | Warm season | Cold season |
|---|---|---|---|
| 0–1 | Clear / fine | ☀️ Sun (day) / 🌙 Moon (night) | ☀️ Sun (day) / 🌙 Moon (night) |
| 2–6 | Fair / variable | 🌤 Cloud-day / ☁️🌙 Cloud-night | 🌤 Cloud-day / ☁️🌙 Cloud-night |
| 7–21 | Showers → rain | 🌧 Rainy | 🌨 Snowy |
| 22–25 | Stormy | ⛈ Thunderstorm | 🌨❄️ Snowstorm |

> Note: unlike the companion widget, bands 7–21 are grouped into a single rain/snow icon (no day/night or light/heavy variants) to keep the watch face clean.

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

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

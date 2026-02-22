# SimplyWatch

A clean [Garmin Connect IQ](https://developer.garmin.com/connect-iq/) watch face that puts time, activity stats, and a barometric weather forecast on your wrist — no phone connection required.

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

A local 12-hour weather forecast powered by the **Zambretti algorithm** — a classic barometric forecasting method that is over 90% accurate in temperate zones. The forecast runs entirely on-device using your watch's pressure sensor history; no internet or phone needed.

- **Forecast text** — a short description such as *Settled fine*, *Changeable, showers likely*, or *Stormy, much rain*, with a rain probability percentage when applicable.
- **Weather icon** — changes based on forecast severity, time of day (day/night), and season (rain vs. snow in winter):

  | Icon | Condition |
  |---|---|
  | ☀️ / 🌙 | Clear (day / night) |
  | ⛅ / 🌥️ | Cloudy (day / night) |
  | 🌧️ | Rainy |
  | 🌨️ | Snowy |
  | ⛈️ | Thunderstorm |
  | 🌨️❄️ | Snowstorm |

- **Hemisphere-aware** — automatically detects your hemisphere via GPS and adjusts seasonal and wind-direction corrections accordingly.
- **Pressure trend** — analyses the barometric pressure history (up to ~3 hours) to determine whether pressure is rising, steady, or falling, refining the forecast.
- **Smart promotions** — in high-pressure, stable conditions the forecast is promoted from *Showery* to *Fine* or *Fair* to avoid overly pessimistic readings.

### Forecast Descriptions

The Zambretti algorithm produces 26 distinct forecast outcomes, ranging from **Settled fine** through **Changeable** and **Unsettled** all the way to **Stormy** — each with an optional qualifying phrase like *improving*, *showers likely*, or *worsening*.

## Supported Devices

- Garmin Fenix 8 Solar (47 mm)

> Requires Connect IQ API 5.1.0 or later. Additional devices can be added via `manifest.xml`.

## Permissions

| Permission | Reason |
|---|---|
| **SensorHistory** | Read barometric pressure history for the Zambretti forecast |
| **Positioning** | Detect hemisphere (north/south) for seasonal corrections |
| **Notifications** | Show unread notification count on the watch face |

## Install

Compile yourself, copy to the watch and enjoy!

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
  SimplyWatchView.mc       # Watch face layout & rendering
  SimplyWatchForecast.mc   # Zambretti weather forecast algorithm
resources/
  drawables/               # SVG icons (weather, battery, steps, etc.)
  strings/                 # App name
  forecast-strings/        # Localised forecast descriptions (26 outcomes)
```

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

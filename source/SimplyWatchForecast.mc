// Sager Weathercaster — Wind-direction-aware barometric forecast
// Based on Raymond Sager's meteorological forecasting method (1960s, US Navy)
// Adapted for Garmin Connect IQ: altitude-safe, power-efficient, glance-ready
//
// Key advantages over Zambretti:
//   - Wind direction is a primary forecast dimension (not a fudge factor)
//   - Pressure level context prevents false alarms at altitude
//   - Six effective trend categories (via pressure-level cross-reference)
//   - Seasonal and hemispheric corrections built into the table
//   - Direct precipitation probability (no arbitrary pair-code mapping)

import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.Math;

module Sager {

    // ── Forecast conditions (26 entries, indexed 0-25) ──────────────────────
    var forecastStrings as Array<Lang.ResourceId> = [
        Rez.Strings.SF,   // 0  Settled fine
        Rez.Strings.FW,   // 1  Fine weather
        Rez.Strings.BF,   // 2  Becoming fine
        Rez.Strings.FN,   // 3  Fine
        Rez.Strings.FF,   // 4  Fairly fine
        Rez.Strings.CH,   // 5  Changeable
        Rez.Strings.FF,   // 6  Fairly fine
        Rez.Strings.RU,   // 7  Rather unsettled
        Rez.Strings.UN,   // 8  Unsettled
        Rez.Strings.SHE,  // 9  Showery early
        Rez.Strings.CH,   // 10 Changeable
        Rez.Strings.UN,   // 11 Unsettled
        Rez.Strings.UN,   // 12 Unsettled
        Rez.Strings.RU,   // 13 Rather unsettled
        Rez.Strings.SH,   // 14 Showery
        Rez.Strings.CH,   // 15 Changeable
        Rez.Strings.UN,   // 16 Unsettled
        Rez.Strings.VU,   // 17 Very unsettled
        Rez.Strings.OR,   // 18 Occasional rain
        Rez.Strings.RT,   // 19 Rain at times
        Rez.Strings.VU,   // 20 Very unsettled
        Rez.Strings.RA,   // 21 Rain
        Rez.Strings.ST,   // 22 Stormy
        Rez.Strings.RA,   // 23 Rain
        Rez.Strings.ST,   // 24 Stormy
        Rez.Strings.ST    // 25 Stormy
    ];

    // ── Sager lookup tables: wind octant × trend → base forecast code ──────
    // Wind octants: 0=Calm 1=N 2=NE 3=E 4=SE 5=S 6=SW 7=W 8=NW
    // Northern Hemisphere reference; Southern is mirrored at query time.
    var steadyBase  as Array<Number> = [ 6,  4,  7, 11, 13, 14, 10,  6,  3];
    var risingBase  as Array<Number> = [ 3,  1,  3,  5,  5,  6,  4,  2,  1];
    var fallingBase as Array<Number> = [15, 12, 17, 20, 21, 22, 19, 15, 11];

    // ── Precipitation probability by forecast code (%) ─────────────────────
    var precipProb as Array<Number> = [
         0,  0,  5, 10, 20, 25, 30, 35, 40, 30,
        45, 50, 60, 55, 50, 60, 70, 75, 70, 80,
        85, 85, 80, 90, 95, 95
    ];

    // ── String cache (loaded once, reused) ──────────────────────────────────
    var forecastCache as Array<String> = [];

    function forecast(f as Number) as String {
        var idx = f.toNumber();
        if (idx < 0 || idx >= forecastStrings.size()) {
            return "";
        }

        if (forecastCache.size() == 0) {
            for (var i = 0; i < forecastStrings.size(); i++) {
                forecastCache.add(WatchUi.loadResource((forecastStrings as Array<Lang.ResourceId>)[i]) as String);
            }
        }

        return (forecastCache as Array<String>)[idx];
    }

    // ── Convert 16-point compass (1-16) to 8-point octant (1-8); 0 = calm ─
    function windToOctant(dir16 as Number) as Number {
        if (dir16 < 1 || dir16 > 16) {
            return 0;
        }
        return ((dir16 - 1) / 2).toNumber() + 1;
    }

    // ── Mirror wind octant for Southern Hemisphere (rotate 180°) ───────────
    function mirrorWind(octant as Number) as Number {
        if (octant == 0) {
            return 0;
        }
        return ((octant - 1 + 4) % 8) + 1;
    }

    // ── Classify MSL pressure into Low(0) / Normal(1) / High(2) ──────────
    //    Thresholds shift ±5 hPa seasonally following mid-latitude SLP variation.
    //    NH winter (Jan): mean SLP ~1020 → thresholds shift UP (+5)
    //    NH summer (Jul): mean SLP ~1013 → thresholds shift DOWN (-5)
    //    Works correctly at any altitude when fed MSL-equivalent pressure.
    function pressureLevel(hpa as Number, month as Lang.Float or Lang.Number, hemisphere as Number) as Number {
        var seasonalOffset = 5.0 * seasonalIndex(month, hemisphere);
        var lowThreshold = 1005.0 + seasonalOffset;
        var highThreshold = 1025.0 + seasonalOffset;
        if (hpa < lowThreshold) { return 0; }
        if (hpa > highThreshold) { return 2; }
        return 1;
    }

    // ── Continuous seasonality scalar ───────────────────────────────────────
    //   +1 ≈ deep winter (mid-Jan, highest mean SLP), −1 ≈ deep summer (mid-Jul).
    //   Hemisphere-aware. Replaces hard calendar-month bands so seasonal
    //   corrections ramp smoothly instead of stepping on month boundaries.
    //   Accepts a fractional month (e.g. 6.5 = mid-June) for day-level smoothness.
    function seasonalIndex(month as Lang.Float or Lang.Number, hemisphere as Number) as Float {
        var c = Math.cos(2.0 * Math.PI * (month.toFloat() - 1.0) / 12.0);
        if (hemisphere != 1) { c = -c; }
        return c;
    }

    // ── Main forecast entry ────────────────────────────────────────────────
    // Returns: [forecastText, forecastNumber, precipProbability]
    //
    // forecastNumber severity bands for icon selection:
    //   0-1  → clear/fine    2-6  → fair/variable
    //   7-21 → rain/snow     22-25 → storm
    function WeatherForecast(pressureHpa as Float or Number, month as Lang.Float or Lang.Number, windDir as Number, trend as Number, hemisphere as Number, steadyHours as Number) as Array {

        // ── Wind direction → octant, hemisphere-aware ──────────────────────
        var octant = windToOctant(windDir);
        if (hemisphere != 1) {
            octant = mirrorWind(octant);
        }

        // ── Sager table lookup: wind octant × barometric trend ─────────────
        // Accumulated on a float so seasonal corrections can ramp continuously;
        // rounded to a discrete forecast code once all modifiers are applied.
        var baseF = ((trend == 1) ? risingBase[octant]
                  : (trend == 2) ? fallingBase[octant]
                  : steadyBase[octant]).toFloat();

        // ── Pressure-level modifier ────────────────────────────────────────
        // Shifts forecast toward better (high MSL) or worse (low MSL).
        // Altitude-safe: uses fixed MSL thresholds, not user-configurable range.
        var pLevel = pressureLevel(pressureHpa.toNumber(), month, hemisphere);
        if (pLevel == 0) {
            baseF += 2.0;
        } else if (pLevel == 2) {
            baseF -= 2.0;
        }

        // ── Seasonal modifier (continuous) ─────────────────────────────────
        // Summer: convective storms intensify faster on a falling barometer.
        // Winter: clearing on a rising barometer is more decisive.
        // Both ramp with seasonality (±1 deep season → 0 at the equinoxes)
        // instead of switching abruptly on calendar-month boundaries.
        var season = seasonalIndex(month, hemisphere);
        var summerness = (season < 0.0) ? -season : 0.0;
        var winterness = (season > 0.0) ? season : 0.0;
        if (trend == 2) {
            baseF += summerness;   // summer convective storms intensify faster
        } else if (trend == 1) {
            baseF -= winterness;   // winter clearing is more decisive
        }

        var base = Math.round(baseF).toNumber();

        // ── Persistence modifier ───────────────────────────────────────────
        // Prolonged pressure stability at Normal/High → settled weather.
        // Only applies when base forecast is already in the fair range (0-6).
        if (trend == 0 && pLevel >= 1 && base <= 6 && steadyHours >= 6) {
            if (steadyHours >= 24) {
                base = 0;   // Settled fine
            } else if (steadyHours >= 12) {
                base = 1;   // Fine weather
            } else {
                base = 3;   // Fine
            }
        }

        // ── Clamp to valid range ───────────────────────────────────────────
        if (base < 0)  { base = 0; }
        if (base > 25) { base = 25; }

        return [forecast(base), base, precipProb[base]];
    }

}

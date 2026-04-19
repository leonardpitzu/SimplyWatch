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

    // ── Classify MSL pressure: Low(0) < 1005, Normal(1) 1005-1025, High(2) > 1025
    //    Standard meteorological thresholds — no user config required.
    //    Works correctly at any altitude when fed MSL-equivalent pressure.
    function pressureLevel(hpa as Number) as Number {
        if (hpa < 1005) { return 0; }
        if (hpa > 1025) { return 2; }
        return 1;
    }

    // ── Main forecast entry ────────────────────────────────────────────────
    // Returns: [forecastText, forecastNumber, precipProbability]
    //
    // forecastNumber severity bands for icon selection:
    //   0-1  → clear/fine    2-6  → fair/variable
    //   7-21 → rain/snow     22-25 → storm
    function WeatherForecast(pressureHpa as Float or Number, month as Number, windDir as Number, trend as Number, hemisphere as Number) as Array {

        // ── Wind direction → octant, hemisphere-aware ──────────────────────
        var octant = windToOctant(windDir);
        if (hemisphere != 1) {
            octant = mirrorWind(octant);
        }

        // ── Sager table lookup: wind octant × barometric trend ─────────────
        var base = (trend == 1) ? risingBase[octant]
                 : (trend == 2) ? fallingBase[octant]
                 : steadyBase[octant];

        // ── Pressure-level modifier ────────────────────────────────────────
        // Shifts forecast toward better (high MSL) or worse (low MSL).
        // Altitude-safe: uses fixed MSL thresholds, not user-configurable range.
        var pLevel = pressureLevel(pressureHpa.toNumber());
        if (pLevel == 0) {
            base += 2;
        } else if (pLevel == 2) {
            base -= 2;
        }

        // ── Seasonal modifier ──────────────────────────────────────────────
        var isSummer = (hemisphere == 1)
            ? (month >= 4 && month <= 9)
            : (month >= 10 || month <= 3);

        if (trend == 2 && isSummer) {
            base += 1;   // summer convective storms intensify faster
        } else if (trend == 1 && !isSummer) {
            base -= 1;   // winter clearing is more decisive
        }

        // ── Clamp to valid range ───────────────────────────────────────────
        if (base < 0)  { base = 0; }
        if (base > 25) { base = 25; }

        return [forecast(base), base, precipProb[base]];
    }

}

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

    // Forecast to use when the wind direction is unknown, indexed by trend
    // (0 steady, 1 rising, 2 falling). Each is the code whose precipitation
    // probability is nearest the mean over the eight octants, ties to the lower
    // code. Averaging the probabilities rather than defaulting to the Calm column
    // cuts the dry bias from 8.1 to 3.1 percentage points.
    var unknownBase as Array<Number> = [7, 3, 16];

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

    // ── Wind bearing (degrees) to 8-point octant (1-8) ─────────────────────
    //    Taken from the bearing, not from a 16-point index: the 22.5 deg octant
    //    boundary falls on the centre of the NNE bucket, so any 16-to-8 mapping
    //    rotates the rose by 11.25 deg and misassigns a quarter of the compass.
    function octantFromBearing(deg as Float) as Number {
        var h = deg;
        while (h < 0.0) { h += 360.0; }
        while (h >= 360.0) { h -= 360.0; }
        return (((h + 22.5) / 45.0).toNumber() % 8) + 1;
    }

    // ── Mirror wind octant for Southern Hemisphere (rotate 180°) ───────────
    function mirrorWind(octant as Number) as Number {
        if (octant == 0) {
            return 0;
        }
        return ((octant - 1 + 4) % 8) + 1;
    }

    // ── Atmospheric tide ────────────────────────────────────────────────────
    //   Both apps share this so they cannot disagree on the correction. Checked
    //   against the Dai & Wang (1999) gridded climatology: the cos^3 law and the
    //   116 Pa equator value reproduce the observed zonal means, but the peak is
    //   at 10.0 h local solar time, not the 9.5 h used previously.
    const S2_AMP_EQUATOR_PA = 116.0;
    const S2_AMP_DEFAULT_PA = 41.0;   // ~45 deg latitude
    const S2_PHASE_H = 10.0;

    // Annual zonal-mean S1 as (real, imag) Pa every 15 deg from -90. The vector
    // mean is the least-squares optimum for any latitude-only model. Components
    // are interpolated rather than amplitude and phase, because phase wraps at
    // 24 h. Poles are zero: a sun-synchronous wave-1 pattern is degenerate there,
    // so the grid's polar values are sparse-station noise.
    const S1_NODE_STEP_DEG = 15.0;
    var s1ZonalPa as Array<Float> = [
          0.00,   0.00,    0.00,   0.00,   25.25,   7.64,   -3.93, -11.95,
         -7.56,  19.41,  -12.56,  43.97,   -4.09,  56.07,   -9.25,  44.95,
        -18.34,  30.63,  -15.87,  15.46,    0.27,   7.11,    0.00,   0.00,
          0.00,   0.00
    ];
    // Fallback while the watch has no cached position. Globally the error curve
    // is flat between 0 and 40 Pa, but dropping the term outright is much worse
    // wherever the diurnal signal is genuinely large.
    const S1_DEFAULT_PA = 40.0;
    const S1_DEFAULT_PHASE_H = 4.8;

    function s2Amplitude(latDeg as Float or Null) as Float {
        if (latDeg == null) { return S2_AMP_DEFAULT_PA; }
        var c = Math.cos((latDeg as Float) * Math.PI / 180.0);
        return (S2_AMP_EQUATOR_PA * c * c * c).toFloat();
    }

    // Returns [amplitude Pa, phase hours LST].
    function s1Tide(latDeg as Float or Null) as Array<Float> {
        if (latDeg == null) { return [S1_DEFAULT_PA, S1_DEFAULT_PHASE_H]; }
        var lat = latDeg as Float;
        if (lat > 90.0) { lat = 90.0; } else if (lat < -90.0) { lat = -90.0; }
        var x = (lat + 90.0) / S1_NODE_STEP_DEG;
        var k = x.toNumber();
        if (k > 11) { k = 11; }
        var f = x - k.toFloat();
        var i = k * 2;
        var re = s1ZonalPa[i] + f * (s1ZonalPa[i + 2] - s1ZonalPa[i]);
        var im = s1ZonalPa[i + 1] + f * (s1ZonalPa[i + 3] - s1ZonalPa[i + 1]);
        var amp = Math.sqrt(re * re + im * im);
        var phase = Math.atan2(im, re) * 24.0 / (2.0 * Math.PI);
        if (phase < 0.0) { phase += 24.0; }
        return [amp.toFloat(), phase.toFloat()];
    }

    function tidePa(solarHour as Float, s2Amp as Float, s1Amp as Float, s1Phase as Float) as Float {
        return (s2Amp * Math.cos(2.0 * Math.PI * (solarHour - S2_PHASE_H) / 12.0)
             + s1Amp * Math.cos(2.0 * Math.PI * (solarHour - s1Phase) / 24.0)).toFloat();
    }

    function tideSlopePaH(solarHour as Float, s2Amp as Float, s1Amp as Float, s1Phase as Float) as Float {
        return (0.0 - s2Amp * (2.0 * Math.PI / 12.0)
                    * Math.sin(2.0 * Math.PI * (solarHour - S2_PHASE_H) / 12.0)
              - s1Amp * (2.0 * Math.PI / 24.0)
                    * Math.sin(2.0 * Math.PI * (solarHour - s1Phase) / 24.0)).toFloat();
    }

    // ── Tide-model uncertainty and the thresholds it sets ───────────────────
    //   What the correction gets wrong, not what it removes. Fitted to the median
    //   residual of the model above against Dai & Wang across all four seasons and
    //   every grid cell with |lat| < 66: 61.8 Pa over 6h10m, 37.7 over 3 h, 19.8
    //   over 1.5 h.
    const TIDE_ERR_S1_PA = 46.5;
    const TIDE_ERR_S2_PA = 28.0;

    // Differencing a sinusoid of period P and amplitude error u over `hours` has
    // an RMS over phase of u*sqrt(2)*|sin(pi*hours/P)|; the harmonics are
    // independent so they add in quadrature. Sublinear in `hours`, which is the
    // point: a threshold linear in the window under-protects the short ones.
    function tideUncertaintyPa(hours as Float) as Float {
        var s1 = TIDE_ERR_S1_PA * Math.sin(Math.PI * hours / 24.0);
        var s2 = TIDE_ERR_S2_PA * Math.sin(Math.PI * hours / 12.0);
        return Math.sqrt(2.0 * (s1 * s1 + s2 * s2)).toFloat();
    }

    // Steady/moving threshold for a window, scaled by what the tide can fake.
    // Anchored on the main window so Sager's own dead zone survives there exactly,
    // while the short windows inherit a threshold that holds the tide's authority
    // constant instead of letting it grow as the window shrinks.
    function windowLimitPa(hours as Float, steadyPaPerH as Float, mainHours as Float) as Float {
        if (hours >= mainHours) { return steadyPaPerH * hours; }
        var reference = tideUncertaintyPa(mainHours);
        if (reference <= 0.0) { return steadyPaPerH * hours; }
        return steadyPaPerH * mainHours * tideUncertaintyPa(hours) / reference;
    }

    // ── Learned daily cycle ─────────────────────────────────────────────────
    //   S1 is thermally driven, so at a given site it is whatever the local land
    //   and terrain make it, and a zonal mean cannot know that: at the reference
    //   station S1 runs 84 Pa at 5.3 h against the table's 21 Pa at 9.0 h.
    //   Differenced over the main window that leftover wave is worth ~107 Pa
    //   against a ~105 Pa threshold, i.e. the afternoon heating alone reads as a
    //   front. So the daily cycle is measured here rather than assumed.
    //
    //   The measurement is one residual at a time: the mean over 24 h is an exact
    //   null for both harmonics, and being centred it also cancels the synoptic
    //   ramp at the middle of the window, so the sample 12 h back minus that mean
    //   is the daily cycle plus noise. Residuals are averaged into solar-hour
    //   bins, and it is that averaging across days that removes the noise. A
    //   least-squares fit over a trailing day or two instead cannot separate the
    //   two and lands 30-40% high with an unstable phase.
    const LEARN_WINDOW_SEC = 86400;
    const LEARN_LAG_SEC = 43200;
    const LEARN_MIN_COVERAGE = 0.96;
    const LEARN_DECIMATE_SEC = 900;
    const LEARN_ALPHA = 0.3;
    const LEARN_MIN_BINS = 12;
    // Hourly slots: 24 h of context plus the sample being judged.
    const LEARN_RING_SLOTS = 25;
    const LEARN_RING_MAX_GAP_SEC = 5400;
    // A scan that came back empty keeps coming back empty until the record is long
    // enough to centre a window in, so it is retried on a timer, never hourly.
    const LEARN_RESCAN_SEC = 21600;
    // This far from the daily mean is synoptic weather, not a daily cycle.
    const LEARN_MAX_RESIDUAL_PA = 400.0;
    const LEARN_MAX_AMP_PA = 300.0;
    // Beyond this the learned cycle belongs to somewhere else.
    const LEARN_RESET_KM = 200.0;

    function binsFilled(mask as Number) as Number {
        var n = 0;
        for (var i = 0; i < 24; i++) {
            if ((mask & (1 << i)) != 0) { n += 1; }
        }
        return n;
    }

    // True when the watch has moved far enough that the cycle it learned belongs
    // to the terrain it left behind.
    function profileMoved(latDeg as Float or Null, lonDeg as Float or Null,
                          prevLat as Float or Null, prevLon as Float or Null) as Boolean {
        if (latDeg == null || lonDeg == null || prevLat == null || prevLon == null) {
            return false;
        }
        var dLat = ((latDeg as Float) - (prevLat as Float)) * 111.0;
        var dLon = ((lonDeg as Float) - (prevLon as Float)) * 111.0
                 * Math.cos((latDeg as Float) * Math.PI / 180.0);
        return Math.sqrt(dLat * dLat + dLon * dLon) > LEARN_RESET_KM;
    }

    // Sample minus the mean of the window centred on it, minus the S2 the
    // climatology already gets right. `values` runs newest-first over [lo..hi].
    function residualPa(values as Array<Float>, lo as Number, hi as Number,
                        centre as Number, solarHour as Float, s2Amp as Float) as Float {
        var sum = 0.0;
        for (var i = lo; i <= hi; i++) { sum += values[i]; }
        var mean = sum / (hi - lo + 1).toFloat();
        var s2 = s2Amp * Math.cos(2.0 * Math.PI * (solarHour - S2_PHASE_H) / 12.0);
        return (values[centre] - mean - s2).toFloat();
    }

    // Average one residual into its solar-hour bin. Returns the updated coverage
    // mask, or the mask unchanged when the residual is refused.
    function foldResidual(bins as Array<Float>, mask as Number,
                          solarHour as Float, residual as Float) as Number {
        var r = residual;
        if (r > LEARN_MAX_RESIDUAL_PA || r < 0.0 - LEARN_MAX_RESIDUAL_PA) { return mask; }
        var h = solarHour;
        while (h < 0.0) { h += 24.0; }
        while (h >= 24.0) { h -= 24.0; }
        var index = Math.round(h).toNumber() % 24;
        var bit = 1 << index;
        if ((mask & bit) == 0) {
            bins[index] = r;
        } else {
            bins[index] = (bins[index] + LEARN_ALPHA * (r - bins[index])).toFloat();
        }
        return mask | bit;
    }

    // Learned diurnal amplitude (Pa) and phase (hours LST) from the filled bins,
    // or null while the clock is too sparsely covered to fit two coefficients.
    //
    // Kept for the settled-weather gate and for diagnostics. The tide correction
    // itself no longer goes through here: collapsing 24 measured bins onto one
    // sinusoid throws away the shape that makes the measurement worth taking, and
    // at the reference station that costs 22.6 Pa RMS against 6.9 Pa for reading
    // the bins directly. Use `binTidePa` on the correction path.
    function learnedS1(bins as Array<Float>, mask as Number) as Array<Float> or Null {
        if (binsFilled(mask) < LEARN_MIN_BINS) { return null; }
        var cc = 0.0;
        var ss = 0.0;
        var cs = 0.0;
        var rc = 0.0;
        var rs = 0.0;
        for (var i = 0; i < 24; i++) {
            if ((mask & (1 << i)) == 0) { continue; }
            var w = 2.0 * Math.PI * i.toFloat() / 24.0;
            var c = Math.cos(w);
            var s = Math.sin(w);
            cc += c * c;
            ss += s * s;
            cs += c * s;
            rc += bins[i] * c;
            rs += bins[i] * s;
        }
        var det = cc * ss - cs * cs;
        if (det > -0.000000001 && det < 0.000000001) { return null; }
        var a = (rc * ss - rs * cs) / det;
        var b = (rs * cc - rc * cs) / det;
        var amp = Math.sqrt(a * a + b * b);
        if (amp > LEARN_MAX_AMP_PA) { return null; }
        var phase = Math.atan2(b, a) * 24.0 / (2.0 * Math.PI);
        if (phase < 0.0) { phase += 24.0; }
        return [amp.toFloat(), phase.toFloat()];
    }

    // The measured cycle itself, read straight out of the bins. `bins` holds the
    // residual after S2 was already removed, so S2 is added back here to give the
    // same quantity `tidePa` returns. Linear interpolation between the two nearest
    // filled bins, wrapping at midnight; null while coverage is too thin.
    function binTidePa(solarHour as Float, s2Amp as Float,
                       bins as Array<Float>, mask as Number) as Float or Null {
        if (binsFilled(mask) < LEARN_MIN_BINS) { return null; }
        var h = solarHour;
        while (h < 0.0) { h += 24.0; }
        while (h >= 24.0) { h -= 24.0; }
        var here = h.toNumber() % 24;

        var back = 0;
        while (back < 24 && (mask & (1 << ((here - back + 24) % 24))) == 0) { back += 1; }
        if (back >= 24) { return null; }
        var forward = 1;
        while (forward <= 24 && (mask & (1 << ((here + forward) % 24))) == 0) { forward += 1; }
        if (forward > 24) { return null; }

        var lo = bins[(here - back + 24) % 24];
        var hi = bins[(here + forward) % 24];
        var span = (back + forward).toFloat();
        var frac = (h - here.toFloat() + back.toFloat()) / span;
        var s2 = s2Amp * Math.cos(2.0 * Math.PI * (h - S2_PHASE_H) / 12.0);
        return (lo + frac * (hi - lo) + s2).toFloat();
    }

    // ── Calibrated rain probability ─────────────────────────────────────────
    //   Fitted offline against 73 days of a real station's rain gauge, then baked.
    //   One feature: sea-level pressure measured against the site's own recent
    //   history, in units of the site's own recent spread.
    //
    //       z = (msl_now - mean of the last 7 daily means) / spread of the last 30
    //       p = 1 / (1 + exp(-(a + b*z)))
    //
    //   The label shown is the forecast code whose tabulated probability is nearest
    //   p, so the words and the number are the same quantity and cannot contradict
    //   each other. That is what stops "Very unsettled" appearing beside 12%.
    //
    //   What this does and does not claim. It ORDERS hours well: on the reference
    //   archive it separates wet from dry with an area under the curve of 0.72,
    //   against 0.52 for the table it replaces, which is a coin flip. It does NOT
    //   beat a constant forecast of the local average, because 73 summer days
    //   cannot establish what that average is across a year. So the range below is
    //   deliberately narrow, and codes above the twenties are unreachable: a single
    //   barometer does not know enough to say "Stormy".
    //
    //   Dividing by the spread earns nothing measurable on the reference archive,
    //   where the spread barely moves. It is here so a slope fitted in summer still
    //   means something in winter, when the same anomaly in pascals is ordinary.
    const CAL_HORIZON_H = 24;
    const CAL_INTERCEPT = -1.36169;
    const CAL_SLOPE_Z = -0.51457;
    const CAL_E = 2.718281828459045;
    // Bounds the amplification when a month is unusually quiet, so a trivial
    // wiggle in settled weather cannot be divided up into a dramatic anomaly.
    const CAL_SD_FLOOR_PA = 150.0;
    // Past this the barometer is doing something the record never showed, and
    // extrapolating the fit is guesswork.
    const CAL_Z_LIMIT = 4.0;
    const CAL_SPREAD_DAYS = 30;
    const CAL_ANOMALY_DAYS = 7;
    // Fewer closed days than this and the spread is noise, not a scale.
    const CAL_MIN_DAYS = 14;
    // What a day must show before its mean is allowed into the ring. The watch
    // samples every few hours, not hourly, so a count alone is the wrong test:
    // what matters is that the samples straddle enough of the day for the ~180 Pa
    // daily cycle to average out instead of tilting the mean toward whenever the
    // watch happened to be awake.
    const CAL_MIN_SAMPLES_PER_DAY = 4;
    const CAL_MIN_SPAN_SEC = 43200;

    // Spread of the trailing daily means, floored. Null while the ring is short.
    function dailySpreadPa(days as Array<Float>) as Float or Null {
        var n = days.size();
        if (n < CAL_MIN_DAYS) { return null; }
        var from = (n > CAL_SPREAD_DAYS) ? n - CAL_SPREAD_DAYS : 0;
        var count = (n - from).toFloat();
        var sum = 0.0;
        for (var i = from; i < n; i++) { sum += days[i]; }
        var mean = sum / count;
        var acc = 0.0;
        for (var j = from; j < n; j++) {
            var d = days[j] - mean;
            acc += d * d;
        }
        var sd = Math.sqrt(acc / (count - 1.0));
        return (sd > CAL_SD_FLOOR_PA) ? sd.toFloat() : CAL_SD_FLOOR_PA;
    }

    // `days` holds the mean sea-level pressure of each CLOSED day, oldest first.
    // Today is excluded on purpose: subtracting today's own weather from itself
    // would flatten the very anomaly being measured.
    function standardisedAnomaly(mslNowPa as Float, days as Array<Float>) as Float or Null {
        var sd = dailySpreadPa(days);
        if (sd == null) { return null; }
        var n = days.size();
        var from = (n > CAL_ANOMALY_DAYS) ? n - CAL_ANOMALY_DAYS : 0;
        var sum = 0.0;
        for (var i = from; i < n; i++) { sum += days[i]; }
        var z = (mslNowPa - sum / (n - from).toFloat()) / (sd as Float);
        if (z > CAL_Z_LIMIT) { z = CAL_Z_LIMIT; }
        if (z < 0.0 - CAL_Z_LIMIT) { z = 0.0 - CAL_Z_LIMIT; }
        return z.toFloat();
    }

    function calibratedProbability(z as Float) as Float {
        var e = CAL_INTERCEPT + CAL_SLOPE_Z * z;
        return (1.0 / (1.0 + Math.pow(CAL_E, -e))).toFloat();
    }

    // Forecast code whose tabulated probability is nearest `p`. Ties go to the
    // lower code: of two equally distant descriptions, the calmer one is the
    // safer thing to put in front of someone.
    function codeForProbability(p as Float) as Number {
        var best = 0;
        var bestGap = 2.0;
        for (var c = 0; c < precipProb.size(); c++) {
            var gap = precipProb[c].toFloat() / 100.0 - p;
            if (gap < 0.0) { gap = 0.0 - gap; }
            if (gap < bestGap - 0.0000001) {
                bestGap = gap;
                best = c;
            }
        }
        return best;
    }

    // Returns [forecastText, forecastNumber, precipProbability], or null while the
    // daily ring is still filling, in which case the caller falls back to the
    // wind-aware table below.
    function CalibratedForecast(mslNowPa as Float or Null,
                                days as Array<Float> or Null) as Array or Null {
        if (mslNowPa == null || days == null) { return null; }
        var z = standardisedAnomaly(mslNowPa as Float, days as Array<Float>);
        if (z == null) { return null; }
        var p = calibratedProbability(z as Float);
        var code = codeForProbability(p);
        return [forecast(code), code, Math.round(p * 100.0).toNumber()];
    }

    // ── Classify MSL pressure into Low(0) / Normal(1) / High(2) ──────────
    //    Thresholds shift ±5 hPa seasonally following mid-latitude SLP variation.
    //    NH winter (Jan): mean SLP ~1020 → thresholds shift UP (+5)
    //    NH summer (Jul): mean SLP ~1013 → thresholds shift DOWN (-5)
    //    Works correctly at any altitude when fed MSL-equivalent pressure.
    function pressureLevel(hpa as Number or Null, month as Lang.Float or Lang.Number, hemisphere as Number) as Number {
        // No sea-level reduction was possible, so there is no level to read. Raw
        // station pressure at altitude looks Low on any fixed scale and would
        // otherwise apply a permanent pessimism of two forecast codes.
        if (hpa == null) { return 1; }
        // Outside the record MSL range this cannot be a real sea-level pressure,
        // so stay neutral instead of biasing.
        if (hpa < 870 || hpa > 1085) { return 1; }
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
        // month is 1-based with 1.0 = Jan 1, so the extremum is anchored at 1.5 = mid-Jan.
        var c = Math.cos(2.0 * Math.PI * (month.toFloat() - 1.5) / 12.0);
        if (hemisphere != 1) { c = -c; }
        return c;
    }

    // ── Main forecast entry ────────────────────────────────────────────────
    // Returns: [forecastText, forecastNumber, precipProbability]
    //
    // forecastNumber severity bands for icon selection:
    //   0-1  → clear/fine    2-6  → fair/variable
    //   7-21 → rain/snow     22-25 → storm
    function WeatherForecast(pressureHpa as Float or Number or Null, month as Lang.Float or Lang.Number, windDeg as Lang.Float or Null, trend as Number, hemisphere as Number, steadyHours as Number) as Array {

        // ── Sager table lookup: wind octant × barometric trend ─────────────
        // Accumulated on a float so seasonal corrections can ramp continuously;
        // rounded to a discrete forecast code once all modifiers are applied.
        // Without a bearing there is no octant to look up, so the wind-averaged
        // row is used rather than pretending the wind is calm.
        var baseF;
        var haveWind = (windDeg != null);
        if (!haveWind) {
            baseF = unknownBase[(trend >= 0 && trend <= 2) ? trend : 0].toFloat();
        } else {
            var octant = octantFromBearing(windDeg as Float);
            if (hemisphere != 1) {
                octant = mirrorWind(octant);
            }
            baseF = ((trend == 1) ? risingBase[octant]
                  : (trend == 2) ? fallingBase[octant]
                  : steadyBase[octant]).toFloat();
        }

        // ── Pressure-level modifier ────────────────────────────────────────
        // Shifts forecast toward better (high MSL) or worse (low MSL).
        // Altitude-safe: uses fixed MSL thresholds, not user-configurable range.
        var pLevel = pressureLevel((pressureHpa == null) ? null : pressureHpa.toNumber(), month, hemisphere);
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
        // The gate keeps a genuinely poor outlook from being promoted. Without a
        // bearing there is no poor outlook to protect against: the base is the
        // octant average, the neutral no-information answer, and holding it out
        // made this branch unreachable for the watch face, which then read
        // "rather unsettled" through a fortnight of steady high pressure.
        var settledGate = haveWind ? 6 : unknownBase[0];
        if (trend == 0 && pLevel >= 1 && base <= settledGate && steadyHours >= 6) {
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

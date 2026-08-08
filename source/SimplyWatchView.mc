import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.SensorHistory;
import Toybox.Math;
import Toybox.Application.Storage;
import Toybox.Application.Properties;

import Sager;

const cTime = 0.0 - ((Gregorian.SECONDS_PER_HOUR * 6) + (Gregorian.SECONDS_PER_MINUTE * 10));
const cSteady = 17.0; // Pa/h dead-zone (0.17 hPa/h = 1.0 hPa/6h, Sager/WMO "slowly" boundary)
const MINS_5 = (Gregorian.SECONDS_PER_MINUTE * 5);
// Elevation on this watch is barometric whenever the altimeter is not GPS-calibrated,
// so feeding it back into the MSL reduction can cancel a real pressure fall. Gate on
// 10-minute anchors: 50 m/h is ~6 hPa/h, above even severe cyclogenesis (42 m/h) and
// far below hiking (200-800 m/h). Anchoring keeps the test at ~10 sigma of sensor
// noise; gating raw 2-minute samples sits at 2 sigma and random-walks ~1 hPa.
const ALT_SLEW_M_PER_H = 50.0;
const ALT_ANCHOR_SEC = 600;
// A short window is only read when the data actually covers this much of it.
// Extrapolating a thin window and then subtracting a full window of tide invents
// a front out of nothing: 20 min blown up to 3 h clears the threshold on tide alone.
const SHORT_WINDOW_MIN_COVERAGE = 0.8;
// Forecast line: smallest system font, with clearance from the icon and the bezel.
const FORECAST_FONT = Graphics.FONT_SYSTEM_XTINY;
const FORECAST_ICON_GAP = 6;
const FORECAST_EDGE_MARGIN = 16;
// Persistence is measured from the pressure record itself, not from a run counter.
const STEADY_LOOKBACK_SEC = 30 * 3600;
const STEADY_STEP_SEC = 1800;
const STEADY_BAND_PA = 150.0;

class SimplyWatchView extends WatchUi.WatchFace {
    var mTime as Float = cTime;
    var mSteadyLimit as Float = cSteady;
    var mNorthSouth as Number = 1; // Northern hemisphere
    var mDefHemi as Number = 1; // Default hemisphere is Northern

    var trend = 0;
    var currentPress as Number or Null = null;

    var mLastForecast = null;

    var height;
    var width;

    var mBatteryPct = 100;
    var StepsIcon;
    var DistanceIcon;
    var notificationIcon;
    var weatherClearDayIcon;
    var weatherClearNightIcon;
    var weatherCloudyDayIcon;
    var weatherCloudyNightIcon;
    var weatherRainyIcon;
    var weatherSnowyIcon;
    var weatherSnowStormIcon;
    var weatherThunderStormIcon;

    var mDayNames as Array<String> = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
    var mMonthNames as Array<String> = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

    var _lastTriggerDay  = -1;
    var _lastTriggerHour = -1;
    var _forceRun = false;

    var mCenterX = 0;
    var mTimeY = 0;
    var mDateY = 0;
    var mWeatherIconX = 0;
    var mForecastTextX = 0;
    var mNotificationIconX = 0;

    var mDateCacheKey = -1;
    var mDateCacheText = "";
    var mDateCacheWidth = 0;

    var mTimeCacheKey = -1;
    var mTimeCacheText = "00:00";

    var mMinuteCacheKey = -1;
    var mNotificationCount = 0;
    var mStepsRaw = -1;
    var mDistanceRaw = -1;
    var mStepsText = "0";
    var mDistanceText = "0";

    var mBatteryBucketKey = -1;
    var mBatteryDaysText = "--d";

    var mForecastRef = null;
    var mForecastLabel = "";
    var mForecastNumber = 0;
    var mForecastChance = 0;
    var mForecastDisplayText = "";
    var mForecastIconKey = -1;
    var mForecastIcon = null;

    // The line actually drawn, after fitting it to the gap left by the icon.
    var mForecastFitText as String = "";
    var mForecastFitSource as String = "";
    var mForecastFitHalf as Number = -1;

    var mLatDeg as Float or Null = null;
    var mLonDeg as Float or Null = null;

    function getPressureIterator() as SensorHistory.SensorHistoryIterator or Null {
        // Check device for SensorHistory compatibility
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getPressureHistory)) {
            return SensorHistory.getPressureHistory({:order => SensorHistory.ORDER_NEWEST_FIRST});
        }

        return null;
    }

    // Position is held in members because isDaylight runs on every draw; reading
    // Storage once a minute for something that changes hourly is wasted power.
    hidden function getLatitude() as Float or Null {
        return mLatDeg;
    }

    // Offset from civil clock time to local solar time (hours). The semidiurnal
    // atmospheric tide is phased to solar time, so reading the wrist clock directly
    // costs up to ±1.5 h of phase error inside a timezone, DST included.
    hidden function getSolarShiftHours() as Float {
        if (mLonDeg == null) { return 0.0; }
        var shift = ((mLonDeg as Float) / 15.0) - (System.getClockTime().timeZoneOffset / 3600.0);
        // No timezone sits this far from solar time, so the cached longitude must be
        // stale after travel. A 6 h error would invert the 12 h tide, so use none.
        if (shift > 3.0 || shift < -3.0) { return 0.0; }
        return shift;
    }

    // How long pressure has actually held within a narrow band, read from the sensor
    // record so it means the same thing regardless of how often either app ran.
    // Uses station pressure: a climb blows the band open and reports 0, which is the
    // safe direction.
    hidden function measureSteadyHours(nowSec as Number) as Number {
        if (!((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getPressureHistory))) {
            return 0;
        }
        var it = SensorHistory.getPressureHistory({
            :period => new Time.Duration(STEADY_LOOKBACK_SEC),
            :order => SensorHistory.ORDER_NEWEST_FIRST
        });
        if (it == null) { return 0; }

        var refPa = null;
        var acceptBefore = null;
        var steadySec = 0;
        var guard = 0;
        var s = it.next();
        while (s != null && guard < 400) {
            guard += 1;
            var d = s.data;
            if (d != null) {
                var swhen = s.when.value();
                if (acceptBefore == null || swhen <= (acceptBefore as Number)) {
                    acceptBefore = swhen - STEADY_STEP_SEC;
                    var pa = d as Float;
                    if (refPa == null) { refPa = pa; }
                    var dev = pa - (refPa as Float);
                    if (dev < 0) { dev = -dev; }
                    if (dev > STEADY_BAND_PA) { break; }
                    steadySec = nowSec - swhen;
                }
            }
            s = it.next();
        }

        var hours = steadySec / 3600;
        return (hours > 24) ? 24 : hours;
    }

    hidden function getSeaLevelPressure(stationPa as Float) as Number or Null {
        // Try OS-provided MSL pressure (requires prior GPS fix)
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo has :meanSeaLevelPressure) {
            var mslPa = activityInfo.meanSeaLevelPressure;
            if (mslPa != null) {
                return Math.round((mslPa as Float) / 100.0).toNumber();
            }
        }

        // Fallback: elevation history + barometric formula
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getElevationHistory)) {
            var elevIter = SensorHistory.getElevationHistory({:period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST});
            if (elevIter != null) {
                var sample = elevIter.next();
                if (sample != null && sample.data != null) {
                    var stationHpa = stationPa / 100.0;
                    return Math.round(stationHpa / mslFactor(sample.data as Float)).toNumber();
                }
            }
        }

        // No altitude is known, so the reading cannot be reduced. Returning the raw
        // station value would read as a deep low at any altitude (945 hPa at 600 m)
        // and apply a permanent two-code pessimism, so report that there is no level.
        return null;
    }

    // Barometric reduction factor for a given altitude (m): P_msl = P_station / factor.
    // Altitude is clamped to a physically sane band so a glitched elevation sample
    // (sensor encoding errors surface as wild values) can't drive the base term to
    // zero/negative, where Math.pow would return NaN and poison the whole series.
    hidden function mslFactor(altitudeM as Float) as Float {
        var a = altitudeM;
        if (a > 9000.0) { a = 9000.0; }
        else if (a < -500.0) { a = -500.0; }
        return Math.pow(1.0 - (0.0065 * a / 288.15), 5.255);
    }

    // Load elevation history into parallel [whenSec[], altM[]] anchors, newest-first,
    // decimated to ALT_ANCHOR_SEC and rebuilt from the present backwards through a
    // slew-rate gate, so only movement too fast to be weather counts as real altitude.
    // Returns null when no elevation history is available (callers then use raw
    // station pressure, i.e. behave exactly as before — safe at constant altitude).
    hidden function loadElevationSeries() as Array or Null {
        if (!((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getElevationHistory))) {
            return null;
        }
        var it = SensorHistory.getElevationHistory({:order => SensorHistory.ORDER_NEWEST_FIRST});
        if (it == null) { return null; }
        var whenArr = new Array<Number>[0];
        var altArr = new Array<Float>[0];
        var s = it.next();
        var guard = 0;
        var acceptBefore = null;
        var prevRaw = null;
        var prevWhen = 0;
        var gated = 0.0;
        while (s != null && guard < 600) {
            guard += 1;
            if (s.data != null) {
                var swhen = s.when.value();
                if (acceptBefore == null || swhen <= (acceptBefore as Number)) {
                    acceptBefore = swhen - ALT_ANCHOR_SEC;
                    var raw = s.data as Float;
                    if (prevRaw == null) {
                        gated = raw;
                    } else {
                        var dtH = (prevWhen - swhen) / 3600.0;
                        var dAlt = raw - (prevRaw as Float);
                        var mag = (dAlt < 0) ? -dAlt : dAlt;
                        if (dtH > 0.0 && mag > ALT_SLEW_M_PER_H * dtH) {
                            gated += dAlt;
                        }
                    }
                    prevRaw = raw;
                    prevWhen = swhen;
                    whenArr.add(swhen);
                    altArr.add(gated);
                }
            }
            s = it.next();
        }
        if (whenArr.size() == 0) { return null; }
        return [whenArr, altArr];
    }

    // Gated altitude at a timestamp, linearly interpolated between anchors. Holding
    // the nearest anchor instead would misplace a 400 m/h ascent by up to 33 m (4 hPa).
    hidden function altAtAnchor(ez as Array<Number>, ea as Array<Float>, idx as Number, whenSec as Number) as Float {
        var altM = ea[idx];
        if (idx > 0 && ez[idx - 1] > whenSec) {
            var span = (ez[idx - 1] - ez[idx]).toFloat();
            if (span > 0.0) {
                altM = altM + (ea[idx - 1] - altM) * ((whenSec - ez[idx]).toFloat() / span);
            }
        }
        return altM;
    }

    // Atmospheric tide at a local solar hour (Pa). Shared with the glance so the two
    // apps cannot disagree on the correction; see the Sager module.
    hidden function tidePa(solarHour as Float, s2Amp as Float, s1 as Array<Float>) as Float {
        return Sager.tidePa(solarHour, s2Amp, s1[0], s1[1]);
    }

    // Tide-corrected pressure change over the last `hours`, from a short-window linear
    // fit. Returns null when the window is too thin, has no time spread, or when the
    // data does not actually reach back far enough to be worth extrapolating.
    hidden function shortWindowDiff(n as Number, sx as Float, sy as Float, sxy as Float,
                                    sx2 as Float, spanH as Float, hours as Float,
                                    hourNow as Float, s2Amp as Float, s1 as Array<Float>) as Float or Null {
        if (n < 3) { return null; }
        if (spanH < hours * SHORT_WINDOW_MIN_COVERAGE) { return null; }
        var nf = n.toFloat();
        var denom = nf * sx2 - sx * sx;
        if (denom <= 0.001) { return null; }
        var slopeAge = (nf * sxy - sx * sy) / denom;
        return (-hours * slopeAge) - (tidePa(hourNow, s2Amp, s1) - tidePa(hourNow - hours, s2Amp, s1));
    }

    // Reduce a single station-pressure sample to MSL using the most-recent
    // elevation at or before its timestamp (zero-order hold). Returns the raw
    // value unchanged when no elevation series is available.
    hidden function mslReduce(stationPa as Float, whenSec as Number, elevWhen as Array<Number> or Null, elevAlt as Array<Float> or Null) as Float {
        if (elevWhen == null || elevAlt == null) { return stationPa; }
        var ez = elevWhen as Array<Number>;
        var ea = elevAlt as Array<Float>;
        if (ez.size() == 0) { return stationPa; }
        var idx = 0;
        while (idx < ez.size() - 1 && ez[idx] > whenSec) { idx += 1; }
        return stationPa / mslFactor(altAtAnchor(ez, ea, idx, whenSec));
    }

    hidden function formatFloat(distance as Float, width as Number) as String {
        if (width == 3) {
            return distance < 10 ? distance.format("%.1f") : distance.format("%d");
        } else {
            return distance < 100 ? distance.format("%.1f") : distance.format("%d");
        }
    }

    hidden function formatTwoDigits(value as Number) as String {
        return (value < 10) ? ("0" + value.toString()) : value.toString();
    }

    hidden function getDayKey(today) as Number {
        return ((today.year * 100 + today.month) * 100) + today.day;
    }

    hidden function getMinuteKey(today) as Number {
        return ((today.day * 24 + today.hour) * 60) + today.min;
    }

    hidden function getBatteryBucketKey(today) as Number {
        return ((today.day * 24 + today.hour) * 2) + (today.min >= 30 ? 1 : 0);
    }

    hidden function refreshDateCache(today, dc as Dc) as Void {
        var dayKey = getDayKey(today);
        if (dayKey == mDateCacheKey) {
            return;
        }

        mDateCacheKey = dayKey;

        var dayName = (mDayNames as Array<String>)[today.day_of_week - 1];
        var monthName = (mMonthNames as Array<String>)[today.month - 1];
        mDateCacheText = dayName + ", " + today.day + " " + monthName + " " + today.year;
        mDateCacheWidth = dc.getTextWidthInPixels(mDateCacheText, Graphics.FONT_TINY);
    }

    hidden function refreshTimeCache(today) as Void {
        var minuteKey = getMinuteKey(today);
        if (minuteKey == mTimeCacheKey) {
            return;
        }

        mTimeCacheKey = minuteKey;

        var hourText;
        if (System.getDeviceSettings().is24Hour) {
            hourText = formatTwoDigits(today.hour);
        } else {
            var h = today.hour % 12;
            hourText = ((h == 0) ? 12 : h).toString();
        }
        mTimeCacheText = hourText + ":" + formatTwoDigits(today.min);
    }

    hidden function refreshDynamicData(today) as Void {
        var deviceSettings = System.getDeviceSettings();
        mNotificationCount = (deviceSettings != null && deviceSettings has :notificationCount && deviceSettings.notificationCount != null) ? deviceSettings.notificationCount : 0;

        var minuteKey = getMinuteKey(today);
        if (minuteKey != mMinuteCacheKey) {
            mMinuteCacheKey = minuteKey;

            var activity = ActivityMonitor.getInfo();
            if (activity != null) {
                if (activity.steps != mStepsRaw) {
                    mStepsRaw = activity.steps;
                    mStepsText = formatFloat(activity.steps / 1000.0, 3);
                }
                if (activity.distance != mDistanceRaw) {
                    mDistanceRaw = activity.distance;
                    mDistanceText = formatFloat(activity.distance / 100000.0, 3);
                }
            }
        }

        var batteryBucketKey = getBatteryBucketKey(today);
        if (batteryBucketKey != mBatteryBucketKey) {
            mBatteryBucketKey = batteryBucketKey;

            var stats = System.getSystemStats();
            if (stats != null) {
                if (stats has :batteryInDays && stats.batteryInDays != null) {
                    // +1 matches the watch's own estimator; truncating alone reads
                    // a day short of what Garmin shows.
                    mBatteryDaysText = (stats.batteryInDays + 1).toNumber().toString() + "d";
                }
                mBatteryPct = stats.battery.toNumber();
            }
        }
    }

    hidden function refreshForecastVisualCache(today, forceRefresh as Boolean) as Void {
        // Draw nothing rather than guessing until the first forecast exists.
        if (mLastForecast == null) {
            mForecastIcon = null;
            mForecastDisplayText = "";
            mForecastIconKey = -1;
            return;
        }

        if (forceRefresh || mLastForecast != mForecastRef) {
            mForecastRef = mLastForecast;
            mForecastLabel = "";
            mForecastNumber = 0;
            mForecastChance = 0;

            var forecast = (mLastForecast != null) ? (mLastForecast as Array) : null;
            if (forecast != null) {
                if (forecast.size() > 0 && forecast[0] != null) {
                    mForecastLabel = forecast[0].toString();
                }
                if (forecast.size() > 1 && forecast[1] != null) {
                    mForecastNumber = forecast[1].toNumber();
                }
                if (forecast.size() > 2 && forecast[2] != null) {
                    mForecastChance = forecast[2].toNumber();
                }
            }

            if (mForecastChance != 0) {
                mForecastDisplayText = mForecastLabel + " (" + mForecastChance.toString() + "%)";
            } else {
                mForecastDisplayText = mForecastLabel;
            }

            mForecastIconKey = -1;
        }

        var isDaytime = isDaylight(today);
        var winter = (mNorthSouth == 1)
                                        ? (today.month == 12 || today.month <= 2)   // Northern hemisphere: Dec–Feb
                                        : (today.month >= 6 && today.month <= 8);   // Southern hemisphere: Jun–Aug

        var iconBand = 2;
        if (mForecastNumber <= 1) {
            iconBand = 0;
        } else if (mForecastNumber <= 6) {
            iconBand = 1;
        } else if (mForecastNumber <= 21) {
            iconBand = 2;
        } else {
            iconBand = 3;
        }

        var iconKey = (((iconBand * 2) + (isDaytime ? 1 : 0)) * 2) + (winter ? 1 : 0);
        if (iconKey == mForecastIconKey) {
            return;
        }

        mForecastIconKey = iconKey;

        if (iconBand == 0) {
            mForecastIcon = isDaytime ? weatherClearDayIcon : weatherClearNightIcon;
        } else if (iconBand == 1) {
            mForecastIcon = isDaytime ? weatherCloudyDayIcon : weatherCloudyNightIcon;
        } else if (iconBand == 2) {
            mForecastIcon = winter ? weatherSnowyIcon : weatherRainyIcon;
        } else {
            mForecastIcon = winter ? weatherSnowStormIcon : weatherThunderStormIcon;
        }
    }

    hidden function dayOfYear(today) as Number {
        var cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
        return cumulative[today.month - 1] + today.day;
    }

    // Half-width available to the centred forecast line: the icon bounds it on the
    // left, the screen edge on the right. Read from the icon rather than assumed,
    // because the drawables are SVGs and the SDK decides their rendered size.
    hidden function forecastMaxHalfWidth() as Number {
        var iconRight = mWeatherIconX;
        if (mForecastIcon != null) {
            iconRight += mForecastIcon.getWidth();
        }
        var left = mForecastTextX - (iconRight + FORECAST_ICON_GAP);
        var right = (width - FORECAST_EDGE_MARGIN) - mForecastTextX;
        return (left < right) ? left : right;
    }

    // The glance shrinks the font to fit; this face is already on the smallest one,
    // so the string has to give instead. The percentage goes first because the
    // forecast word is what carries the meaning.
    hidden function updateForecastFit(dc as Dc) as Void {
        var maxHalf = forecastMaxHalfWidth();
        if (maxHalf == mForecastFitHalf && mForecastDisplayText.equals(mForecastFitSource)) {
            return;
        }
        mForecastFitSource = mForecastDisplayText;
        mForecastFitHalf = maxHalf;

        if (dc.getTextDimensions(mForecastDisplayText, FORECAST_FONT)[0] / 2 <= maxHalf) {
            mForecastFitText = mForecastDisplayText;
            return;
        }
        if (dc.getTextDimensions(mForecastLabel, FORECAST_FONT)[0] / 2 <= maxHalf) {
            mForecastFitText = mForecastLabel;
            return;
        }
        var s = mForecastLabel;
        while (s.length() > 1
               && dc.getTextDimensions(s + "...", FORECAST_FONT)[0] / 2 > maxHalf) {
            s = s.substring(0, s.length() - 1);
        }
        mForecastFitText = s + "...";
    }

    // Sun above the horizon, from the cached position. A fixed 07:00-19:00 is wrong
    // by up to 2.5 h here in December and never gets a polar day right.
    hidden function isDaylight(today) as Boolean {
        var lat = getLatitude();
        if (lat == null) { return (today.hour >= 7 && today.hour < 19); }
        var decl = -23.44 * Math.PI / 180.0
                 * Math.cos(2.0 * Math.PI * (dayOfYear(today) + 10).toFloat() / 365.0);
        var solarHour = today.hour.toFloat() + today.min.toFloat() / 60.0 + getSolarShiftHours();
        var hourAngle = (solarHour - 12.0) * 15.0 * Math.PI / 180.0;
        var latRad = (lat as Float) * Math.PI / 180.0;
        var sinElev = Math.sin(latRad) * Math.sin(decl)
                    + Math.cos(latRad) * Math.cos(decl) * Math.cos(hourAngle);
        // Sunrise is defined at -0.833 deg, not at geometric zero: refraction lifts
        // the disc by ~0.57 deg and its own radius accounts for the rest.
        return sinElev > -0.01454;
    }

    function initialize() {
        WatchFace.initialize();
        getSettings();
    }

    // Mirrors the glance's settings so both apps run the same window and dead-zone.
    function getSettings() as Void {
        var temp;

        try {
            temp = Properties.getValue("Steady");
        }
        catch (ex) {
            temp = null;
        }
        // Sager's own dead zone is 0.17 hPa/h. Outside roughly a decade around it the
        // face either never leaves "steady" or never enters it, so clamp rather than
        // trust a typo in the settings.
        if (temp == null) {
            mSteadyLimit = cSteady;
        } else {
            mSteadyLimit = (temp as Numeric).toFloat() * 100.0;
            if (mSteadyLimit < 5.0) { mSteadyLimit = 5.0; }
            else if (mSteadyLimit > 100.0) { mSteadyLimit = 100.0; }
        }

        try {
            temp = Properties.getValue("Time");
        }
        catch (ex) {
            temp = null;
        }
        if (temp == null) {
            mTime = cTime;
        } else {
            try {
                temp = (temp as Numeric).toFloat();
            }
            catch (ex) {
                temp = null;
            }
            mTime = (temp == null) ? cTime : (temp * -Gregorian.SECONDS_PER_HOUR - 10 * Gregorian.SECONDS_PER_MINUTE);
        }
        // Under an hour there is not enough record to fit a parabola to, and the tide
        // correction starts to dominate what is left.
        var minWindow = 0.0 - Gregorian.SECONDS_PER_HOUR.toFloat();
        if (mTime > minWindow) { mTime = minWindow; }

        // Default is 1 North, 0 South
        try {
            temp = Properties.getValue("DefaultHemisphere");
        }
        catch (ex) {
            temp = 1;
        }
        temp = ((temp instanceof Number) ? temp : 1);
        mDefHemi = temp > 0 ? 1 : 0;

        // Window and dead-zone may have moved, so the cached hourly result is stale.
        _lastTriggerHour = -1;
        _forceRun = true;
    }

    function onLayout(dc as Dc) as Void {
        height = dc.getHeight();
        width = dc.getWidth();
        mCenterX = width / 2;
        mTimeY = (height / 2) - 80;
        mDateY = (height / 2) + 23;
        mWeatherIconX = mCenterX - 95;
        mForecastTextX = mCenterX + 15;



        StepsIcon = WatchUi.loadResource(Rez.Drawables.StepsIcon);
        DistanceIcon = WatchUi.loadResource(Rez.Drawables.DistanceIcon);

        notificationIcon = WatchUi.loadResource(Rez.Drawables.NotificationIcon);
        weatherClearDayIcon = WatchUi.loadResource(Rez.Drawables.ClearDay);
        weatherClearNightIcon = WatchUi.loadResource(Rez.Drawables.ClearNight);
        weatherCloudyDayIcon = WatchUi.loadResource(Rez.Drawables.CloudyDay);
        weatherCloudyNightIcon = WatchUi.loadResource(Rez.Drawables.CloudyNight);
        weatherRainyIcon = WatchUi.loadResource(Rez.Drawables.Rainy);
        weatherSnowyIcon = WatchUi.loadResource(Rez.Drawables.Snowy);
        weatherSnowStormIcon = WatchUi.loadResource(Rez.Drawables.SnowStorm);
        weatherThunderStormIcon = WatchUi.loadResource(Rez.Drawables.ThunderStorm);

        mNotificationIconX = mCenterX - notificationIcon.getWidth() / 2;
    }

    // Re-read latitude/longitude opportunistically. Called hourly, not just on show,
    // so hemisphere, tide amplitude and solar offset self-heal after long-haul travel
    // instead of staying pinned to wherever the watch last had a fix.
    hidden function refreshLocationContext() as Void {
        var lat = null;
        var lon = null;

        // 1. Try activity's cached location (free, no GPS fix)
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null) {
            var positionInfo = activityInfo.currentLocation;
            if (positionInfo != null) {
                var degrees = positionInfo.toDegrees();
                lat = degrees[0];
                lon = degrees[1];
            }
        }

        // 2. Try Weather observation location (synced from phone, free)
        if (lat == null && Toybox has :Weather) {
            var conditions = Toybox.Weather.getCurrentConditions();
            if (conditions != null && conditions has :observationLocationPosition
                && conditions.observationLocationPosition != null) {
                var degrees = conditions.observationLocationPosition.toDegrees();
                lat = degrees[0];
                lon = degrees[1];
            }
        }

        if (lat != null) {
            mNorthSouth = (lat >= 0) ? 1 : 0;
            mLatDeg = (lat as Double).toFloat();
            mLonDeg = (lon as Double).toFloat();
            Storage.setValue("hemisphere", mNorthSouth);
            Storage.setValue("latDeg", mLatDeg);
            Storage.setValue("lonDeg", mLonDeg);
        } else {
            // No fix this hour, so fall back to whatever the last one left behind.
            if (mLatDeg == null) {
                var storedLat = Storage.getValue("latDeg");
                mLatDeg = (storedLat != null) ? (storedLat as Float) : null;
            }
            if (mLonDeg == null) {
                var storedLon = Storage.getValue("lonDeg");
                mLonDeg = (storedLon != null) ? (storedLon as Float) : null;
            }
            var stored = Storage.getValue("hemisphere");
            if (stored != null && stored has :toNumber) {
                var hemi = stored.toNumber();
                if (hemi == 0 || hemi == 1) {
                    mNorthSouth = hemi;
                } else {
                    mNorthSouth = mDefHemi;
                }
            } else {
                mNorthSouth = mDefHemi;
            }
        }
    }

    function onShow() as Void {
        refreshLocationContext();

        _forceRun = true;

        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var nowMoment = Time.now();
        var today = Gregorian.info(nowMoment, Time.FORMAT_SHORT);
        var forecastChanged = false;

        // Recompute once per clock hour; onShow() forces an immediate run.
        // Gating on min == 0 as well would silently skip the hour whenever the
        // face is not drawn on that exact minute.
        if (_forceRun || _lastTriggerDay != today.day || _lastTriggerHour != today.hour) {
            _lastTriggerDay  = today.day;
            _lastTriggerHour = today.hour;
            _forceRun = false;

            refreshLocationContext();

            var latestNonNull = null;
            // Quadratic regression accumulators (single-pass least-squares)
            // Fits y = a·x² + b·x + c over ALL samples.
            // x = age in hours, y = pressure - reference (Pa, normalized)
            var regN = 0;
            var regRef = 0.0;
            var regSx = 0.0;
            var regSx2 = 0.0;
            var regSx3 = 0.0;
            var regSx4 = 0.0;
            var regSy = 0.0;
            var regSxy = 0.0;
            var regSx2y = 0.0;
            // Independent short-window linear-fit accumulators for front detection.
            // The span each one actually covers is tracked so a thin window is not
            // extrapolated to its full length.
            var short3N = 0;
            var short3Sx = 0.0;
            var short3Sy = 0.0;
            var short3Sxy = 0.0;
            var short3Sx2 = 0.0;
            var short3Span = 0.0;
            var short15N = 0;
            var short15Sx = 0.0;
            var short15Sy = 0.0;
            var short15Sxy = 0.0;
            var short15Sx2 = 0.0;
            var short15Span = 0.0;
            var regSpan = 0.0;
            var t0sec = nowMoment.value();
            var pressureIter = getPressureIterator();
            var oldest = null;

            // Reduce every sample to mean-sea-level before regression so altitude
            // changes (hike, cable car, bike, elevator) cancel and only genuine
            // weather drives the trend. Elevation arrays are newest-first, matching
            // the pressure iterator, so a single forward index pairs them in one pass.
            var elevSeries = loadElevationSeries();
            var elevWhen = (elevSeries != null) ? ((elevSeries as Array)[0] as Array<Number>) : null;
            var elevAlt = (elevSeries != null) ? ((elevSeries as Array)[1] as Array<Float>) : null;
            var ei = 0;
            var newestMsl = null;
            var oldestMsl = null;

            if (pressureIter != null) {
                var start = nowMoment.add(new Time.Duration(mTime.toNumber()));
                oldest = pressureIter.getOldestSampleTime();
                if (oldest == null || (start as Time.Moment).greaterThan(oldest as Time.Moment)) {
                    oldest = start;
                }

                // Decimate to one sample per 5 minutes, matching the glance, so both
                // apps fit the same series and agree on the trend and on the pressure
                // range that drives the persistence modifier.
                var acceptBefore = null;
                var sample = pressureIter.next();
                while (sample != null) {
                    var s = sample as SensorHistory.SensorSample;
                    var swhen = s.when.value();
                    var data = s.data;

                    if (data != null && (acceptBefore == null || swhen <= (acceptBefore as Number))) {
                        acceptBefore = swhen - MINS_5;

                        if (latestNonNull == null) {
                            latestNonNull = data;
                        }

                        var pa = data as Float;
                        if (elevWhen != null && elevAlt != null) {
                            var ez = elevWhen as Array<Number>;
                            var ea = elevAlt as Array<Float>;
                            while (ei < ez.size() - 1 && ez[ei] > swhen) { ei += 1; }
                            pa = pa / mslFactor(altAtAnchor(ez, ea, ei, swhen));
                        }
                        if (newestMsl == null) { newestMsl = pa; }
                        oldestMsl = pa;

                        // Accumulate for quadratic regression (MSL)
                        var ageH = (t0sec - swhen) / 3600.0;
                        if (ageH > regSpan) { regSpan = ageH; }
                        if (regN == 0) { regRef = pa; }
                        var yNorm = pa - regRef;
                        var xSq = ageH * ageH;
                        regN += 1;
                        regSx += ageH;
                        regSx2 += xSq;
                        regSx3 += xSq * ageH;
                        regSx4 += xSq * xSq;
                        regSy += yNorm;
                        regSxy += ageH * yNorm;
                        regSx2y += xSq * yNorm;

                        // Independent short-window linear accumulators.
                        if (ageH <= 3.0) {
                            short3N += 1;
                            short3Sx += ageH;
                            short3Sy += yNorm;
                            short3Sxy += ageH * yNorm;
                            short3Sx2 += xSq;
                            if (ageH > short3Span) { short3Span = ageH; }
                            if (ageH <= 1.5) {
                                short15N += 1;
                                short15Sx += ageH;
                                short15Sy += yNorm;
                                short15Sxy += ageH * yNorm;
                                short15Sx2 += xSq;
                                if (ageH > short15Span) { short15Span = ageH; }
                            }
                        }
                    }

                    if (!s.when.greaterThan(oldest as Time.Moment)) {
                        break;
                    }
                    sample = pressureIter.next();
                }
            }

            // --- Trend calculation (quadratic regression) ---
            // Single-pass parabolic fit y = a·x² + b·x + c over ALL samples.
            // b = average slope (Pa/h into the past; negative = rising)
            // a = curvature/acceleration (Pa/h²; positive = decelerating fall)
            // Replaces point-sample acceleration and 3h endpoint comparison.
            trend = 0;  // Safe default if insufficient data
            var windowHours = (-mTime) / Gregorian.SECONDS_PER_HOUR.toFloat();
            if (windowHours < 0.5) { windowHours = 0.5; }

            var pressureDiff = 0.0;
            var quadA = 0.0;
            var quadB = 0.0;
            var tideSpanH = windowHours;

            if (regN > 5) {
                var nf = regN.toFloat();
                var xMean = regSx / nf;

                // Centered moments (avoids solving full 3×3 system)
                var cx2 = regSx2 - regSx * regSx / nf;
                var cx4 = regSx4 - 4.0 * xMean * regSx3 + 6.0 * xMean * xMean * regSx2 - 3.0 * nf * xMean * xMean * xMean * xMean;
                var cxy = regSxy - regSx * regSy / nf;
                var cx2y = regSx2y - 2.0 * xMean * regSxy + xMean * xMean * regSy;

                // Linear slope (decoupled for symmetric data)
                if (cx2 > 0.001) {
                    quadB = cxy / cx2;
                }

                // Quadratic coefficient (acceleration)
                var denomQ = nf * cx4 - cx2 * cx2;
                if (denomQ > 0.001 || denomQ < -0.001) {
                    quadA = (nf * cx2y - regSy * cx2) / denomQ;
                }

                // 6h trend: y(0) - y(W) = W * [a*(2·xMean - W) - b]
                pressureDiff = windowHours * (quadA * (2.0 * xMean - windowHours) - quadB);
            } else if (newestMsl != null && oldestMsl != null) {
                pressureDiff = (newestMsl as Float) - (oldestMsl as Float);
                // The endpoint fallback spans only the data present, so the tide term
                // must span the same. A full window of tide against 20 min of data is
                // enough on its own to invent a front.
                tideSpanH = regSpan;
                if (tideSpanH < 0.000001) { tideSpanH = 0.000001; }
            }

            // Classification runs at any sample count so the endpoint fallback above
            // still yields a trend instead of silently reporting steady.
            // --- Atmospheric tide correction (S2 + S1, local solar time) ---
            var hourNow = today.hour.toFloat() + today.min.toFloat() / 60.0 + getSolarShiftHours();
            var latDeg = getLatitude();
            var tideAmp = Sager.s2Amplitude(latDeg);
            var s1 = Sager.s1Tide(latDeg);
            pressureDiff = pressureDiff - (tidePa(hourNow, tideAmp, s1) - tidePa(hourNow - tideSpanH, tideAmp, s1));

            var scaledLimit = Sager.windowLimitPa(windowHours, mSteadyLimit, windowHours);

            var nextTrend = 0;
            if (pressureDiff > scaledLimit) {
                nextTrend = 1;
            } else if ((pressureDiff + scaledLimit) < 0) {
                nextTrend = 2;
            }

            // --- Shorter windows for early onset ---
            // Fitted independently of the 6 h parabola so a poorly-conditioned long fit
            // cannot fabricate a front, and so a fast-arriving front is not diluted by
            // the quiet hours ahead of it. Verified to cut warning lag by 0.75-1.75 h.
            if (nextTrend == 0) {
                var d3 = shortWindowDiff(short3N, short3Sx, short3Sy, short3Sxy, short3Sx2,
                                         short3Span, 3.0, hourNow, tideAmp, s1);
                if (d3 != null) {
                    var lim3 = Sager.windowLimitPa(3.0, mSteadyLimit, windowHours);
                    if ((d3 as Float) > lim3) {
                        nextTrend = 1;
                    } else if ((d3 as Float) < -lim3) {
                        nextTrend = 2;
                    }
                }
            }
            if (nextTrend == 0) {
                var d15 = shortWindowDiff(short15N, short15Sx, short15Sy, short15Sxy, short15Sx2,
                                          short15Span, 1.5, hourNow, tideAmp, s1);
                if (d15 != null) {
                    var lim15 = Sager.windowLimitPa(1.5, mSteadyLimit, windowHours);
                    if ((d15 as Float) > lim15) {
                        nextTrend = 1;
                    } else if ((d15 as Float) < -lim15) {
                        nextTrend = 2;
                    }
                }
            }

            // --- Trend hysteresis: quick to alarm, slow to clear ---
            var prevTrend = Storage.getValue("pT");
            if (prevTrend != null && (prevTrend as Number) != 0 && nextTrend == 0) {
                var absDiff = pressureDiff;
                if (absDiff < 0) { absDiff = -absDiff; }
                if (absDiff > scaledLimit * 0.6) {
                    nextTrend = prevTrend as Number;
                }
            }

            // --- Front passage detection ---
            // Was falling, now steady, current slope shows recovery → rising.
            // slopeNow < 0 means pressure is currently rising.
            if (prevTrend != null && (prevTrend as Number) == 2 && nextTrend == 0 && regN > 5) {
                var xMean = regSx / regN.toFloat();
                var slopeNow = quadB - 2.0 * quadA * xMean;
                if (slopeNow < 0) {
                    nextTrend = 1;
                }
            }

            // Persist what was actually shown. Storing before the promotion above left
            // the next run seeing "steady" while the user had been shown "rising".
            Storage.setValue("pT", nextTrend);

            trend = nextTrend;

            // --- Persistence tracking (measured from the pressure record) ---
            var steadyHours = measureSteadyHours(nowMoment.value());

            // --- Current pressure (MSL, altitude-safe; null when unreducible) ---
            if (latestNonNull != null) {
                currentPress = getSeaLevelPressure(latestNonNull as Float);
                var monthF = today.month.toFloat() + (today.day.toFloat() - 1.0) / 30.4;
                // The watch face has no compass, so the wind is genuinely unknown
                // rather than calm.
                mLastForecast = Sager.WeatherForecast(currentPress, monthF, null, trend, mNorthSouth, steadyHours);
                forecastChanged = true;
            }
        }

        refreshForecastVisualCache(today, forecastChanged);


        dc.setColor(Graphics.COLOR_BLACK,Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE,Graphics.COLOR_TRANSPARENT);

        refreshDynamicData(today);
        refreshTimeCache(today);
        refreshDateCache(today, dc);


        // notifications
        if (mNotificationCount > 0) {
            dc.drawBitmap(mNotificationIconX, 3, notificationIcon);
        }


        // steps
        dc.drawBitmap(45, 28, StepsIcon);
        dc.drawText(80, 28, Graphics.FONT_XTINY, mStepsText, Graphics.TEXT_JUSTIFY_LEFT);

        dc.drawBitmap(131, 26, DistanceIcon);
        dc.drawText(167, 28, Graphics.FONT_XTINY, mDistanceText, Graphics.TEXT_JUSTIFY_LEFT);


        // time
        dc.drawText(mCenterX, mTimeY, Graphics.FONT_SYSTEM_NUMBER_THAI_HOT, mTimeCacheText, Graphics.TEXT_JUSTIFY_CENTER);


        // date
        dc.drawText(mCenterX - (mDateCacheWidth / 2), mDateY, Graphics.FONT_TINY, mDateCacheText, Graphics.TEXT_JUSTIFY_LEFT);


        // forecast
        if (mForecastIcon != null) {
            dc.drawBitmap(mWeatherIconX, 190, mForecastIcon);
        }
        updateForecastFit(dc);
        dc.drawText(mForecastTextX, 195, FORECAST_FONT, mForecastFitText, Graphics.TEXT_JUSTIFY_CENTER);


        // battery - dynamic icon
        var bx = 100;
        var by = 235;
        var bw = 26;
        var bh = 12;
        dc.drawRectangle(bx, by, bw, bh);
        dc.fillRectangle(bx + bw, by + 3, 3, 6);
        var fillW = ((bw - 4) * mBatteryPct / 100.0).toNumber();
        if (fillW > 0) {
            dc.fillRectangle(bx + 2, by + 2, fillW, bh - 4);
        }
        dc.drawText(135, 230, Graphics.FONT_XTINY, mBatteryDaysText, Graphics.TEXT_JUSTIFY_LEFT);
    }

}

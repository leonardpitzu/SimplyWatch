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

import Sager;

const cTime = 0.0 - ((Gregorian.SECONDS_PER_HOUR * 6) + (Gregorian.SECONDS_PER_MINUTE * 10));
const cSteady = 35.0; // Pa/h dead-zone (0.35 hPa/h) — tighter for barometer-only forecast

class SimplyWatchView extends WatchUi.WatchFace {
    var mTime as Float = cTime;
    var mSteadyLimit as Float = cSteady;
    var mNorthSouth as Number = 1; // Northern hemisphere
    var mDefHemi as Number = 1; // Default hemisphere is Northern

    var trend = 0;
    var currentPress = 0;

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
    var mForecastNumber = 23;
    var mForecastChance = 0;
    var mForecastDisplayText = "";
    var mForecastIconKey = -1;
    var mForecastIcon = null;

    function getPressureIterator() as SensorHistory.SensorHistoryIterator or Null {
        // Check device for SensorHistory compatibility
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getPressureHistory)) {
            return SensorHistory.getPressureHistory({:order => SensorHistory.ORDER_NEWEST_FIRST});
        }

        return null;
    }

    // Semidiurnal tide amplitude scaled by latitude: A ≈ 125 * cos²(lat) Pa.
    // Computed at load time (onShow) when GPS is active; read from Storage afterwards.
    hidden function getDiurnalAmplitude() as Float {
        var stored = Storage.getValue("dA");
        return (stored != null) ? (stored as Number).toFloat() : 60.0;
    }

    hidden function getSeaLevelPressure(stationPa as Float) as Number {
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

        // Final fallback: raw station pressure
        return Math.round(stationPa / 100.0).toNumber();
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

    // Load elevation history (newest-first) into parallel [whenSec[], altM[]] arrays
    // so each pressure sample can be reduced to MSL at its own recorded altitude.
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
        while (s != null && guard < 600) {
            if (s.data != null) {
                whenArr.add(s.when.value());
                altArr.add(s.data as Float);
            }
            s = it.next();
            guard += 1;
        }
        if (whenArr.size() == 0) { return null; }
        return [whenArr, altArr];
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
        return stationPa / mslFactor(ea[idx]);
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
        mTimeCacheText = formatTwoDigits(today.hour) + ":" + formatTwoDigits(today.min);
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
                    mBatteryDaysText = (stats.batteryInDays + 1).toNumber().toString() + "d";
                }
                mBatteryPct = stats.battery.toNumber();
            }
        }
    }

    hidden function refreshForecastVisualCache(today, forceRefresh as Boolean) as Void {
        if (forceRefresh || mLastForecast != mForecastRef) {
            mForecastRef = mLastForecast;
            mForecastLabel = "";
            mForecastNumber = 23;
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

        var isDaytime = (today.hour >= 7 && today.hour < 19);
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

    function initialize() {
        WatchFace.initialize();
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
        mForecastIcon = weatherRainyIcon;

        mNotificationIconX = mCenterX - notificationIcon.getWidth() / 2;
    }

    function onShow() as Void {
        var lat = null;

        // 1. Try activity's cached location (free, no GPS fix)
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null) {
            var positionInfo = activityInfo.currentLocation;
            if (positionInfo != null) {
                lat = positionInfo.toDegrees()[0];
            }
        }

        // 2. Try Weather observation location (synced from phone, free)
        if (lat == null && Toybox has :Weather) {
            var conditions = Toybox.Weather.getCurrentConditions();
            if (conditions != null && conditions has :observationLocationPosition
                && conditions.observationLocationPosition != null) {
                lat = conditions.observationLocationPosition.toDegrees()[0];
            }
        }

        if (lat != null) {
            mNorthSouth = (lat >= 0) ? 1 : 0;
            Storage.setValue("hemisphere", mNorthSouth);
            // Cache diurnal tide amplitude from latitude: A ≈ 125 * cos²(lat) Pa
            var latRad = (lat as Double).toFloat() * Math.PI / 180.0;
            var cosLat = Math.cos(latRad);
            Storage.setValue("dA", (125.0 * cosLat * cosLat).toNumber());
        } else {
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

        _forceRun = true;

        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var nowMoment = Time.now();
        var today = Gregorian.info(nowMoment, Time.FORMAT_SHORT);
        var forecastChanged = false;

        // Run if forced OR at the start of each hour
        if (_forceRun || today.min == 0) {
            if (_lastTriggerDay != today.day || _lastTriggerHour != today.hour) {
                _lastTriggerDay  = today.day;
                _lastTriggerHour = today.hour;
                _forceRun = false;
                
                var sampleCount = 0;
                var latestNonNull = null;
                var pressureMax = null;
                var pressureMin = null;
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
                // Independent short-window (last 3h) linear-fit accumulators for front detection.
                var short3N = 0;
                var short3Sx = 0.0;
                var short3Sy = 0.0;
                var short3Sxy = 0.0;
                var short3Sx2 = 0.0;
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

                    var sample = pressureIter.next();
                    while (sample != null) {
                        var s = sample as SensorHistory.SensorSample;
                        sampleCount += 1;
                        var data = s.data;

                        if (data != null) {
                            if (latestNonNull == null) {
                                latestNonNull = data;
                            }

                            var swhen = s.when.value();
                            var pa = data as Float;
                            if (elevWhen != null && elevAlt != null) {
                                var ez = elevWhen as Array<Number>;
                                var ea = elevAlt as Array<Float>;
                                while (ei < ez.size() - 1 && ez[ei] > swhen) { ei += 1; }
                                pa = pa / mslFactor(ea[ei]);
                            }
                            if (newestMsl == null) { newestMsl = pa; }
                            oldestMsl = pa;

                            // Track pressure range for persistence detection (MSL)
                            if (pressureMax == null || pa > (pressureMax as Float)) {
                                pressureMax = pa;
                            }
                            if (pressureMin == null || pa < (pressureMin as Float)) {
                                pressureMin = pa;
                            }

                            // Accumulate for quadratic regression (MSL)
                            var ageH = (t0sec - swhen) / 3600.0;
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

                            // Independent short-window (last 3h) linear accumulators.
                            if (ageH <= 3.0) {
                                short3N += 1;
                                short3Sx += ageH;
                                short3Sy += yNorm;
                                short3Sxy += ageH * yNorm;
                                short3Sx2 += xSq;
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
                }

                if (regN > 5) {
                    var nf = regN.toFloat();
                    var xMean = regSx / nf;

                    // --- Diurnal tide correction ---
                    var hourNow = today.hour.toFloat() + today.min.toFloat() / 60.0;
                    var hourStart = hourNow + (mTime / Gregorian.SECONDS_PER_HOUR.toFloat());
                    var phase = 2.0 * Math.PI / 12.0;
                    var tideAmp = getDiurnalAmplitude();
                    var diurnalCorr = tideAmp * (Math.cos(phase * (hourNow - 9.5)) - Math.cos(phase * (hourStart - 9.5)));
                    pressureDiff = pressureDiff - diurnalCorr;

                    var scaledLimit = mSteadyLimit * windowHours;

                    var nextTrend = 0;
                    if (pressureDiff > scaledLimit) {
                        nextTrend = 1;
                    } else if ((pressureDiff + scaledLimit) < 0) {
                        nextTrend = 2;
                    }

                    // --- 3h front detection (independent short-window linear fit) ---
                    // Fits pressure vs time over ONLY the last 3h, decoupled from the 6h
                    // parabola's conditioning, so a poorly-shaped long fit can't fabricate
                    // a short-term front. Needs >=3 recent samples with real time spread.
                    if (nextTrend == 0 && short3N >= 3) {
                        var sN = short3N.toFloat();
                        var sDenom = sN * short3Sx2 - short3Sx * short3Sx;
                        if (sDenom > 0.001) {
                            var slopeAge = (sN * short3Sxy - short3Sx * short3Sy) / sDenom;
                            var shortDiff = -3.0 * slopeAge;   // change over the last 3h (now - 3h ago)
                            var hourMid = hourNow - 3.0;
                            var shortDiurnal = tideAmp * (Math.cos(phase * (hourNow - 9.5)) - Math.cos(phase * (hourMid - 9.5)));
                            shortDiff = shortDiff - shortDiurnal;
                            var shortLimit = mSteadyLimit * 3.0;
                            if (shortDiff > shortLimit) {
                                nextTrend = 1;
                            } else if (shortDiff < -shortLimit) {
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
                    Storage.setValue("pT", nextTrend);

                    // --- Front passage detection ---
                    // Was falling, now steady, current slope shows recovery → rising.
                    // slopeNow < 0 means pressure is currently rising.
                    if (prevTrend != null && (prevTrend as Number) == 2 && nextTrend == 0) {
                        var slopeNow = quadB - 2.0 * quadA * xMean;
                        if (slopeNow < 0) {
                            nextTrend = 1;
                        }
                    }

                    trend = nextTrend;
                }

                // --- Persistence tracking (Storage-backed, survives reboots) ---
                // Timestamp-guarded: max 1 increment per hour, survives instance recreation.
                var steadyHours = 0;
                if (pressureMax != null && pressureMin != null) {
                    var pressureRange = (pressureMax as Float) - (pressureMin as Float);
                    if (pressureRange < 200.0) {
                        var stored = Storage.getValue("sH");
                        var lastTs = Storage.getValue("sT");
                        var nowSec = nowMoment.value();
                        if (lastTs != null && (nowSec - (lastTs as Number)) < 3600) {
                            // Less than 1h since last increment — just re-read
                            steadyHours = (stored != null) ? (stored as Number) : 0;
                        } else {
                            // ≥1h elapsed or first run — increment
                            steadyHours = (stored != null) ? (stored as Number) + 1 : 1;
                            Storage.setValue("sT", nowSec);
                        }
                    }
                }
                Storage.setValue("sH", steadyHours);

                // --- Current pressure (MSL, altitude-safe) ---
                if (latestNonNull != null) {
                    currentPress = getSeaLevelPressure(latestNonNull as Float);
                    var monthF = today.month.toFloat() + (today.day.toFloat() - 1.0) / 30.4;
                    mLastForecast = Sager.WeatherForecast(currentPress, monthF, 0, trend, mNorthSouth, steadyHours);
                    forecastChanged = true;
                }
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
        dc.drawText(mForecastTextX, 195, Graphics.FONT_SYSTEM_XTINY, mForecastDisplayText, Graphics.TEXT_JUSTIFY_CENTER);


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

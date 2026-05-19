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
const MINS_5 = (Gregorian.SECONDS_PER_MINUTE * 5);

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

    var batteryBitmap;
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
                    var altitude = (sample.data as Float);
                    var stationHpa = stationPa / 100.0;
                    var factor = Math.pow(1.0 - (0.0065 * altitude / 288.15), 5.255);
                    return Math.round(stationHpa / factor).toNumber();
                }
            }
        }

        // Final fallback: raw station pressure
        return Math.round(stationPa / 100.0).toNumber();
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
            if (stats != null && stats has :batteryInDays && stats.batteryInDays != null) {
                mBatteryDaysText = (stats.batteryInDays + 1).toNumber().toString() + "d";
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

        batteryBitmap = WatchUi.loadResource(Rez.Drawables.BatteryIcon);

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
                var firstA = null;
                var firstB = null;
                var firstC = null;
                var lastA = null;
                var lastB = null;
                var lastC = null;
                var latestNonNull = null;
                var oldestNonNull = null;
                // Hourly snapshots for acceleration (sample 1 ≈ now, ~12 ≈ -1h, ~24 ≈ -2h)
                var accelP0 = null;
                var accelP1 = null;
                var accelP2 = null;
                var accelBest1 = 7;  // half-interval tolerance in sample count
                var accelBest2 = 7;
                var pressureIter = getPressureIterator();
                var oldest = null;

                if (pressureIter != null) {
                    var start = nowMoment.add(new Time.Duration(mTime.toNumber()));
                    oldest = pressureIter.getOldestSampleTime();
                    if (oldest == null || (start as Time.Moment).greaterThan(oldest as Time.Moment)) {
                        oldest = start;
                    }

                    var firstSample = pressureIter.next();
                    if (firstSample != null) {
                        var sample = firstSample as SensorHistory.SensorSample;
                        var minus5Mins = new Time.Duration(-MINS_5);

                        while (true) {
                            sampleCount += 1;
                            var data = sample.data;

                            if (data != null) {
                                if (latestNonNull == null) {
                                    latestNonNull = data;
                                }
                                oldestNonNull = data;

                                // Capture hourly snapshots for acceleration calc
                                // Samples are ~5 min apart: index 12 ≈ -1h, 24 ≈ -2h
                                if (sampleCount == 1) {
                                    accelP0 = data;
                                }
                                var d1 = sampleCount - 12;
                                if (d1 < 0) { d1 = -d1; }
                                if (d1 < accelBest1) { accelBest1 = d1; accelP1 = data; }
                                var d2 = sampleCount - 24;
                                if (d2 < 0) { d2 = -d2; }
                                if (d2 < accelBest2) { accelBest2 = d2; accelP2 = data; }
                            }

                            if (sampleCount == 1) {
                                firstA = data;
                                lastA = data;
                            } else if (sampleCount == 2) {
                                firstB = data;
                                lastB = data;
                            } else if (sampleCount == 3) {
                                firstC = data;
                                lastC = data;
                            } else {
                                lastA = lastB;
                                lastB = lastC;
                                lastC = data;
                            }

                            if (!sample.when.greaterThan(oldest)) {
                                break;
                            }

                            var sampleNextTime = sample.when.add(minus5Mins);
                            var nextSample = pressureIter.next();
                            if (nextSample == null) {
                                break;
                            }

                            var selected = nextSample as SensorHistory.SensorSample;

                            while (selected.when.greaterThan(sampleNextTime) && selected.when.greaterThan(oldest)) {
                                var replacement = pressureIter.next();
                                if (replacement == null) {
                                    break;
                                }
                                selected = replacement as SensorHistory.SensorSample;
                            }

                            sample = selected;
                        }
                    }
                }

                // --- Trend calculation ---
                var p1 = 0.0, p2 = 0.0, cnt = 0;

                if (sampleCount > 5) {
                    if (firstA != null && lastC != null) {
                        p1 += (firstA as Float);
                        p2 += (lastC as Float);
                        cnt += 1;
                    }
                    if (firstB != null && lastB != null) {
                        p1 += (firstB as Float);
                        p2 += (lastB as Float);
                        cnt += 1;
                    }
                    if (firstC != null && lastA != null) {
                        p1 += (firstC as Float);
                        p2 += (lastA as Float);
                        cnt += 1;
                    }
                } else {
                    if (latestNonNull != null && oldestNonNull != null) {
                        p1 = latestNonNull;
                        p2 = oldestNonNull;
                        cnt = 1;
                    }
                }

                // Calculate pressure difference
                if (cnt > 0) {
                    var pressureDiff = (p1 - p2) / cnt;

                    // Scale rate threshold (Pa/h) by window duration to get Pa total.
                    var windowHours = (-mTime) / Gregorian.SECONDS_PER_HOUR.toFloat();
                    if (windowHours < 0.5) { windowHours = 0.5; }
                    var scaledLimit = mSteadyLimit * windowHours;

                    var nextTrend = 0;
                    if (pressureDiff > scaledLimit) {
                        nextTrend = 1;
                    } else if ((pressureDiff + scaledLimit) < 0) {
                        nextTrend = 2;
                    }

                    // Acceleration-aware trend refinement
                    if (accelP0 != null && accelP1 != null && accelP2 != null) {
                        var a0 = (accelP0 as Float) / 100.0;
                        var a1 = (accelP1 as Float) / 100.0;
                        var a2 = (accelP2 as Float) / 100.0;
                        var accel = a0 - 2.0 * a1 + a2;
                        if (accel > -0.3 && accel < 0.3) { accel = 0.0; }

                        if (nextTrend == 0 && accel <= -0.4) {
                            nextTrend = 2;
                        } else if (nextTrend == 2 && accel > 0.5) {
                            nextTrend = 0;
                        } else if (nextTrend == 1 && accel <= -1.0) {
                            nextTrend = 1;
                        }
                    }

                    trend = nextTrend;
                }

                // --- Current pressure (MSL, altitude-safe) ---
                if (latestNonNull != null) {
                    currentPress = getSeaLevelPressure(latestNonNull as Float);
                    mLastForecast = Sager.WeatherForecast(currentPress, today.month as Number, 0, trend, mNorthSouth);
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


        // battery
        dc.drawBitmap(100, 225, batteryBitmap);
        dc.drawText(135, 230, Graphics.FONT_XTINY, mBatteryDaysText, Graphics.TEXT_JUSTIFY_LEFT);
    }

}

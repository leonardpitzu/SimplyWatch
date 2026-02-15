// beteljuice.com - near enough Zambretti Algorhithm 
// June 2008 - v1.0
// tweak added so decision # can be output

/*
Negretti and Zambras 'slide rule' is supposed to be better than 90% accurate 
for a local forecast upto 12 hrs, it is most accurate in the temperate zones and about 09:00  hrs local solar time.
I hope I have been able to 'tweak it' a little better ;-)    

This code is free to use and redistribute as long as NO CHARGE is EVER made for its use or output
*/

import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.Math;

module Zambretti {
    var forecastStrings0 as Array<Lang.ResourceId> = [
        Rez.Strings.SF,
        Rez.Strings.FW,
        Rez.Strings.BF,
        Rez.Strings.FN,
        Rez.Strings.FN,
        Rez.Strings.FF,
        Rez.Strings.FF,
        Rez.Strings.FF,
        Rez.Strings.SHE,
        Rez.Strings.CH,
        Rez.Strings.FF,
        Rez.Strings.RU,
        Rez.Strings.UN,
        Rez.Strings.SH,
        Rez.Strings.SH,
        Rez.Strings.CH,
        Rez.Strings.UN,
        Rez.Strings.UN,
        Rez.Strings.UN,
        Rez.Strings.VU,
        Rez.Strings.OR,
        Rez.Strings.RT,
        Rez.Strings.RA,
        Rez.Strings.RA,
        Rez.Strings.ST,
        Rez.Strings.ST
    ];

    var forecastStrings1 as Array<Lang.ResourceId> = [
        Rez.Strings.MT,
        Rez.Strings.MT,
        Rez.Strings.MT,
        Rez.Strings.LS,
        Rez.Strings.PS,
        Rez.Strings.IM,
        Rez.Strings.PSE,
        Rez.Strings.SL,
        Rez.Strings.IM,
        Rez.Strings.ME,
        Rez.Strings.SY,
        Rez.Strings.CL,
        Rez.Strings.PI,
        Rez.Strings.BI,
        Rez.Strings.LS,
        Rez.Strings.SR,
        Rez.Strings.SI,
        Rez.Strings.RL,
        Rez.Strings.SR,
        Rez.Strings.MO,
        Rez.Strings.WO,
        Rez.Strings.VU,
        Rez.Strings.FI,
        Rez.Strings.VU,
        Rez.Strings.MI,
        Rez.Strings.MR
    ] as Array<Lang.ResourceId>;

    // equivalents of Zambretti 'dial window' letters A - Z
    var rise_options as Array<Number> = [25,25,25,24,24,19,16,12,11,9,8,6,5,2,1,1,0,0,0,0,0,0];
    var steady_options as Array<Number> = [25,25,25,25,25,25,23,23,22,18,15,13,10,4,1,1,0,0,0,0,0,0]; 
    var fall_options as Array<Number> = [25,25,25,25,25,25,25,25,23,23,21,20,17,14,7,3,1,1,1,0,0,0];

    // Cache loaded localized strings to avoid repeated resource lookups.
    var forecastCache0 as Array<String> = [];
    var forecastCache1 as Array<String> = [];

    // Lookup tables for wind direction influence on pressure.
    var northAdjust as Array<Float> = [ 0.0, 6.0, 5.0, 5.0, 2.0, -0.5, -2.0, -5.0, -8.5, -12.0, -10.0, -6.0, -4.5, -3.0, -0.5, 1.5, 3.0 ];
    var southAdjust as Array<Float> = [ 0.0, -12.0, -10.0, -6.0, -4.5, -3.0, -0.5, 1.5, 3.0, 6.0, 5.0, 5.0, 2.0, -0.5, -2.0, -5.0, -8.5 ];

    // Symbolic rain profile pairs by forecast number (0..25, 0 is fallback).
    var forecastPairs as Array<Array<Number>> = [
        [0,0], // 0 (fallback)
        [0,0], [1,1], [2,1], [1,2], [1,1], [1,0], [2,1], [1,4], [4,2], [4,4],
        [1,1], [3,1], [3,3], [2,2], [4,5], [4,4], [2,2], [2,4], [2,2], [5,5],
        [2,4], [4,4], [4,4], [6,4], [6,6]
    ];

    function forecast0(f as Number) as String {
        var idx = f.toNumber();
        if (idx < 0 || idx >= forecastStrings0.size()) {
            return "";
        }

        if (forecastCache0.size() == 0) {
            for (var i = 0; i < forecastStrings0.size(); i++) {
                forecastCache0.add(WatchUi.loadResource((forecastStrings0 as Array<Lang.ResourceId>)[i]) as String);
            }
        }

        return (forecastCache0 as Array<String>)[idx];
    }

    function forecast1(f as Number) as String {
        var idx = f.toNumber();
        if (idx < 0 || idx >= forecastStrings1.size()) {
            return "";
        }

        if (forecastCache1.size() == 0) {
            for (var i = 0; i < forecastStrings1.size(); i++) {
                forecastCache1.add(WatchUi.loadResource((forecastStrings1 as Array<Lang.ResourceId>)[i]) as String);
            }
        }

        return (forecastCache1 as Array<String>)[idx];
    }

    function WeatherForecast(z_hpa as Float or Number, z_month as Number, z_wind_dir as Number, z_trend as Number, z_where as Number, z_baro_top as Float or Number, z_baro_bottom as Float or Number) as Array {
        var baroRange = (z_baro_top - z_baro_bottom).toFloat();
        if (baroRange <= 0.0) {
            baroRange = 1.0;
        }

        var z_frac = baroRange / 100.0;
        var z_constant = z_frac * 4.5454545454;
        var z_season = (z_month >= 4 && z_month <= 9); // true if 'Summer'
        var isNorth = (z_where == 1);

        try {
            var windAdj = isNorth ? northAdjust : southAdjust;

            if (z_wind_dir >= 1 && z_wind_dir <= 16) {
                z_hpa += windAdj[z_wind_dir] * z_frac;
            }

            // Seasonal trend effect
            if ((isNorth && z_season) or (!isNorth && !z_season)) {
                if (z_trend == 1) { z_hpa += 7 * z_frac; } // Rising
                else if (z_trend == 2) { z_hpa -= 7 * z_frac; } // Falling
            }
        }
        catch (ex) {
            z_hpa = 0.0;
        }

        z_hpa = z_hpa.toNumber();
        if(z_hpa == z_baro_top) { z_hpa = z_baro_top - 1; }

        var z_except = false;
        var z_option = Math.floor((z_hpa - z_baro_bottom) / z_constant).toNumber();
        var z_output0 = "";
        var z_output1 = "";

        if (z_option < 0 or z_option > 21) {
            z_option = (z_option < 0) ? 0 : 21;
            z_except = true;
            z_output0 = "*";
            z_output1 = "*";
        }

        var forecast = 0;
        if (z_trend == 1) { forecast = rise_options[z_option]; } // rising
        else if (z_trend == 2) { forecast = fall_options[z_option]; } // falling
        else { forecast = steady_options[z_option]; } // must be 'steady'

        z_output0 += forecast0(forecast);
        z_output1 += forecast1(forecast);

        if (z_except) {
            z_output0 += "*";
            if (z_output1.equals("*")) { z_output1 = ""; }
            else { z_output1 += "*"; }
        }


        var rain = 0;

        // Get symbolic pair or default.
        var pair = [0, 0];
        if (forecast >= 1 && forecast <= 25) {
            pair = forecastPairs[forecast];
        }
        var f0 = (pair as Array<Number>)[0];
        var f1 = (pair as Array<Number>)[1];
        var pairCode = (f0 * 10 + f1).toNumber();

        // Return mapped or fallback rain probability.
        if (pairCode == 0 || pairCode == 10) { rain = 0; }
        else if (pairCode == 21) { rain = 10; }
        else if (pairCode == 11) { rain = 30; }
        else if (pairCode == 12) { rain = 60; }
        else if (pairCode == 22) { rain = 50; }
        else if (pairCode == 23 || pairCode == 24 || pairCode == 25) { rain = 70; }
        else if (pairCode == 31 || pairCode == 44 || pairCode == 55 || pairCode == 66) { rain = 90; }
        else { rain = (f0 >= 2 && f1 < 2) ? 10 : 90; }

        return [z_output0, z_output1, forecast, rain];
    }

}

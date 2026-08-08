import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class SimplyWatchApp extends Application.AppBase {
    hidden var watchView as SimplyWatchView or Null;

    function initialize() {
        AppBase.initialize();
    }

    // Return the initial view of your application here
    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new SimplyWatchView();
        watchView = view;
        return [ view ];
    }

    // New app settings have been received so trigger a UI update
    function onSettingsChanged() as Void {
        if (watchView != null) {
            watchView.getSettings();
        }

        WatchUi.requestUpdate();
    }

}

function getApp() as SimplyWatchApp {
    return Application.getApp() as SimplyWatchApp;
}
package com.zkv.sensmos

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Skróty z widgetu przychodzą jako sensmos://open?kind=… . Dart pyta o adres przy starcie
    // (getInitial) i dostaje kolejne przez „link" — apka bywa już żywa (launchMode singleTop),
    // wtedy onCreate się nie powtórzy i bez onNewIntent stuknięcie w widget nic by nie robiło.
    private val CHANNEL = "sensmos/deeplink"
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pending = linkOf(intent)
        // Kanał IMPORTANCE_HIGH: bez niego FCM ląduje w kanale domyślnym (DEFAULT), a Android
        // pokazuje wtedy tylko dźwięk + ikonę w pasku — BEZ pływającego banera (heads-up).
        // BE wskazuje channelId "alerts" w payloadzie; manifest ma go jako default.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                "alerts", "Alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Node emergency and alerts"
                enableVibration(true)
            }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "getInitial") {
                    result.success(pending)
                    pending = null      // jednorazowo: przy powrocie z tła nie odtwarzamy starego skrótu
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sensmos/device").setMethodCallHandler { call, result ->
            if (call.method == "isEmulator") result.success(isEmulator()) else result.notImplemented()
        }
    }

    // Emulator pozwala wpisać dowolną pozycję GPS — ceremonia lokalizacji nie może jej przyjąć.
    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") || Build.FINGERPRINT.startsWith("unknown") ||
        Build.FINGERPRINT.contains("emulator") || Build.FINGERPRINT.contains("sdk_gphone") ||
        Build.MODEL.contains("Emulator") || Build.MODEL.contains("Android SDK built for") ||
        Build.HARDWARE.contains("goldfish") || Build.HARDWARE.contains("ranchu") ||
        Build.PRODUCT.startsWith("sdk") || Build.PRODUCT.contains("emulator") ||
        Build.MANUFACTURER.contains("Genymotion")

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkOf(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("link", link) else pending = link
    }

    /**
     * Skrót z widgetu przychodzi jako extra przy intencie launchera (patrz SensmosWidgetProvider),
     * a zwykły deep link jako data. Obie drogi sprowadzamy do jednego adresu dla Darta.
     */
    private fun linkOf(intent: Intent?): String? {
        val kind = intent?.getStringExtra(WidgetLink.EXTRA_KIND)
        if (kind != null) {
            intent.removeExtra(WidgetLink.EXTRA_KIND)   // bez tego powrót z tła powtarzałby skrót
            return "sensmos://open?kind=$kind"
        }
        return intent?.data?.toString()
    }
}

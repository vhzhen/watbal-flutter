package com.example.watbal

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/// Android home-screen widget, mirroring the iOS `WatBalWidget`. Reads the same
/// keys the Flutter side writes through `home_widget` (`balance_text`,
/// `app_theme`, `transactions_json`, `last_updated`) and renders the balance
/// plus a scrollable list of recent transactions. The class name must stay
/// `WatBalWidgetReceiver` — the Dart `updateWidget(name: ...)` call resolves it
/// as `<applicationId>.WatBalWidgetReceiver`.
class WatBalWidgetReceiver : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val theme = WidgetTheme.named(widgetData.getString("app_theme", "light"))
        val balance = widgetData.getString("balance_text", "\$--.--") ?: "\$--.--"
        val label = widgetData.getString("balance_label", null) ?: "WatBal"
        val updated = formatUpdated(widgetData.getString("last_updated", null))

        // Tag: WatBalWidget — `adb logcat -s WatBalWidget` shows each render so
        // you can confirm the broadcast actually re-ran onUpdate and what time
        // it painted.
        Log.d(
            "WatBalWidget",
            "onUpdate ids=${appWidgetIds.toList()} balance=$balance \"$updated\"",
        )

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.watbal_widget)

            views.setInt(R.id.widget_root, "setBackgroundResource", theme.backgroundRes)
            views.setTextViewText(R.id.widget_title, label)
            views.setTextColor(R.id.widget_title, theme.secondary)
            views.setTextViewText(R.id.widget_updated, updated)
            views.setTextColor(R.id.widget_updated, theme.secondary)
            views.setTextViewText(R.id.widget_balance, balance)
            views.setTextColor(R.id.widget_balance, theme.primary)
            views.setTextColor(R.id.widget_empty, theme.secondary)

            // Scrollable transactions list, fed by TransactionsWidgetService. A
            // per-widget unique Uri forces the adapter to rebuild on each update.
            val serviceIntent = Intent(context, TransactionsWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            views.setRemoteAdapter(R.id.widget_list, serviceIntent)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)

            // Tapping anywhere opens the app.
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                views.setOnClickPendingIntent(
                    R.id.widget_root,
                    PendingIntent.getActivity(context, 0, launch, flags),
                )
            }

            // Background-safe text update. This widget has a collection (the
            // transaction ListView), so a full updateAppWidget makes the
            // launcher bind TransactionsWidgetService — which Android blocks
            // from a background broadcast, so the whole push (balance + time
            // included) gets dropped and the widget freezes. A partial update
            // touches only the text views (no adapter, no service bind), so the
            // balance and "Updated …" time land reliably even in the background.
            // The simple 1x1/2x2 tiles don't hit this because they have no list.
            val textOnly = RemoteViews(context.packageName, R.layout.watbal_widget).apply {
                setInt(R.id.widget_root, "setBackgroundResource", theme.backgroundRes)
                setTextViewText(R.id.widget_title, label)
                setTextColor(R.id.widget_title, theme.secondary)
                setTextViewText(R.id.widget_updated, updated)
                setTextColor(R.id.widget_updated, theme.secondary)
                setTextViewText(R.id.widget_balance, balance)
                setTextColor(R.id.widget_balance, theme.primary)
            }
            appWidgetManager.partiallyUpdateAppWidget(id, textOnly)

            // Full update refreshes the list too; lands in the foreground (and
            // whenever the service can bind), and is harmless when it can't.
            appWidgetManager.updateAppWidget(id, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
        }
    }

    /// "Updated 3:45 PM" today, "Updated Jun 14" otherwise — matches iOS.
    private fun formatUpdated(raw: String?): String {
        val ms = raw?.toDoubleOrNull() ?: return ""
        val date = Date(ms.toLong())
        val now = Calendar.getInstance()
        val then = Calendar.getInstance().apply { time = date }
        val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) &&
            now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
        val fmt = SimpleDateFormat(if (sameDay) "h:mm a" else "MMM d", Locale.getDefault())
        return "Updated ${fmt.format(date)}"
    }
}

/// Theme palette that mirrors the Flutter app's Material 3 "vibrant" scheme so
/// the widget matches the in-app balance hero in every theme (including dark).
/// The card background is `primaryContainer` (a rounded drawable per theme so
/// corners survive); [primary]/[text] are `onPrimaryContainer`, [secondary] is
/// the same at 70% alpha, and [debit]/[credit] are accents chosen to stay
/// legible on each card. Values come straight from
/// `ColorScheme.fromSeed(seed, brightness, vibrant)` — see [AppTheme] in
/// main.dart; keep the two in sync if the app themes change.
data class WidgetTheme(
    val backgroundRes: Int,
    val primary: Int,
    val text: Int,
    val secondary: Int,
    val debit: Int,
    val credit: Int,
) {
    companion object {
        fun named(name: String?): WidgetTheme = when (name) {
            "dark" -> WidgetTheme(
                R.drawable.watbal_widget_bg_dark,
                Color.parseColor("#D1E4FF"), // onPrimaryContainer
                Color.parseColor("#D1E4FF"),
                Color.parseColor("#B3D1E4FF"), // 70% alpha
                Color.parseColor("#FFB4AB"), // error (light, for the dark card)
                Color.parseColor("#7CDB8A"),
            )
            "green" -> WidgetTheme(
                R.drawable.watbal_widget_bg_green,
                Color.parseColor("#005313"), // onPrimaryContainer
                Color.parseColor("#005313"),
                Color.parseColor("#B3005313"),
                Color.parseColor("#8C1414"),
                Color.parseColor("#1B5E20"),
            )
            "purple" -> WidgetTheme(
                R.drawable.watbal_widget_bg_purple,
                Color.parseColor("#5B00C5"), // onPrimaryContainer
                Color.parseColor("#5B00C5"),
                Color.parseColor("#B35B00C5"),
                Color.parseColor("#BA1A1A"), // error
                Color.parseColor("#1B6B2E"),
            )
            else -> WidgetTheme(
                R.drawable.watbal_widget_bg_light,
                Color.parseColor("#00497D"), // onPrimaryContainer
                Color.parseColor("#00497D"),
                Color.parseColor("#B300497D"),
                Color.parseColor("#BA1A1A"), // error
                Color.parseColor("#1B6B2E"),
            )
        }
    }
}

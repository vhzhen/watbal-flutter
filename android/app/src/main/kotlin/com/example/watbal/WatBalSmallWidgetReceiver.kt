package com.example.watbal

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/// Compact 1x1 home-screen widget: just the "WatBal" title, the balance, and
/// the "Updated …" time — no transaction list. Reads the same shared keys the
/// Flutter side writes (`balance_text`, `last_updated`, `app_theme`) and reuses
/// [WidgetTheme] from WatBalWidgetReceiver. The Dart `updateWidget` call
/// resolves this as `<applicationId>.WatBalSmallWidgetReceiver`.
class WatBalSmallWidgetReceiver : HomeWidgetProvider() {

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

        Log.d(
            "WatBalWidget",
            "small onUpdate ids=${appWidgetIds.toList()} balance=$balance \"$updated\"",
        )

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.watbal_widget_small)

            views.setInt(R.id.widget_root, "setBackgroundResource", theme.backgroundRes)
            views.setTextViewText(R.id.widget_title, label)
            views.setTextColor(R.id.widget_title, theme.secondary)
            views.setTextViewText(R.id.widget_balance, balance)
            views.setTextColor(R.id.widget_balance, theme.primary)
            views.setTextViewText(R.id.widget_updated, updated)
            views.setTextColor(R.id.widget_updated, theme.secondary)

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

            appWidgetManager.updateAppWidget(id, views)
        }
    }

    /// "Updated 3:45 PM" today, "Updated Jun 14" otherwise — matches the full
    /// widget.
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

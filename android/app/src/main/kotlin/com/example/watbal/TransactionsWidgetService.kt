package com.example.watbal

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/// Feeds the widget's transaction ListView. Reads `transactions_json` (written
/// by the Flutter scraper) on every data-change and renders one row per txn,
/// colouring debits red and credits green like the iOS `TxnRow`.
class TransactionsWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        TransactionsFactory(applicationContext)
}

private class TransactionsFactory(
    private val context: Context,
) : RemoteViewsService.RemoteViewsFactory {

    private data class Txn(
        val label: String,
        val amount: String,
        val date: String,
        val isDebit: Boolean,
    )

    private var items: List<Txn> = emptyList()
    private var theme: WidgetTheme = WidgetTheme.named("light")

    override fun onCreate() {}

    override fun onDataSetChanged() {
        val prefs = HomeWidgetPlugin.getData(context)
        theme = WidgetTheme.named(prefs.getString("app_theme", "light"))
        val raw = prefs.getString("transactions_json", "[]") ?: "[]"
        val parsed = mutableListOf<Txn>()
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                parsed.add(
                    Txn(
                        label = o.optString("label"),
                        amount = o.optString("amount"),
                        date = o.optString("date"),
                        isDebit = o.optBoolean("isDebit"),
                    ),
                )
            }
        } catch (_: Exception) {
            // Malformed / empty — show nothing rather than crash the host.
        }
        items = parsed
    }

    override fun onDestroy() {
        items = emptyList()
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews {
        val txn = items[position]
        val accent = if (txn.isDebit) theme.debit else theme.credit
        return RemoteViews(context.packageName, R.layout.watbal_widget_row).apply {
            setTextViewText(R.id.row_arrow, if (txn.isDebit) "↓" else "↑")
            setTextColor(R.id.row_arrow, accent)
            setTextViewText(R.id.row_label, txn.label)
            setTextColor(R.id.row_label, theme.text)
            setTextViewText(R.id.row_date, txn.date)
            setTextColor(R.id.row_date, theme.secondary)
            setTextViewText(R.id.row_amount, txn.amount)
            setTextColor(R.id.row_amount, accent)
        }
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 1
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}

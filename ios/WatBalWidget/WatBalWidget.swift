import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    // Shared storage ID - Must match your App Group exactly
    let appGroupId = "group.com.vincent.watbal"
    
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), balance: "$--.--")
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = SimpleEntry(date: Date(), balance: "$--.--")
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let prefs = UserDefaults(suiteName: appGroupId)
        let cookies = prefs?.string(forKey: "balance_text") ?? "Login Required"
        
        // Use the last known balance immediately
        let lastBalance = prefs?.string(forKey: "balance_text") ?? "No Data"
        
        // Define when to check again (every 30 minutes)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!

        // If we want the widget to fetch its OWN data, we would trigger a URLSession here.
        // For now, this timeline ensures the widget stays synced with the App Group data.
        let entry = SimpleEntry(date: Date(), balance: lastBalance)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let balance: String
}

struct WatBalWidgetEntryView : View {
    var entry: Provider.Entry

    var body: some View {
        VStack(alignment: .leading) {
            Text("WatBal")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            Spacer()
            Text(entry.balance)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Spacer()
            Text("Updated: \(entry.date, formatter: Self.timeFormatter)")
                .font(.system(size: 8))
                .foregroundColor(.gray)
        }
        .padding()
    }
    
    static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }
}

@main
struct WatBalWidget: Widget {
    let kind: String = "WatBalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            WatBalWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("WatBal Widget")
        .description("Track your balance at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

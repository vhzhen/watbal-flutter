import WidgetKit
import SwiftUI

// MARK: - Theme

struct WidgetTheme {
    let background: Color
    let primary: Color
    let text: Color
    let secondary: Color

    static func named(_ name: String?) -> WidgetTheme {
        switch name {
        case "dark":
            return WidgetTheme(
                background: Color(red: 0.11, green: 0.11, blue: 0.12),
                primary: Color(red: 0.40, green: 0.60, blue: 1.0),
                text: .white,
                secondary: Color.white.opacity(0.6)
            )
        case "green":
            return WidgetTheme(
                background: Color(red: 0.93, green: 0.97, blue: 0.93),
                primary: Color(red: 0.18, green: 0.49, blue: 0.20),
                text: Color(red: 0.10, green: 0.18, blue: 0.10),
                secondary: Color(red: 0.30, green: 0.40, blue: 0.30)
            )
        case "purple":
            // ColorScheme.fromSeed(deepPurple, light, vibrant): container
            // #EBDDFF, onContainer #5B00C5.
            return WidgetTheme(
                background: Color(red: 0.92, green: 0.87, blue: 1.0),
                primary: Color(red: 0.36, green: 0.0, blue: 0.77),
                text: Color(red: 0.36, green: 0.0, blue: 0.77),
                secondary: Color(red: 0.36, green: 0.0, blue: 0.77).opacity(0.7)
            )
        case "gold":
            // UWaterloo gold: container #FDD34C, onContainer black.
            return WidgetTheme(
                background: Color(red: 0.99, green: 0.83, blue: 0.30),
                primary: .black,
                text: .black,
                secondary: Color.black.opacity(0.7)
            )
        default: // light
            return WidgetTheme(
                background: .white,
                primary: .blue,
                text: .black,
                secondary: Color.gray
            )
        }
    }
}

// MARK: - Models

struct WidgetTxn: Decodable, Identifiable {
    var id: String { date + label + amount }
    let label: String
    let amount: String
    let date: String
    let isDebit: Bool
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let balance: String
    let themeName: String
    let txns: [WidgetTxn]
    let updated: Date?
}

// MARK: - Provider

struct Provider: TimelineProvider {
    let appGroupId = "group.com.vincent.watbal"

    private func loadEntry() -> SimpleEntry {
        let prefs = UserDefaults(suiteName: appGroupId)
        let balance = prefs?.string(forKey: "balance_text") ?? "$--.--"
        let theme = prefs?.string(forKey: "app_theme") ?? "light"

        var txns: [WidgetTxn] = []
        if let raw = prefs?.string(forKey: "transactions_json"),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([WidgetTxn].self, from: data) {
            txns = decoded
        }

        var updated: Date? = nil
        if let raw = prefs?.string(forKey: "last_updated"),
           let ms = Double(raw) {
            updated = Date(timeIntervalSince1970: ms / 1000.0)
        }

        return SimpleEntry(date: Date(), balance: balance,
                           themeName: theme, txns: txns, updated: updated)
    }

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), balance: "$--.--",
                    themeName: "light", txns: [], updated: nil)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (SimpleEntry) -> ()) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(
            byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Views

struct BalanceHeader: View {
    let entry: SimpleEntry
    let theme: WidgetTheme
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text("WatBal")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(theme.secondary)
                Spacer()
                if let u = entry.updated {
                    Text(updatedLabel(u))
                        .font(.system(size: 9))
                        .foregroundColor(theme.secondary)
                }
            }
            Text(entry.balance)
                .font(.system(size: compact ? 22 : 28,
                              weight: .heavy, design: .rounded))
                .foregroundColor(theme.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    private func updatedLabel(_ date: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "h:mm a"
        } else {
            f.dateFormat = "MMM d"
        }
        return "Updated \(f.string(from: date))"
    }
}

struct TxnRow: View {
    let txn: WidgetTxn
    let theme: WidgetTheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: txn.isDebit ? "arrow.down" : "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(txn.isDebit ? .red : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(txn.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(txn.date)
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(txn.amount)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(txn.isDebit ? .red : .green)
        }
    }
}

struct WatBalWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var body: some View {
        let theme = WidgetTheme.named(entry.themeName)

        Group {
            switch family {
            case .systemSmall:
                VStack(alignment: .leading) {
                    BalanceHeader(entry: entry, theme: theme)
                    Spacer()
                }
            default:
                let limit = family == .systemLarge ? 7 : 3
                VStack(alignment: .leading, spacing: 8) {
                    BalanceHeader(entry: entry, theme: theme, compact: true)
                    Divider()
                    if entry.txns.isEmpty {
                        Spacer()
                        Text("Open the app to load recent transactions")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondary)
                        Spacer()
                    } else {
                        ForEach(entry.txns.prefix(limit)) { txn in
                            TxnRow(txn: txn, theme: theme)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .widgetBackground(theme.background)
    }
}

// iOS 17 requires containerBackground; fall back for earlier versions.
extension View {
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(color, for: .widget)
        } else {
            self.background(color)
        }
    }
}

// MARK: - Widget

@main
struct WatBalWidget: Widget {
    let kind: String = "WatBalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            WatBalWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("WatBal Widget")
        .description("Track your balance and recent transactions.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

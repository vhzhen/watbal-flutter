import BackgroundTasks
import Foundation
import WidgetKit

/// Native iOS background-refresh path for the home-screen widget.
///
/// The Dart `workmanager` plugin schedules a `BGProcessingTaskRequest`, which
/// iOS treats as discretionary — it often won't fire for hours unless the
/// device is charging/idle. To keep the widget reasonably fresh during normal
/// use, we register a *second* task here as a `BGAppRefreshTaskRequest`. iOS
/// fires these much more aggressively (typically every 15 min–few hours,
/// based on how often the user opens the app).
///
/// The handler does the same Dashboard → KeepAlive → Balances sequence as the
/// Dart [ScraperService.fetchBalance], parses out the FLEXIBLE row balance
/// with a regex, writes it + `last_updated` to the shared app-group
/// UserDefaults, reloads the widget timeline, then reschedules itself.
///
/// We deliberately avoid spinning up a Flutter engine here — keeping the
/// Swift path entirely self-contained makes it cheap enough that iOS is more
/// likely to grant the task time.
enum BalanceRefresher {
    static let taskIdentifier = "com.vincent.watbal.refresh.app"
    static let appGroupId = "group.com.vincent.watbal"
    static let baseUrl = "https://secure.touchnet.net/C22566_oneweb"
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// Called once from AppDelegate.didFinishLaunching. Registers the task
    /// handler with the system before app launch completes — required by
    /// BGTaskScheduler.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task: task as! BGAppRefreshTask)
        }
    }

    /// Submit the next BGAppRefreshTaskRequest. Idempotent — call from
    /// app launch and after each successful handler run. iOS only honours
    /// `earliestBeginDate` as a hint; actual firing is governed by usage
    /// heuristics.
    static func schedule(after seconds: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("[BalanceRefresher] schedule failed: \(error)")
        }
    }

    // MARK: - Handler

    private static func handle(task: BGAppRefreshTask) {
        // Always queue the next run *before* doing work, so we keep our slot
        // in the scheduler even if this run is killed by the expiration timer.
        schedule()

        let work = DispatchWorkItem {
            refreshBalance { ok in
                task.setTaskCompleted(success: ok)
            }
        }

        task.expirationHandler = {
            // iOS is taking the time back; cancel and report partial success.
            work.cancel()
            task.setTaskCompleted(success: false)
        }

        DispatchQueue.global(qos: .background).async(execute: work)
    }

    // MARK: - Scrape

    private static func refreshBalance(completion: @escaping (Bool) -> Void) {
        let prefs = UserDefaults(suiteName: appGroupId)
        guard let cookies = prefs?.string(forKey: "session_cookies"),
              !cookies.isEmpty
        else {
            // No saved session — nothing we can do headlessly. Caller schedules
            // another run; eventually the user reopens the app and re-auths.
            NSLog("[BalanceRefresher] no cookies; skipping")
            completion(false)
            return
        }

        getDashboardToken(cookies: cookies) { token in
            guard let token = token else {
                NSLog("[BalanceRefresher] no token; session likely expired")
                completion(false)
                return
            }

            // Hit KeepAlive to bump the sliding window even when the balance
            // page itself is heavy. Failure here is non-fatal.
            keepAlive(cookies: cookies, token: token) { _ in
                fetchBalanceHtml(cookies: cookies, token: token) { html in
                    guard let html = html,
                          let amount = parseFlexibleBalance(html: html)
                    else {
                        NSLog("[BalanceRefresher] couldn't parse balance")
                        completion(false)
                        return
                    }

                    prefs?.set(amount, forKey: "balance_text")
                    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
                    prefs?.set("\(nowMs)", forKey: "last_updated")

                    // Best-effort transactions refresh so the widget's list
                    // doesn't go stale between app opens. A failure here must not
                    // sink the balance push, so we always reload + report success
                    // once the balance is written, regardless of this outcome.
                    fetchTransactionsHtml(cookies: cookies, token: token) { txnHtml in
                        if let txnHtml = txnHtml {
                            let txns = parseTransactions(html: txnHtml)
                            if let data = try? JSONSerialization.data(
                                withJSONObject: txns
                            ), let json = String(data: data, encoding: .utf8) {
                                prefs?.set(json, forKey: "transactions_json")
                            }
                        }
                        DispatchQueue.main.async {
                            WidgetCenter.shared.reloadAllTimelines()
                            NSLog("[BalanceRefresher] OK: \(amount)")
                            completion(true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - HTTP helpers

    private static func standardRequest(
        _ url: URL, cookies: String, method: String = "GET"
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(cookies, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        return req
    }

    private static func getDashboardToken(
        cookies: String,
        completion: @escaping (String?) -> Void
    ) {
        let url = URL(string: "\(baseUrl)/Account/Dashboard")!
        let req = standardRequest(url, cookies: cookies)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let html = String(data: data, encoding: .utf8)
            else {
                completion(nil); return
            }
            completion(extractVerificationToken(html: html))
        }.resume()
    }

    private static func keepAlive(
        cookies: String, token: String,
        completion: @escaping (Bool) -> Void
    ) {
        let url = URL(string: "\(baseUrl)/Layout/KeepAlive")!
        var req = standardRequest(url, cookies: cookies, method: "POST")
        req.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let body = "__RequestVerificationToken=\(urlEncode(token))"
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { $0.statusCode < 400 } ?? false
            completion(ok)
        }.resume()
    }

    private static func fetchBalanceHtml(
        cookies: String, token: String,
        completion: @escaping (String?) -> Void
    ) {
        let url = URL(string: "\(baseUrl)/Deposit/Home/Balances")!
        var req = standardRequest(url, cookies: cookies, method: "POST")
        req.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(
            "\(baseUrl)/Deposit", forHTTPHeaderField: "Referer"
        )
        let body = "__RequestVerificationToken=\(urlEncode(token))"
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let html = String(data: data, encoding: .utf8)
            else { completion(nil); return }
            completion(html)
        }.resume()
    }

    /// POSTs the transaction-history query — mirrors the Dart
    /// `Scraper.fetchTransactions`: a 5-year window capped at 1000 rows, the
    /// newest of which the widget shows.
    private static func fetchTransactionsHtml(
        cookies: String, token: String,
        completion: @escaping (String?) -> Void
    ) {
        let url = URL(string: "\(baseUrl)/TransactionHistory/TransactionsPass")!
        var req = standardRequest(url, cookies: cookies, method: "POST")
        req.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(
            "https://secure.touchnet.net", forHTTPHeaderField: "Origin"
        )
        req.setValue(
            "\(baseUrl)/TransactionHistory/Transactions",
            forHTTPHeaderField: "Referer"
        )

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MM/dd/yyyy"
        let now = Date()
        let from = Calendar.current.date(byAdding: .year, value: -5, to: now)
            ?? now

        let params = [
            "FromDate": fmt.string(from: from),
            "ToDate": fmt.string(from: now),
            "ReturnRows": "1000",
            "BalanceID": "",
            "__RequestVerificationToken": token,
        ]
        let body = params
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let html = String(data: data, encoding: .utf8)
            else { completion(nil); return }
            completion(html)
        }.resume()
    }

    // MARK: - Parsing

    /// Pulls the form-field anti-forgery token out of the Dashboard HTML.
    /// Returns nil when the token is absent — same signal the Dart scraper
    /// uses to detect "session expired".
    private static func extractVerificationToken(html: String) -> String? {
        // input ... name="__RequestVerificationToken" ... value="...."
        let pattern =
            "name=\"__RequestVerificationToken\"[^>]*value=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let m = regex.firstMatch(in: html, options: [], range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: html)
        else { return nil }
        return String(html[r])
    }

    /// Mirrors the Dart logic: find "FLEXIBLE" and the next dollar amount
    /// after it in the page. Permissive on whitespace and column ordering.
    private static func parseFlexibleBalance(html: String) -> String? {
        // Use a non-greedy match between FLEXIBLE and the next $X.XX, with
        // `.` matching newlines so the regex spans the table row markup.
        let pattern = "FLEXIBLE[\\s\\S]{0,4000}?(\\$[0-9,]+\\.[0-9]{2})"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: []
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let m = regex.firstMatch(in: html, options: [], range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: html)
        else { return nil }
        return String(html[r])
    }

    /// Parses the transaction-history table into the same shape the Dart
    /// `Scraper.refreshTransactionsWidget` writes, so both the iOS and Android
    /// widgets can decode it: `[{label, amount, date, isDebit}]`, newest first,
    /// capped at 8 rows. No HTML parser on the native side, so we narrow to the
    /// results table, split on rows, and pull each `data-title` cell by regex.
    private static func parseTransactions(html: String) -> [[String: Any]] {
        // Narrow to the results table so unrelated markup can't leak in.
        guard let anchor = html.range(of: "transaction-history-result-table")
        else { return [] }
        let table = String(html[anchor.lowerBound...])

        var result: [[String: Any]] = []
        // The chunk before the first "<tr" is the table head/setup; row chunks
        // follow. cellText returns "" for any chunk without the cell.
        // "102 : ACCOUNT ADJUSTMENT" / "00024 : TIM HORTONS" -> the part after
        // the colon.
        func afterColon(_ s: String) -> String {
            if let colon = s.firstIndex(of: ":") {
                return String(s[s.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return s.trimmingCharacters(in: .whitespaces)
        }

        for row in table.components(separatedBy: "<tr") {
            let dateTime = cellText(row, title: "Date - Time")
            let type = cellText(row, title: "Type")
            let terminal = cellText(row, title: "Terminal")
            let amount = cellText(row, title: "Amount")
            if dateTime.isEmpty && type.isEmpty && amount.isEmpty { continue }

            // Merchant (Terminal) as the row title, matching the in-app list and
            // the Dart widget data; fall back to the Type description when blank.
            let merchant = afterColon(terminal)
            let label = merchant.isEmpty ? afterColon(type) : merchant

            result.append([
                "label": label,
                // Site renders "$-0.14"; show "-$0.14" like the Dart side.
                "amount": amount.replacingOccurrences(of: "$-", with: "-$"),
                "date": dateTime,
                "isDebit": amount.contains("-"),
            ])
            if result.count >= 8 { break }
        }
        return result
    }

    /// Extracts the trimmed text of the `<td data-title="...">` cell from a
    /// single table-row chunk, stripping tags and decoding common entities.
    private static func cellText(_ row: String, title: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: title)
        let pattern = "data-title=\"\(escaped)\"[^>]*>([\\s\\S]*?)</td>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(
                in: row, range: NSRange(row.startIndex..., in: row)
              ),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: row)
        else { return "" }

        var text = String(row[r])
            .replacingOccurrences(
                of: "<[^>]+>", with: " ", options: .regularExpression
            )
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<",
            "&gt;": ">", "&quot;": "\"", "&#39;": "'",
        ]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }
        return text
            .replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

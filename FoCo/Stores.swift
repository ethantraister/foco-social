import Foundation
import Observation

@MainActor @Observable
final class MenuStore {
    static let shared = MenuStore()

    private(set) var menus: [String: [FoodItem]] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var freshWeeks: Set<String> = []

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("menus.v2.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([String: [FoodItem]].self, from: data) {
            menus = cached
        }
    }

    static func key(_ day: String, _ source: String) -> String { "\(day)|\(source)" }

    private static func weekKey(_ date: Date, _ source: String) -> String {
        "\(FoCoCalendar.dayString(FoCoCalendar.weekStart(date)))|\(source)"
    }

    func items(on date: Date, meal: Meal) -> [FoodItem]? {
        menus[Self.key(FoCoCalendar.dayString(date), meal.rawValue)]
    }

    func saladBar(on date: Date) -> [FoodItem] {
        menus[Self.key(FoCoCalendar.dayString(date), MenuSource.saladBar)] ?? []
    }

    func isLoading(_ date: Date, _ meal: Meal) -> Bool { inFlight.contains(Self.weekKey(date, meal.rawValue)) }
    func error(_ date: Date, _ meal: Meal) -> String? { errors[Self.weekKey(date, meal.rawValue)] }

    func load(date: Date, meal: Meal, force: Bool = false) async {
        async let main: Void = load(date: date, source: meal.rawValue, force: force)
        if meal.includesSaladBar {
            async let salad: Void = load(date: date, source: MenuSource.saladBar, force: force)
            _ = await (main, salad)
        } else {
            await main
        }
    }

    private func load(date: Date, source: String, force: Bool) async {
        let wk = Self.weekKey(date, source)
        if inFlight.contains(wk) || (!force && freshWeeks.contains(wk)) { return }
        inFlight.insert(wk)
        defer { inFlight.remove(wk) }
        do {
            let week = try await NutrisliceAPI.fetchWeek(source: source, date: date)
            for (day, items) in week { menus[Self.key(day, source)] = items }
            freshWeeks.insert(wk)
            errors[wk] = nil
            saveCache()
        } catch {
            errors[wk] = "Couldn't reach the FoCo menu. Check your connection and pull down to try again."
        }
    }

    /// Loads this week and next week for every meal, which covers the next 7 days.
    func loadUpcoming(force: Bool = false) async {
        let today = Date.now
        let nextWeek = FoCoCalendar.adding(days: 7, to: today)
        await withTaskGroup(of: Void.self) { group in
            for meal in Meal.allCases {
                for date in [today, nextWeek] {
                    group.addTask { await self.load(date: date, source: meal.rawValue, force: force) }
                }
            }
        }
    }

    private func upcoming(days: Int) -> [(day: String, meal: Meal, items: [FoodItem])] {
        let start = FoCoCalendar.startOfDay(.now)
        var out: [(String, Meal, [FoodItem])] = []
        for offset in 0..<days {
            let day = FoCoCalendar.dayString(FoCoCalendar.adding(days: offset, to: start))
            for meal in Meal.allCases where !(offset == 0 && meal.isOverToday) {
                if let items = menus[Self.key(day, meal.rawValue)] { out.append((day, meal, items)) }
            }
        }
        return out
    }

    func matches(for keywords: [String], days: Int = 7) -> [MenuMatch] {
        upcoming(days: days).flatMap { slot in
            keywords.compactMap { keyword in
                let hits = slot.items.filter { FoodClassifier.matches($0.name, keyword: keyword) }
                return hits.isEmpty ? nil : MenuMatch(day: slot.day, meal: slot.meal, keyword: keyword, items: hits)
            }
        }
    }

    func search(_ query: String, days: Int = 7) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return upcoming(days: days).flatMap { slot in
            slot.items
                .filter { $0.name.localizedCaseInsensitiveContains(q) || $0.station.localizedCaseInsensitiveContains(q) }
                .map { SearchHit(day: slot.day, meal: slot.meal, item: $0) }
        }
    }

    private func saveCache() {
        let cutoff = FoCoCalendar.dayString(FoCoCalendar.adding(days: -7, to: .now))
        let recent = menus.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(recent) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }
}

@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    var avoid: Set<String> { didSet { save() } }
    var require: Set<String> { didSet { save() } }
    var watches: [String] { didSet { save() } }
    /// Requests from before they went to Dining through the server. Only read once, to follow those foods.
    private var requests: [FoodRequest] { didSet { save() } }
    /// Lets you peek at the full menu without losing your diet settings.
    var filtersPaused = false

    private struct Snapshot: Codable {
        var avoid: Set<String> = []
        var require: Set<String> = []
        var watches: [String] = []
        var requests: [FoodRequest] = []
    }

    private static let defaultsKey = "preferences.v1"

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") {
            for key in [Self.defaultsKey, "onboarded", "tab", "hiddenPlans"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        #endif
        let s = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        avoid = s.avoid
        require = s.require
        watches = s.watches
        requests = s.requests
        // Requested foods used to be followed invisibly, so they couldn't be unfollowed. Move them into the visible list once.
        if !UserDefaults.standard.bool(forKey: "requestsFoldedIntoWatches") {
            for r in requests where !isWatching(r.food) { watches.append(r.food) }
            UserDefaults.standard.set(true, forKey: "requestsFoldedIntoWatches")
            save()   // didSet doesn't run inside init
        }
    }

    private func save() {
        let s = Snapshot(avoid: avoid, require: require, watches: watches, requests: requests)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    var hasFilters: Bool { !avoid.isEmpty || !require.isEmpty }
    var filtering: Bool { hasFilters && !filtersPaused }

    var filterSummary: String {
        var parts: [String] = []
        if !require.isEmpty { parts.append(Diet.allCases.filter { require.contains($0.rawValue) }.map(\.title).joined(separator: ", ")) }
        if !avoid.isEmpty { parts.append("no " + Allergen.allCases.filter { avoid.contains($0.rawValue) }.map { $0.title.lowercased() }.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Everything that should trigger an alert. Requesting a food follows it too, and it can be unfollowed like any other.
    var alertKeywords: [String] {
        var seen = Set<String>()
        return watches.filter { seen.insert($0.lowercased()).inserted }
    }

    func follow(_ name: String) {
        if !isWatching(name) { watches.append(name) }
    }

    func unfollow(_ name: String) {
        watches.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func allows(_ item: FoodItem) -> Bool {
        guard filtering else { return true }
        var tags = item.tags
        if tags.contains("vegan") { tags.insert("vegetarian") }
        return avoid.isDisjoint(with: tags) && require.isSubset(of: tags)
    }

    func isWatching(_ name: String) -> Bool {
        watches.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleWatch(_ name: String) {
        if let i = watches.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            watches.remove(at: i)
        } else {
            watches.append(name)
        }
    }
}

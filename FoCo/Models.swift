import Foundation

enum Meal: String, CaseIterable, Identifiable, Codable {
    case breakfast, lunch, dinner
    case lateNight = "late-night"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .dinner: "Dinner"
        case .lateNight: "Late Night"
        }
    }

    var symbol: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "sunset"
        case .lateNight: "moon.stars"
        }
    }

    /// The salad bar is published as its own "all-day" menu; it's shown inside lunch and dinner.
    var includesSaladBar: Bool { self == .lunch || self == .dinner }

    static var current: Meal {
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: .now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        switch minutes {
        case 90..<(11 * 60): return .breakfast
        case (11 * 60)..<(16 * 60): return .lunch
        case (16 * 60)..<(20 * 60 + 30): return .dinner
        default: return .lateNight
        }
    }

    /// Dining periods from Dartmouth Dining, in minutes after midnight; late night runs past midnight.
    private var startMinute: Int {
        switch self {
        case .breakfast: 7 * 60 + 30
        case .lunch: 11 * 60
        case .dinner: 16 * 60
        case .lateNight: 21 * 60 + 30
        }
    }

    private var endMinute: Int {
        switch self {
        case .breakfast: 11 * 60
        case .lunch: 16 * 60
        case .dinner: 20 * 60 + 30
        case .lateNight: 24 * 60 + 90
        }
    }

    /// The meal Foco is serving right now, if any, and when it ends.
    static func serving(at date: Date = .now) -> (meal: Meal, ends: Date)? {
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: date)
        var minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if minutes < 90 { minutes += 24 * 60 }
        guard let meal = allCases.first(where: { minutes >= $0.startMinute && minutes < $0.endMinute }) else { return nil }
        return (meal, date.addingTimeInterval(Double(meal.endMinute - minutes) * 60))
    }

    /// The meal Foco serves at a time, or nil when it's closed (8:30–9:30 PM and 1:30–7:30 AM).
    static func at(_ date: Date) -> Meal? { serving(at: date)?.meal }

    var isOverToday: Bool {
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: .now)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes >= 90 && minutes >= endMinute
    }

    /// When a "this food is on the menu" alert fires, relative to the day it's served.
    var alertTime: (dayOffset: Int, hour: Int) {
        switch self {
        case .breakfast: (-1, 20)
        case .lunch: (0, 9)
        case .dinner: (0, 15)
        case .lateNight: (0, 19)
        }
    }

    var alertTimeDescription: String {
        switch self {
        case .breakfast: "8 PM the night before"
        case .lunch: "9 AM"
        case .dinner: "3 PM"
        case .lateNight: "7 PM"
        }
    }
}

enum MenuSource {
    static let saladBar = "all-day"
    static func key(_ meal: Meal) -> String { meal.rawValue }
}

struct FoodItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let station: String
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let fiber: Double?
    let sugar: Double?
    let sodium: Double?
    let serving: String?
    let ingredients: String?
    let tags: Set<String>
    let isMain: Bool

    var isDessert: Bool { FoodClassifier.isDessert(name: name, station: station) }

    /// Protein alone is 4 cal/g, so protein calories can't exceed total calories.
    var nutritionLooksWrong: Bool {
        guard let c = calories, let p = protein else { return false }
        return p * 4 > c * 1.15
    }

    var proteinPer100Cal: Double? {
        guard !nutritionLooksWrong, let c = calories, let p = protein, c > 0 else { return nil }
        return p / c * 100
    }

    var macroLine: String? {
        var parts: [String] = []
        if let calories { parts.append("\(Int(calories)) cal") }
        if let protein { parts.append("\(Int(protein))g protein") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var diets: [Diet] { Diet.allCases.filter { tags.contains($0.rawValue) || ($0 == .vegetarian && tags.contains("vegan")) } }
    var allergens: [Allergen] { Allergen.allCases.filter { tags.contains($0.rawValue) } }
    var hasAllergenInfo: Bool { !tags.isEmpty }
}

enum Allergen: String, CaseIterable, Identifiable {
    case dairy, egg, soy, wheat, sesame, fish, shellfish, mustard, coconut, pork, alcohol
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Diet: String, CaseIterable, Identifiable {
    case vegan, vegetarian
    case glutenFree = "gluten-free"
    case halal, kosher
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glutenFree: "Gluten Free"
        default: rawValue.capitalized
        }
    }
    var short: String {
        switch self {
        case .vegan: "VG"
        case .vegetarian: "V"
        case .glutenFree: "GF"
        case .halal: "H"
        case .kosher: "K"
        }
    }
}

struct FoodRequest: Identifiable, Codable, Hashable {
    var id = UUID()
    var food: String
    var meal: Meal?
    var note: String
    var created = Date()
}

struct MenuMatch: Identifiable, Hashable {
    let day: String
    let meal: Meal
    let keyword: String
    let items: [FoodItem]
    var id: String { "\(day)|\(meal.rawValue)|\(keyword)" }

    var date: Date? { FoCoCalendar.date(from: day) }

    var fireDate: Date? {
        guard let date else { return nil }
        let t = meal.alertTime
        guard let shifted = FoCoCalendar.cal.date(byAdding: .day, value: t.dayOffset, to: date) else { return nil }
        return FoCoCalendar.cal.date(bySettingHour: t.hour, minute: 0, second: 0, of: shifted)
    }
}

struct SearchHit: Identifiable, Hashable {
    let day: String
    let meal: Meal
    let item: FoodItem
    var id: String { item.id }
    var date: Date { FoCoCalendar.date(from: day) ?? .now }
}

/// When Foco is open: 7:30 AM to 8:30 PM, then Late Night 9:30 PM to 1:30 AM.
enum FoCoHours {
    static func isOpen(at date: Date) -> Bool { Meal.at(date) != nil }

    /// "Foco is closed at 9:00 PM" / "Late Night starts at 9:30 PM.", for the popup when you pick a closed time.
    static func closedTitle(at date: Date) -> String {
        "Foco is closed at \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: FoCoCalendar.tz)))"
    }

    static func closedMessage(at date: Date) -> String {
        let c = FoCoCalendar.cal.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if minutes >= 20 * 60 + 30 && minutes < 21 * 60 + 30 {
            return "Dinner ends at 8:30 PM and Late Night starts at 9:30 PM. Pick a time when Foco is open."
        }
        return "Foco is closed overnight, after Late Night ends at 1:30 AM. It opens at 7:30 AM."
    }
}

enum FoCoCalendar {
    static let tz = TimeZone(identifier: "America/New_York")!

    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        c.firstWeekday = 1
        return c
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func date(from s: String) -> Date? { dayFormatter.date(from: s) }
    static func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }
    static func weekStart(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d }
    static func adding(days: Int, to d: Date) -> Date { cal.date(byAdding: .day, value: days, to: d) ?? d }

    /// "today", "tomorrow", or "on Thursday" — for use mid-sentence.
    static func phrase(_ d: Date) -> String {
        let r = relativeName(d)
        return r == "Today" || r == "Tomorrow" ? r.lowercased() : "on \(r)"
    }

    static func relativeName(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.wide))
    }
}

import Foundation

enum NutrisliceAPI {
    private struct Week: Decodable { let days: [Day] }
    private struct Day: Decodable { let date: String; let menuItems: [Item] }
    private struct Item: Decodable {
        let id: Int
        let isStationHeader: Bool
        let isSectionTitle: Bool
        let text: String
        let food: Food?
    }
    private struct Food: Decodable {
        let name: String
        let ingredients: String?
        let roundedNutritionInfo: [String: Double?]?
        let servingSizeInfo: Serving?
        let icons: Icons
    }
    private struct Serving: Decodable { let servingSizeAmount: String?; let servingSizeUnit: String? }
    private struct Icons: Decodable { let foodIcons: [Icon] }
    private struct Icon: Decodable { let slug: String }

    static func url(source: String, date: Date) -> URL {
        let c = FoCoCalendar.cal.dateComponents([.year, .month, .day], from: date)
        let path = String(format: "%04d/%02d/%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
        return URL(string: "https://dartmouthcollege.api.nutrislice.com/menu/api/weeks/school/1953-commons/menu-type/\(source)/\(path)/")!
    }

    /// Returns every day in the week containing `date`, keyed by "yyyy-MM-dd".
    static func fetchWeek(source: String, date: Date) async throws -> [String: [FoodItem]] {
        var request = URLRequest(url: url(source: source, date: date))
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let week = try decoder.decode(Week.self, from: data)

        var result: [String: [FoodItem]] = [:]
        for day in week.days {
            var station = "Foco"
            var items: [FoodItem] = []
            for item in day.menuItems {
                if item.isStationHeader || item.isSectionTitle {
                    let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { station = title }
                    continue
                }
                guard let food = item.food else { continue }
                items.append(makeItem(id: "\(day.date)-\(source)-\(item.id)", food: food, station: station))
            }
            result[day.date] = items
        }
        return result
    }

    private static func makeItem(id: String, food: Food, station: String) -> FoodItem {
        let n = food.roundedNutritionInfo ?? [:]
        // Dining reports 0 when a value is missing, so 0 calories means "unknown".
        func value(_ key: String) -> Double? { n[key] ?? nil }
        let calories = value("calories").flatMap { $0 > 0 ? $0 : nil }
        let hasData = calories != nil
        let name = FoodClassifier.clean(food.name)
        var serving: String?
        if let a = food.servingSizeInfo?.servingSizeAmount, let u = food.servingSizeInfo?.servingSizeUnit, !a.isEmpty {
            serving = "\(a) \(u)"
        }
        let tags = Set(food.icons.foodIcons.map(\.slug))
        return FoodItem(
            id: id,
            name: name,
            station: station,
            calories: calories,
            protein: hasData ? value("g_protein") : nil,
            carbs: hasData ? value("g_carbs") : nil,
            fat: hasData ? value("g_fat") : nil,
            fiber: hasData ? value("g_fiber") : nil,
            sugar: hasData ? value("g_sugar") : nil,
            sodium: hasData ? value("mg_sodium") : nil,
            serving: serving,
            ingredients: food.ingredients?.isEmpty == false ? food.ingredients : nil,
            tags: tags,
            isMain: FoodClassifier.isMain(name: name, station: station, calories: calories, protein: hasData ? value("g_protein") : nil)
        )
    }
}

enum FoodClassifier {
    private static let nonMainStations: Set<String> = [
        "bakery", "farmstand", "farmstand south", "farmstand north", "farmstand east", "soups", "deli",
    ]

    private static let entreeWords = #"\b(steak|chicken|beef|pork|turkey|salmon|fish|cod|swordfish|tilapia|haddock|shrimp|mussels|tofu|tempeh|burger|cheeseburger|sandwich|wrap|pizza|stromboli|calzone|tacos?|burrito|quesadilla|quesdilla|curry|vindaloo|parmesan|meatloaf|lasagna|mac & cheese|stir fry|pad thai|ribs|wings|tenders|nuggets|gyro|flatbread|omelets?|eggs|french toast|pancakes?|waffles?|scramble|chili|kebab|meatballs|lamb|spanakopita|enchiladas?|casserole|cacio|risotto|ravioli|gnocchi|dumplings|falafel|pulled)\b"#
    private static let sideWords = #"\b(rice|buns?|rolls?|bread|breadsticks|knot|sauce|dressing|vinaigrette|vinegar|oil|mayonnaise|gravy|salsa|ketchup|syrup|butter|toppings?|fries|tots|potato(es)?|hash|chips|cookies?|brownie|pie|muffin|scone|cake|cheesecake|pudding|bar|fruit|yogurt|cereal|shredded|sliced|diced|lettuce|jalapenos?|corn|beans|carrots|cauliflower|broccoli|squash|vegetables?|greens|spinach|peppers|onions?|tortilla|focaccia|farro|quinoa|couscous|noodles|pasta|rigatoni|penne|cavatappi|spaghetti|bites|rings|sticks|poppers|soup|chowder|bisque|oatmeal|grits|bacon|sausage|congee|half order|1/2 order|cheese for|meats for|vegetables for)\b"#

    /// Words that make something a side even when it also names a protein ("Steak Fries", "Chicken Noodle Soup").
    private static let alwaysSide = #"\b(fries|tots|chips|sauce|dressing|gravy|buns?|cookies?|cheesecake|toppings|soup|chowder|bisque|stew|broth)\b|1/2 order|half order"#

    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\s+(LN|A9|KWC|SF|Grill)$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^SF\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Desserts get their own section, since they change every day and people care about them.
    private static let dessertWords = #"\b(cakes?|cupcakes?|cheesecake|cookies?|brownies?|blondies?|pies?|pudding|cobbler|crisp|crumble|tarts?|mousse|ice cream|gelato|sundaes?|soft serve|donuts?|doughnuts?|cannoli|eclairs?|macarons?|cream puffs?|tiramisu|baklava|churros?|fudge|whoopie|s'mores|rice krispie|parfait)\b"#
    /// "Lemon Bar" is a dessert; "Salad Bar" isn't, so bars only count from the bakery.
    private static let bakeryBars = #"\bbars?\b"#

    static func isDessert(name: String, station: String) -> Bool {
        let n = name.lowercased()
        if ["pie crust", "pot pie", "shepherd", "yogurt parfait", "crab cake", "fish cake", "rice cake"].contains(where: n.contains) { return false }
        if n.range(of: dessertWords, options: .regularExpression) != nil { return true }
        return station.lowercased() == "bakery" && n.range(of: bakeryBars, options: .regularExpression) != nil
    }

    static func isMain(name: String, station: String, calories: Double?, protein: Double?) -> Bool {
        if nonMainStations.contains(station.lowercased()) { return false }
        let n = name.lowercased()
        // Pizza is there every day, so it isn't a headline (it's still under its station's "More").
        if n.contains("pizza") { return false }
        let entree = n.range(of: entreeWords, options: .regularExpression) != nil
        let side = n.range(of: sideWords, options: .regularExpression) != nil
        if n.range(of: alwaysSide, options: .regularExpression) != nil { return false }
        if entree && !n.contains("sauce") { return true }
        if side { return false }
        return (protein ?? 0) >= 12 || (calories ?? 0) >= 250
    }

    /// Whole-word, case-insensitive match that also catches simple plurals ("steak" → "Steaks").
    static func matches(_ name: String, keyword: String) -> Bool {
        let k = NSRegularExpression.escapedPattern(for: keyword.trimmingCharacters(in: .whitespaces))
        guard !k.isEmpty else { return false }
        return name.range(of: #"\b\#(k)(s|es)?\b"#, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }
}

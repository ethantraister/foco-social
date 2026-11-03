import SwiftUI

struct MenuView: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tabIsActive) private var active
    @AppStorage("tab") private var tab = AppTab.together.rawValue
    @State private var leftAt: Date?
    @State private var date = FoCoCalendar.startOfDay(.now)
    @State private var meal = UserDefaults.standard.string(forKey: "meal").flatMap(Meal.init) ?? .current
    @State private var query = ""

    @Environment(SocialStore.self) private var socialStore

    private var allItems: [FoodItem]? { store.items(on: date, meal: meal) }

    /// "Maya and 2 others are eating dinner": friends going to a plan for this meal. (Who's there now is on Together.)
    private var friendsLine: (people: [Person], text: String)? {
        guard socialStore.phase == .ready else { return nil }
        let me = socialStore.myId
        var people: [Person] = []
        for plan in socialStore.together.plans where plan.mealKind == meal && FoCoCalendar.cal.isDate(plan.startsAt, inSameDayAs: date) {
            for p in plan.going where p.id != me && !people.contains(p) { people.append(p) }
        }
        guard let first = people.first else { return nil }
        let who = people.count == 1 ? first.firstName : "\(first.firstName) and \(people.count - 1) other\(people.count == 2 ? "" : "s")"
        return (people, "\(who) \(people.count == 1 ? "is" : "are") eating \(meal.title.lowercased())")
    }
    private var visible: [FoodItem] { (allItems ?? []).filter(prefs.allows) }
    private var saladBar: [FoodItem] { meal.includesSaladBar ? store.saladBar(on: date).filter(prefs.allows) : [] }

    /// Today's desserts, once each (the same cookie can be at two stations).
    private var desserts: [FoodItem] {
        var seen = Set<String>()
        return visible.filter { $0.isDessert && seen.insert($0.name.lowercased()).inserted }
    }

    /// Each station's main dishes up front and everything else under "More". Desserts are in their own section.
    private struct Station: Identifiable {
        let name: String
        var mains: [FoodItem] = []
        var more: [FoodItem] = []
        var id: String { name }
    }

    private var stations: [Station] {
        var order: [String] = []
        var byName: [String: Station] = [:]
        for item in visible where !item.isDessert {
            if byName[item.station] == nil { order.append(item.station); byName[item.station] = Station(name: item.station) }
            if item.isMain { byName[item.station]!.mains.append(item) } else { byName[item.station]!.more.append(item) }
        }
        return order.compactMap { byName[$0] }
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    SearchResultsView(query: query)
                } else {
                    menuList
                }
            }
            .navigationTitle("Foco")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search this week — steak, sushi…")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { FoodAlertsView() } label: {
                        Image(systemName: prefs.watches.isEmpty ? "bell" : "bell.badge")
                    }
                    .accessibilityLabel("Food alerts")
                    .accessibilityValue(prefs.watches.isEmpty ? "" : "Following \(prefs.watches.count)")
                }
            }
            .navigationDestination(for: FoodRoute.self) { FoodDetailView(route: $0) }
            .navigationDestination(for: StationRoute.self) { StationDishesView(route: $0) }
            .tabRoot()
            .task(id: active) { if active { socialStore.noteUse(.menu) } }
        }
    }

    private var menuList: some View {
        List {
            // Day and meal float on the backdrop, not in a card: they're controls, so they're glass.
            Section {
                DayStrip(selection: $date)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                mealPicker
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if socialStore.phase == .signedOut {
                Section {
                    Button { tab = AppTab.together.rawValue } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2.fill").foregroundStyle(.tint)
                            Text("See which friends are at Foco").font(.subheadline).foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityHint("Opens Together, where you sign in with your NetID")
                }
            } else if let social = friendsLine {
                Section {
                    Button { tab = AppTab.together.rawValue } label: {
                        HStack(spacing: 10) {
                            AvatarStack(people: social.people, max: 3, size: 26)
                            Text(social.text).font(.subheadline).foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityHint("Opens Together")
                }
            }

            if prefs.hasFilters {
                Section { filterBanner }
            }

            content
        }
        .listStyle(.insetGrouped)
        .onBackdrop()
        .refreshable { await store.load(date: date, meal: meal, force: true) }
        .task(id: "\(date)\(meal)") { await store.load(date: date, meal: meal) }
        .sensoryFeedback(.selection, trigger: meal)
        .sensoryFeedback(.selection, trigger: date)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { leftAt = .now }
            // Back after a while: show what's on now, not the meal you were looking at this morning.
            if phase == .active, let leftAt, Date.now.timeIntervalSince(leftAt) > 30 * 60 {
                date = FoCoCalendar.startOfDay(.now)
                meal = .current
            }
        }
    }

    @ViewBuilder private var mealPicker: some View {
        if typeSize.isAccessibilitySize {
            Picker("Meal", selection: $meal) {
                ForEach(Meal.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.menu)
        } else {
            Picker("Meal", selection: $meal) {
                ForEach(Meal.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var filterBanner: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Image(systemName: prefs.filtersPaused ? "eye" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prefs.filtersPaused ? "Showing everything" : "Filtered for your diet")
                        .font(.subheadline.weight(.semibold))
                    Text(prefs.filterSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            Button(prefs.filtersPaused ? "Use my diet" : "Show all") { prefs.filtersPaused.toggle() }
                .glassButton()
                .controlSize(typeSize.isAccessibilitySize ? .regular : .small)
                .fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        if let all = allItems, !all.isEmpty {
            if !desserts.isEmpty {
                Section {
                    DessertStrip(items: desserts, date: date, meal: meal)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                } header: {
                    Label("Desserts \(FoCoCalendar.phrase(date))", systemImage: "birthday.cake.fill")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(Color.dessert)
                        .textCase(nil)
                }
            }

            let withMains = stations.filter { !$0.mains.isEmpty }
            if withMains.isEmpty && !visible.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No main dishes fit your diet this meal.")
                        if prefs.filtering { Button("Show everything") { prefs.filtersPaused = true } }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            // Every station slides sideways, like the desserts: its main dishes first, then See all for the rest.
            ForEach(withMains) { station in
                Section {
                    DishStrip(items: station.mains, date: date, meal: meal,
                              seeAll: station.more.isEmpty ? nil : StationRoute(name: station.name, mains: station.mains, more: station.more, date: date, meal: meal))
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                } header: {
                    SectionTitle(station.name)
                } footer: {
                    if station.id == withMains.first?.id { Text("Press and hold any dish to get an alert when it’s served.") }
                }
            }

            // Stations with only sides and everyday items (bakery, deli…): the first few, then See all.
            ForEach(stations.filter { $0.mains.isEmpty && !$0.more.isEmpty }) { station in
                Section {
                    DishStrip(items: Array(station.more.prefix(Self.stripLimit)), date: date, meal: meal,
                              seeAll: station.more.count > Self.stripLimit ? StationRoute(name: station.name, mains: [], more: station.more, date: date, meal: meal) : nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                } header: {
                    SectionTitle(station.name)
                }
            }

            if !saladBar.isEmpty {
                Section {
                    DishStrip(items: Array(saladBar.prefix(Self.stripLimit)), date: date, meal: meal,
                              seeAll: saladBar.count > Self.stripLimit ? StationRoute(name: "Salad Bar", mains: [], more: saladBar, date: date, meal: meal) : nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                } header: {
                    SectionTitle("Salad Bar")
                } footer: {
                    Text("Open all day")
                }
            }
        } else if store.isLoading(date, meal) {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(meal.title.lowercased())…").foregroundStyle(.secondary)
                }
            }
        } else if let error = store.error(date, meal) {
            Section {
                ContentUnavailableView {
                    Label("Can't load the menu", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await store.load(date: date, meal: meal, force: true) } }
                        .glassButton(prominent: true)
                }
            }
        } else {
            Section {
                ContentUnavailableView(
                    "No \(meal.title.lowercased()) posted",
                    systemImage: meal.symbol,
                    description: Text("Dining hasn't posted a \(meal.title.lowercased()) menu \(FoCoCalendar.phrase(date)). Try another meal or day.")
                )
            }
        }
    }

    /// How many cards a station without main dishes shows before See all.
    private static let stripLimit = 8
}

struct SearchResultsView: View {
    @Environment(MenuStore.self) private var store
    @Environment(Preferences.self) private var prefs
    let query: String

    private var groups: [(title: String, hits: [SearchHit])] {
        var order: [String] = []
        var map: [String: [SearchHit]] = [:]
        for hit in store.search(query) where prefs.allows(hit.item) {
            let title = "\(FoCoCalendar.relativeName(hit.date)) · \(hit.meal.title)"
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(hit)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.hits) { hit in
                        NavigationLink(value: FoodRoute(item: hit.item, date: hit.date, meal: hit.meal)) {
                            FoodRow(item: hit.item)
                        }
                        .watchSwipe(hit.item.name)
                    }
                }
            }
            Section {
                let q = query.trimmingCharacters(in: .whitespaces)
                Button {
                    prefs.toggleWatch(q)
                    Task {
                        await AlertScheduler.requestPermission()
                        await AlertScheduler.reschedule()
                    }
                } label: {
                    Label(prefs.isWatching(q) ? "You'll be alerted for “\(q)”" : "Alert me whenever “\(q)” is served",
                          systemImage: prefs.isWatching(q) ? "bell.fill" : "bell.badge")
                }
            } footer: {
                Text("Searches the posted menus for the next 7 days.")
            }
        }
        .task { await store.loadUpcoming() }
    }
}

struct DayStrip: View {
    @Binding var selection: Date
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 54
    @Namespace private var glassSpace
    private let days = (0..<7).map { FoCoCalendar.adding(days: $0, to: FoCoCalendar.startOfDay(.now)) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        let selected = FoCoCalendar.cal.isDate(day, inSameDayAs: selection)
                        Button { withAnimation(.snappy) { selection = day } } label: {
                            VStack(spacing: 1) {
                                Text(label(day)).font(.caption.weight(.semibold))
                                Text(day.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).day()))
                                    .font(.title3.weight(.bold).monospacedDigit())
                            }
                            .frame(minWidth: size, minHeight: size)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .glass(in: .rect(cornerRadius: 18), tint: selected ? .dartmouthDeep : nil, interactive: true)
                            .glassID(day, in: glassSpace)
                            .contentShape(.rect(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(FoCoCalendar.relativeName(day) + ", " + day.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).month(.wide).day()))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .noTabBarMargin()
    }

    private func label(_ d: Date) -> String {
        FoCoCalendar.cal.isDateInToday(d) ? "Today" : d.formatted(Date.FormatStyle(timeZone: FoCoCalendar.tz).weekday(.abbreviated))
    }
}

extension Color {
    /// The dessert highlight: a warm raspberry, so desserts stand out from the green.
    static let dessert = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.95, green: 0.42, blue: 0.58, alpha: 1)
        : UIColor(red: 0.70, green: 0.13, blue: 0.34, alpha: 1) })
}

/// Desserts as big cards you scroll sideways through, at the top of the menu.
private struct DessertStrip: View {
    let items: [FoodItem]
    let date: Date
    let meal: Meal

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Spacer(minLength: 0)
                            Text(item.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let cal = item.calories {
                                Text("\(Int(cal)) cal").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(14)
                        // Every card as tall as the tallest, so long names wrap instead of being cut off.
                        .frame(width: 156, alignment: .bottomLeading)
                        .frame(minHeight: 128, maxHeight: .infinity, alignment: .bottomLeading)
                        .background(DessertCardFill(seed: item.name), in: .rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.accessibilitySummary)
                    .watchSwipe(item.name)
                }
            }
            .padding(.horizontal, 16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .noTabBarMargin()
    }
}

/// Each dessert card gets its own warm color (raspberry, berry, caramel, plum…), always the same for the same dessert.
private struct DessertCardFill: ShapeStyle {
    let seed: String
    // Dark enough at both ends for white text.
    private static let pairs: [(Color, Color)] = [
        (Color(red: 0.62, green: 0.12, blue: 0.30), Color(red: 0.80, green: 0.27, blue: 0.33)),
        (Color(red: 0.45, green: 0.13, blue: 0.38), Color(red: 0.66, green: 0.22, blue: 0.45)),
        (Color(red: 0.52, green: 0.25, blue: 0.08), Color(red: 0.70, green: 0.38, blue: 0.13)),
        (Color(red: 0.33, green: 0.16, blue: 0.46), Color(red: 0.55, green: 0.27, blue: 0.56)),
        (Color(red: 0.58, green: 0.16, blue: 0.16), Color(red: 0.76, green: 0.33, blue: 0.24)),
    ]

    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        let index = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.pairs.count
        let (a, b) = Self.pairs[index]
        return LinearGradient(colors: [b, a], startPoint: .topTrailing, endPoint: .bottomLeading)
    }
}

/// A station's dishes for the See all page: its main dishes, then everything else.
struct StationRoute: Hashable {
    let name: String
    let mains: [FoodItem]
    let more: [FoodItem]
    let date: Date
    let meal: Meal
    var count: Int { mains.count + more.count }
}

/// A station's dishes as cards you slide through sideways, like the desserts, ending in See all when there's more.
/// Press and hold a card to get an alert when that dish is served (a sideways swipe moves the cards).
private struct DishStrip: View {
    let items: [FoodItem]
    let date: Date
    let meal: Meal
    var seeAll: StationRoute? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    NavigationLink(value: FoodRoute(item: item, date: date, meal: meal)) {
                        DishCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .watchSwipe(item.name)
                }
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        SeeAllCard(count: seeAll.count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all of \(seeAll.name)")
                    .accessibilityValue("\(seeAll.count) dishes")
                }
            }
            .padding(.horizontal, 16)
            // Every card as tall as the tallest, so long names wrap instead of being cut off.
            .fixedSize(horizontal: false, vertical: true)
        }
        .noTabBarMargin()
    }
}

private struct DishCard: View {
    @Environment(Preferences.self) private var prefs
    let item: FoodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 4) {
                DietBadges(item: item)
                Spacer(minLength: 0)
                if prefs.isWatching(item.name) {
                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            Text(item.name)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let macros = item.macroLine {
                Text(macros).font(.caption).foregroundStyle(.secondary)
            }
            if prefs.filtering && !item.hasAllergenInfo {
                Text("Not labeled").font(.caption.weight(.medium)).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 168, alignment: .topLeading)
        .frame(minHeight: 132, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilityValue(prefs.isWatching(item.name) ? "Alert on" : "")
        .accessibilityHint("Shows nutrition and allergens")
    }
}

/// The last card in a station's row: opens every dish it has today.
private struct SeeAllCard: View {
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.right.circle.fill").font(.title2)
            Text("See all").font(.headline)
            Text("\(count) dishes").font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.tint)
        .frame(width: 120)
        .frame(minHeight: 132, maxHeight: .infinity)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
    }
}

/// Everything a station has this meal, as a list: its main dishes, then its sides and everyday items.
/// Swipe right on a dish here (or press and hold it) to get an alert when it's served.
struct StationDishesView: View {
    let route: StationRoute

    var body: some View {
        List {
            if !route.mains.isEmpty {
                Section {
                    ForEach(route.mains) { row($0, prominent: true) }
                } header: {
                    SectionTitle("Main dishes")
                }
            }
            if !route.more.isEmpty {
                Section {
                    ForEach(route.more) { row($0, prominent: false) }
                } header: {
                    if !route.mains.isEmpty { SectionTitle("More from \(route.name)") }
                } footer: {
                    Text("Swipe right on any dish to get an alert when it’s served.")
                }
            }
        }
        .onBackdrop()
        .navigationTitle(route.name)
    }

    private func row(_ item: FoodItem, prominent: Bool) -> some View {
        NavigationLink(value: FoodRoute(item: item, date: route.date, meal: route.meal)) {
            FoodRow(item: item, prominent: prominent, showStation: false)
        }
        .watchSwipe(item.name)
    }
}

import SwiftUI

struct FoodDetailView: View {
    @Environment(Preferences.self) private var prefs
    let route: FoodRoute

    private var item: FoodItem { route.item }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name).font(.system(.title2, design: .serif).weight(.bold))
                    Label("\(item.station) · \(route.meal.title) \(FoCoCalendar.phrase(route.date))", systemImage: route.meal.symbol)
                        .foregroundStyle(.secondary)
                    if !item.diets.isEmpty {
                        Text(item.diets.map(\.title).joined(separator: " · "))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                Toggle(isOn: Binding(get: { prefs.isWatching(item.name) }, set: { on in
                    guard on != prefs.isWatching(item.name) else { return }
                    prefs.toggleWatch(item.name)
                    Task {
                        await AlertScheduler.requestPermission()
                        await AlertScheduler.reschedule()
                    }
                })) {
                    Label("Alert me when it's served", systemImage: "bell")
                }
                .sensoryFeedback(.success, trigger: prefs.isWatching(item.name))
            } footer: {
                Text("You'll get a notification whenever it's on the menu.")
            }

            Section("Nutrition") {
                if item.calories == nil {
                    Text("Dining hasn't posted nutrition for this item.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                        GridRow { stat("Calories", item.calories, ""); stat("Protein", item.protein, "g") }
                        GridRow { stat("Carbs", item.carbs, "g"); stat("Fat", item.fat, "g") }
                        GridRow { stat("Fiber", item.fiber, "g"); stat("Sugar", item.sugar, "g") }
                        GridRow { stat("Sodium", item.sodium, "mg"); stat("Protein per 100 cal", item.proteinPer100Cal, "g", decimals: 1) }
                    }
                    .padding(.vertical, 4)
                    if item.nutritionLooksWrong {
                        Label("These numbers can't all be right: the protein alone adds up to more calories than the total. Dining's data has an error.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let serving = item.serving {
                        Text("Per \(serving) serving").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if !item.hasAllergenInfo {
                    Label("Dining didn't label this item", systemImage: "questionmark.circle").foregroundStyle(.orange)
                } else if item.allergens.isEmpty {
                    Text("None of the 11 tracked allergens")
                } else {
                    Text("Contains " + ListFormatter.localizedString(byJoining: item.allergens.map { $0.title.lowercased() }))
                        .font(.body.weight(.medium))
                }
            } header: {
                Text("Allergens")
            } footer: {
                Text("Labels come from Dartmouth Dining. Peanuts and tree nuts aren't labeled. With a serious allergy, confirm at the station.")
            }

            if let ingredients = item.ingredients {
                Section("Ingredients") {
                    Text(ingredients).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .onBackdrop()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stat(_ label: String, _ value: Double?, _ unit: String, decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.\(decimals)f", $0) + unit } ?? "—").font(.title3.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }
}

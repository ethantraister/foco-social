import SwiftUI

struct DietView: View {
    var body: some View { NavigationStack { DietForm() } }
}

struct DietForm: View {
    @Environment(Preferences.self) private var prefs
    @AppStorage("onboarded") private var onboarded = true

    var body: some View {
        @Bindable var prefs = prefs
            Form {
                Section {
                    FlowLayout {
                        ForEach(Diet.allCases) { diet in
                            Chip(title: diet.title, selected: prefs.require.contains(diet.rawValue)) {
                                self.prefs.require.formSymmetricDifference([diet.rawValue])
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Only show food that is")
                } footer: {
                    Text("Vegan food counts as vegetarian.")
                }

                Section {
                    FlowLayout {
                        ForEach(Allergen.allCases) { allergen in
                            Chip(title: allergen.title, selected: prefs.avoid.contains(allergen.rawValue), excludes: true) {
                                self.prefs.avoid.formSymmetricDifference([allergen.rawValue])
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Hide food that contains")
                } footer: {
                    Text("Dining doesn't label peanuts or tree nuts, so the app can't filter them. Labels can be incomplete. With a serious allergy, confirm at the station or ask the FoCo dietitian.")
                }

                Section {
                    Button("Run setup again") { onboarded = false }
                }
            }
            .onBackdrop()
            .navigationTitle("My Diet")
    }
}

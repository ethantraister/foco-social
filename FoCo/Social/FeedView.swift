import PhotosUI
import SwiftUI

struct FeedView: View {
    @Environment(SocialStore.self) private var social
    @State private var sort = "top"
    @State private var composing = false

    private var posts: [Post] {
        (social.feeds[.photo] ?? []).filter { !(sort == "top" && $0.id == social.bestToday?.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Sort", selection: $sort) {
                        Text("Top").tag("top")
                        Text("Newest").tag("new")
                    }
                    .pickerStyle(.segmented)
                }
                .listRowSeparator(.hidden)

                if social.isLocalDemo {
                    Section { DemoBanner() }
                }

                if social.isOffline {
                    Section { OfflineNote() }
                }

                if sort == "top", let best = social.bestToday {
                    Section {
                        PostCard(post: best)
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "crown.fill").foregroundStyle(.orange)
                            Text("Plate of the day").foregroundStyle(Color.primary)
                        }
                        .font(.headline)
                        .accessibilityElement(children: .combine)
                    }
                }

                Section {
                    if social.feeds[.photo] == nil {
                        if !social.isOffline {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40).listRowBackground(Color.clear)
                        }
                    } else if posts.isEmpty {
                        ContentUnavailableView {
                            Label("No plates yet", systemImage: "camera")
                        } description: {
                            Text("Snap your plate. The most-upvoted photo each day is Plate of the Day.")
                        } actions: {
                            Button("Post a plate") { composing = true }.buttonStyle(.borderedProminent)
                        }
                    }
                    ForEach(posts) { PostCard(post: $0) }
                } header: {
                    if !posts.isEmpty { Text(sort == "top" ? "Most upvoted" : "Latest plates") }
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Label("New post", systemImage: "plus.circle.fill").font(.title3) }
                }
            }
            .refreshable { await social.refreshFeed(.photo, sort: sort) }
            .task(id: sort) { await social.refreshFeed(.photo, sort: sort) }
            .sheet(isPresented: $composing) { PostComposer() }
            .sensoryFeedback(.selection, trigger: sort)
            .toastHost()
        }
    }
}

struct PostCard: View {
    @Environment(SocialStore.self) private var social
    let post: Post
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var confirmDelete = false

    private var mine: Bool { post.authorId == social.myId }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(person: post.author, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(post.authorName).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if mine {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete post", systemImage: "trash")
                        }
                    } else {
                        Button { reporting = true } label: { Label("Report post", systemImage: "flag") }
                        Button(role: .destructive) { confirmBlock = true } label: { Label("Block \(post.authorName)", systemImage: "hand.raised") }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More options")
            }
            .accessibilityElement(children: .combine)

            if let url = social.photoURL(post) {
                // The whole photo at its own shape, never cropped; a very tall one is fit inside 520 pt.
                RemoteImage(url: url, fit: true) {
                    Color.secondary.opacity(0.1).aspectRatio(4 / 3, contentMode: .fit)
                }
                .frame(maxHeight: 520)
                .clipShape(.rect(cornerRadius: 14))
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(post.dish.map { "Photo of \($0)" } ?? "Meal photo")
            }

            if !post.body.isEmpty {
                Text(post.body).font(.subheadline)
            }

            HStack {
                Button {
                    Task { await social.toggleVote(post) }
                } label: {
                    Label("\(post.votes)", systemImage: post.voted ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(post.voted ? Color.dartmouthGreen : Color.secondary.opacity(0.12), in: .capsule)
                        .foregroundStyle(post.voted ? Color(uiColor: .systemBackground) : .primary)
                }
                .buttonStyle(.plain)
                .disabled(mine)
                .sensoryFeedback(.impact(weight: .light), trigger: post.voted)
                .accessibilityLabel("Upvote, \(post.votes) \(post.votes == 1 ? "vote" : "votes")")
                .accessibilityAddTraits(post.voted ? .isSelected : [])

                Spacer()
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog("Why are you reporting this?", isPresented: $reporting, titleVisibility: .visible) {
            ForEach(["Offensive or harassing", "Spam", "Not FoCo food", "Shows someone without consent", "Something else"], id: \.self) { reason in
                Button(reason) {
                    Task { await social.report(post, reason: reason) }
                }
            }
        }
        .confirmationDialog("Block \(post.authorName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await social.block(post.author) } }
        } message: {
            Text("You won't see each other's posts, plans, or check-ins.")
        }
        .confirmationDialog("Delete this post?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await social.delete(post) } }
        } message: {
            Text("It's removed from the feed for everyone, along with its photo.")
        }
    }

    private var subtitle: String {
        var parts = [post.createdAt.formatted(.relative(presentation: .named))]
        if let meal = post.mealKind { parts.append(meal.title) }
        if let dish = post.dish, !dish.isEmpty { parts.append(dish) }
        return parts.joined(separator: " · ")
    }

}

struct PostComposer: View {
    @Environment(SocialStore.self) private var social
    @Environment(MenuStore.self) private var menu
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @State private var meal: Meal? = .current
    @State private var dish = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var photoFailed = false
    @State private var working = false

    private var dishes: [String] {
        guard let meal else { return [] }
        return Array((menu.items(on: .now, meal: meal) ?? []).filter(\.isMain).prefix(8).map(\.name))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image {
                        // As it will look in the feed: the whole photo, not cropped.
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 360)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button { self.image = nil; pickerItem = nil } label: {
                                    Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.5))
                                }
                                .padding(8)
                                .accessibilityLabel("Remove photo")
                            }
                            .frame(maxWidth: .infinity)
                    }
                    if photoFailed {
                        Text("Couldn't open that photo. Try another one.").font(.footnote).foregroundStyle(.red)
                    }
                    HStack {
                        PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .compatible) {
                            Label(image == nil ? "Choose photo" : "Change photo", systemImage: "photo.on.rectangle")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Spacer()
                            Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Section {
                    TextField("Caption (optional)", text: $caption, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Which meal?") {
                    Picker("Meal", selection: $meal) {
                        Text("None").tag(Meal?.none)
                        ForEach(Meal.allCases) { Text($0.title).tag(Meal?.some($0)) }
                    }
                    TextField("Dish (optional)", text: $dish)
                    if !dishes.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(dishes, id: \.self) { d in
                                Chip(title: d, selected: dish == d) { dish = dish == d ? "" : d }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("New plate")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .task(id: meal) { if let meal { await menu.load(date: .now, meal: meal) } }
            .onChange(of: pickerItem) {
                guard let item = pickerItem else { return }
                photoFailed = false
                Task {
                    if let picked = try? await item.loadTransferable(type: PickedImage.self) { image = picked.image } else { photoFailed = true }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(image: $image).ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            working = true
                            let ok = await social.post(kind: .photo, body: caption, meal: meal, dish: dish, image: image)
                            working = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if working { ProgressView() } else { Text("Post").bold() }
                    }
                    .disabled(image == nil || working)
                }
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    /// Start on the selfie camera (profile photos).
    var front = false
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if front, UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

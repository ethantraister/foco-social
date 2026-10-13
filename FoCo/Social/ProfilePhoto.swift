import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Profile picture: a big circle with "Add photo" / "Edit photo" under it, which opens a short list:
/// Take photo (selfie camera), Choose photo (camera roll, then move and zoom into the circle), Remove photo.
/// Without a photo, people see your initials.
struct ProfilePictureEditor: View {
    @Environment(SocialStore.self) private var social
    /// For the initials preview.
    let name: String
    /// A photo picked in this session, not uploaded yet.
    @Binding var newPhoto: UIImage?
    /// True when the saved photo should be removed.
    @Binding var removeSaved: Bool
    let savedPath: String?
    /// Whose initials color to show: you by default, or a group.
    var ownerId: UUID? = nil
    /// "profile picture" or "group photo", for the options sheet's title.
    var noun = "profile picture"
    @State private var showOptions = false
    /// What was picked in the options sheet; it opens once that sheet has gone away.
    @State private var next: PhotoSource?
    @State private var choosing = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var cropping: CropTarget?
    @State private var showCamera = false

    private var showsSaved: Bool { newPhoto == nil && savedPath != nil && !removeSaved }
    private var hasPhoto: Bool { newPhoto != nil || showsSaved }

    var body: some View {
        VStack(spacing: 12) {
            Button { showOptions = true } label: {
                preview(size: 140)
                    .overlay { if loading { ProgressView().controlSize(.large).tint(.white) } }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(noun.prefix(1).uppercased() + noun.dropFirst())
            .accessibilityValue(hasPhoto ? "Photo" : "Initials")
            .accessibilityHint("Change the \(noun)")

            Button(hasPhoto ? "Edit photo" : "Add photo") { showOptions = true }
                .font(.headline)
                .buttonStyle(.borderless)
                .disabled(loading)

            if loadFailed {
                Text("Couldn't open that photo. Try another one.").font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .sheet(isPresented: $showOptions, onDismiss: openNext) {
            PhotoOptionsSheet(preview: preview(size: 44), title: hasPhoto ? "Edit \(noun)" : "Add \(noun)", hasPhoto: hasPhoto,
                              canTakePhoto: UIImagePickerController.isSourceTypeAvailable(.camera)) { source in
                next = source
                showOptions = false
            } remove: {
                newPhoto = nil
                removeSaved = true
                showOptions = false
            }
        }
        // .compatible hands over a JPEG even for HEIC, RAW, and other formats.
        .photosPicker(isPresented: $choosing, selection: $pickerItem, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: pickerItem) { load(pickerItem) }
        .fullScreenCover(item: $cropping) { target in
            PhotoCropView(image: target.image) { newPhoto = $0 }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(image: $newPhoto, front: true).ignoresSafeArea()
        }
    }

    private func openNext() {
        switch next {
        case .camera: showCamera = true
        case .library: loadFailed = false; choosing = true
        case nil: break
        }
        next = nil
    }

    private func preview(size: CGFloat) -> some View {
        Group {
            if let newPhoto {
                Image(uiImage: newPhoto).resizable().scaledToFill()
            } else {
                Avatar(person: Person(id: ownerId ?? social.myId ?? Self.placeholderId, name: name, emoji: "",
                                      photoPath: showsSaved ? savedPath : nil), size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private static let placeholderId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadFailed = false
        loading = true
        Task {
            let picked = try? await item.loadTransferable(type: PickedImage.self)
            loading = false
            pickerItem = nil   // so picking the same photo again still works
            if let picked { cropping = CropTarget(image: picked.image) } else { loadFailed = true }
        }
    }
}

enum PhotoSource { case camera, library }

/// The short sheet behind "Edit photo", sized to its rows.
private struct PhotoOptionsSheet<Preview: View>: View {
    let preview: Preview
    let title: String
    let hasPhoto: Bool
    let canTakePhoto: Bool
    var pick: (PhotoSource) -> Void
    var remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 320

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                preview.accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 40, height: 40)
                        .background(Color(.tertiarySystemFill), in: .circle)
                }
                .accessibilityLabel("Close")
            }

            VStack(spacing: 0) {
                if canTakePhoto {
                    row("Take photo", icon: "camera") { pick(.camera) }
                    Divider().padding(.leading, 60)
                }
                row("Choose photo", icon: "photo") { pick(.library) }
                if hasPhoto {
                    Divider().padding(.leading, 60)
                    row("Remove photo", icon: "trash", tint: .red) { remove() }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 22))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(height)])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private func row(_ title: String, icon: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).frame(width: 28)
                Text(title)
                Spacer()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionRowStyle())
    }
}

/// A list-row highlight while pressed.
private struct OptionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color(.systemFill) : .clear)
    }
}

private struct CropTarget: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A photo from the library, decoded straight from the file at a sensible size (a 48 MP photo would otherwise use ~200 MB).
struct PickedImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            guard let image = UIImage.downsampled(at: received.file, maxPixels: 2400) else { throw CocoaError(.fileReadCorruptFile) }
            return PickedImage(image: image)
        }
    }
}

extension UIImage {
    /// Upright (EXIF rotation applied), longest side at most `maxPixels`, scale 1.
    static func downsampled(at url: URL, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Move and zoom a photo inside the circle, like setting a contact photo. Pinch to zoom, drag to move, double-tap to zoom in or out.
struct PhotoCropView: View {
    /// Upright, scale 1 (as `UIImage.downsampled` makes it).
    let image: UIImage
    var onChoose: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var side: CGFloat = 300
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxZoom: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            Text("Move and Scale")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 16)
            cropArea
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Choose") {
                    onChoose(cropped())
                    dismiss()
                }
                .bold()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
    }

    private var cropArea: some View {
        let liveZoom = Self.limited(zoom * pinch)
        let shown = shownSize(liveZoom)
        let liveOffset = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), shown)
        // The photo is drawn in an overlay so its size never changes the area's size (which sets the circle's size).
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(liveOffset)
            }
            .overlay {
                CropMask(side: side)
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            }
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
                    .frame(width: side, height: side)
                    .allowsHitTesting(false)
            }
            .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { max(1, min($0.size.width, $0.size.height) - 32) } action: { side = $0 }
        .gesture(
            DragGesture()
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset = clamped(CGSize(width: offset.width + value.translation.width,
                                            height: offset.height + value.translation.height), shownSize(zoom))
                }
                .simultaneously(with: MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        zoom = Self.limited(zoom * value.magnification)
                        offset = clamped(offset, shownSize(zoom))
                    })
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy) {
                zoom = zoom > 1.01 ? 1 : 2.5
                offset = clamped(offset, shownSize(zoom))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Photo, centered in the circle")
        .accessibilityHint("Choose uses the part inside the circle.")
    }

    /// Between 1 and 6, and never NaN (a pinch can report odd values).
    private static func limited(_ zoom: CGFloat) -> CGFloat {
        zoom.isFinite ? min(max(zoom, 1), maxZoom) : 1
    }

    /// At zoom 1 the photo just covers the circle's square.
    private var baseScale: CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }
        return max(side / image.size.width, side / image.size.height)
    }

    private func shownSize(_ zoom: CGFloat) -> CGSize {
        CGSize(width: image.size.width * baseScale * zoom, height: image.size.height * baseScale * zoom)
    }

    /// Keeps the photo covering the whole circle.
    private func clamped(_ offset: CGSize, _ shown: CGSize) -> CGSize {
        guard offset.width.isFinite, offset.height.isFinite else { return .zero }
        let maxX = max(0, (shown.width - side) / 2), maxY = max(0, (shown.height - side) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// The square under the circle, in the photo's pixels.
    private func cropped() -> UIImage {
        let scale = baseScale * zoom
        let off = clamped(offset, shownSize(zoom))
        let sidePixels = side / scale
        let rect = CGRect(x: image.size.width / 2 - off.width / scale - sidePixels / 2,
                          y: image.size.height / 2 - off.height / scale - sidePixels / 2,
                          width: sidePixels, height: sidePixels)
            .integral
            .intersection(CGRect(origin: .zero, size: image.size))
        guard let cg = image.cgImage?.cropping(to: rect) else { return image }
        return UIImage(cgImage: cg)
    }
}

/// The dimmed area around the circle.
private struct CropMask: Shape {
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        return path
    }
}

/// The camera, for profile and group photos.
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

import CoreTransferable
import UniformTypeIdentifiers
import Photos
import SwiftUI

private enum ProportionMode: String { case automatic, standard, custom }

struct CardResultView: View {
    let result: CardResult
    let onNewPhoto: () -> Void
    @State private var showingOriginal = false
    @State private var saving = false
    @State private var saved = false
    @State private var message: String?
    @State private var mode = ProportionMode.automatic
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var rendered: CardResult?
    @State private var rendering = false
    @State private var quarterTurns = 0
    private let processor = CardProcessor()

    private var displayed: CardResult { rendered ?? result }
    private var estimatedRatio: AspectRatioEstimate? {
        result.automaticRatio.map {
            AspectRatioEstimate(widthOverHeight: quarterTurns % 2 == 0 ? $0.widthOverHeight : 1 / $0.widthOverHeight,
                                relativeUncertainty: $0.relativeUncertainty)
        }
    }
    private var previewRatio: Double { quarterTurns % 2 == 0 ? result.aspectRatio : 1 / result.aspectRatio }
    private struct RenderRequest: Equatable { let ratio: Double; let turns: Int }
    private var renderRequest: RenderRequest { RenderRequest(ratio: desiredRatio ?? previewRatio, turns: quarterTurns) }
    private var desiredRatio: Double? {
        switch mode {
        case .automatic: estimatedRatio?.widthOverHeight
        case .standard: previewRatio <= 1 ? 1 / CardGeometry.standardAspectRatio : CardGeometry.standardAspectRatio
        case .custom:
            if let width = Self.number(customWidth), let height = Self.number(customHeight), width > 0, height > 0,
               (0.2...5).contains(width / height) { width / height } else { nil }
        }
    }
    private var canExport: Bool {
        guard let ratio = desiredRatio else { return false }
        return !rendering && displayed.quarterTurns == quarterTurns && abs(displayed.aspectRatio - ratio) < 1e-8
    }
    private static func number(_ string: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        return formatter.number(from: string)?.doubleValue
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ResultHeading()
                Picker("Image comparison", selection: $showingOriginal) {
                    Text("Corrected").tag(false)
                    Text("Original").tag(true)
                }.pickerStyle(.segmented)
                Image(decorative: showingOriginal ? result.original : displayed.corrected, scale: 1)
                    .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 320)
                    .padding(20)
                    .background(.background, in: RoundedRectangle(cornerRadius: 24))
                    .overlay { if rendering { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
                    .accessibilityLabel(showingOriginal ? "Original card photo" : "Straightened card")
                HStack {
                    Spacer()
                    Button {
                        quarterTurns = (quarterTurns + 1) % 4
                        if mode == .custom {
                            let previousWidth = customWidth
                            customWidth = customHeight
                            customHeight = previousWidth
                        }
                    } label: { Label("Rotate", systemImage: "rotate.right") }
                    .buttonStyle(.bordered).disabled(rendering || saving)
                    .accessibilityLabel("Rotate clockwise")
                }
                ProportionControls(estimate: estimatedRatio, mode: $mode, width: $customWidth, height: $customHeight)
                HStack {
                    if canExport {
                        Label("\(displayed.aspectRatio, specifier: "%.3f") : 1", systemImage: "aspectratio")
                    } else { Text("Preview • choose proportions to export") }
                    Spacer()
                    Text("\(displayed.corrected.width) × \(displayed.corrected.height) px")
                }.font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 12) {
                    Button(action: save) {
                        Label(saving ? "Saving…" : saved ? "Saved to Photos" : "Save to Photos",
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(saving || saved || !canExport)
                    ShareLink(item: CardPNG(data: displayed.pngData),
                              preview: SharePreview("Straightened trading card", image: Image(decorative: displayed.corrected, scale: 1))) {
                        Label("Share corrected card", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.bordered).controlSize(.large).disabled(!canExport)
                    Button("Scan another card", action: onNewPhoto).padding(.top, 4)
                }
            }.padding(24)
        }
        .task { if result.automaticRatio == nil { mode = .custom } }
        .task(id: renderRequest) {
            saved = false
            rendering = false
            let request = renderRequest
            let ratio = request.ratio
            if displayed.quarterTurns == request.turns && abs(displayed.aspectRatio - ratio) < 1e-8 { return }
            rendering = true
            do {
                // Local render only: changing proportions reuses the existing Photoroom mask.
                let updated = try await processor.render(result, aspectRatio: ratio, quarterTurns: request.turns)
                try Task.checkCancellation()
                rendered = updated
                rendering = false
            } catch {
                guard !Task.isCancelled else { return }
                rendering = false
                message = error.localizedDescription
            }
        }
        .alert("Card export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func save() {
        guard canExport else { return }
        let data = displayed.pngData
        let savedRatio = displayed.aspectRatio
        saving = true
        Task { @MainActor in
            defer { saving = false }
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                message = "Allow photo saving in Settings, or use Share to export your corrected card."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }
                saved = desiredRatio == savedRatio
            } catch { message = error.localizedDescription }
        }
    }
}

private struct ResultHeading: View {
    var body: some View {
        VStack(spacing: 8) {
            Label("Perspective corrected", systemImage: "checkmark.circle.fill")
                .font(.title2.bold()).foregroundStyle(Color.accentColor)
            Text("Straight edges. Background removed.").foregroundStyle(.secondary)
        }
    }
}

private struct ProportionControls: View {
    let estimate: AspectRatioEstimate?
    @Binding var mode: ProportionMode
    @Binding var width: String
    @Binding var height: String
    private enum Field: Hashable { case width, height }
    @FocusState private var editing: Field?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proportions").font(.headline)
            Picker("Proportions", selection: $mode) {
                Text("Automatic").tag(ProportionMode.automatic).disabled(estimate == nil)
                Text("Standard card").tag(ProportionMode.standard)
                Text("Custom").tag(ProportionMode.custom)
            }.pickerStyle(.menu).accessibilityIdentifier("proportions")
            if mode == .automatic, let estimate {
                Text("Estimated from camera calibration: \(estimate.widthOverHeight, specifier: "%.3f") : 1 (width : height).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if mode == .standard {
                Text("Use the standard 2.5 × 3.5-inch trading-card shape.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if estimate == nil {
                    Text("A reliable calibrated estimate isn’t available for this photo. Enter the card’s width and height, or choose Standard card.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Width", text: $width).focused($editing, equals: .width).accessibilityIdentifier("cardWidth")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $height).focused($editing, equals: .height).accessibilityIdentifier("cardHeight")
                }.textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                Text("Use the same units for both sides, for example 63 × 88. Ratios from 1:5 to 5:1 are supported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: mode) { editing = nil }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = nil } } }
    }
}

private struct CardPNG: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import MapKit

struct LocationLibraryTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LibraryImportSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let library: LocationLibrary
    let onClose: (() -> Void)?
    let onImport: (Set<UUID>, Set<UUID>) -> Void

    @State private var selectedLocationIDs: Set<UUID>
    @State private var selectedRouteIDs: Set<UUID>

    init(
        library: LocationLibrary,
        onClose: (() -> Void)? = nil,
        onImport: @escaping (Set<UUID>, Set<UUID>) -> Void
    ) {
        self.library = library
        self.onClose = onClose
        self.onImport = onImport
        _selectedLocationIDs = State(initialValue: Set(library.locations.map(\.id)))
        _selectedRouteIDs = State(initialValue: Set(library.routes.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Import Selection"))
                .font(.headline)
            Text(L10n.t("Choose which locations and routes should be imported."))
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox(L10n.f("Locations (%d/%d)", selectedLocationIDs.count, library.locations.count)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(L10n.t("All")) {
                            selectedLocationIDs = Set(library.locations.map(\.id))
                        }
                        Button(L10n.t("None")) {
                            selectedLocationIDs.removeAll()
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(library.locations) { location in
                                Toggle(
                                    location.name,
                                    isOn: Binding(
                                        get: { selectedLocationIDs.contains(location.id) },
                                        set: { isOn in
                                            if isOn {
                                                selectedLocationIDs.insert(location.id)
                                            } else {
                                                selectedLocationIDs.remove(location.id)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(height: 140)
                }
            }

            GroupBox(L10n.f("Routes (%d/%d)", selectedRouteIDs.count, library.routes.count)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(L10n.t("All")) {
                            selectedRouteIDs = Set(library.routes.map(\.id))
                        }
                        Button(L10n.t("None")) {
                            selectedRouteIDs.removeAll()
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(library.routes) { route in
                                Toggle(
                                    route.name,
                                    isOn: Binding(
                                        get: { selectedRouteIDs.contains(route.id) },
                                        set: { isOn in
                                            if isOn {
                                                selectedRouteIDs.insert(route.id)
                                            } else {
                                                selectedRouteIDs.remove(route.id)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(height: 140)
                }
            }

            HStack {
                Spacer()
                Button(L10n.t("Cancel")) {
                    close()
                }
                Button(L10n.t("Import Selection")) {
                    onImport(selectedLocationIDs, selectedRouteIDs)
                    close()
                }
                .disabled(selectedLocationIDs.isEmpty && selectedRouteIDs.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 520)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

struct GPXImportPreviewWindowView: View {
    @Environment(\.dismiss) private var dismiss

    let preview: GPXImportPreview
    let onClose: (() -> Void)?
    let onImport: (ClosedRange<Date>?, ClosedRange<Int>?) -> Void

    @State private var selectedStartFraction: Double
    @State private var selectedEndFraction: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion

    init(
        preview: GPXImportPreview,
        onClose: (() -> Void)? = nil,
        onImport: @escaping (ClosedRange<Date>?, ClosedRange<Int>?) -> Void
    ) {
        self.preview = preview
        self.onClose = onClose
        self.onImport = onImport

        let defaultRegion = Self.mapRegion(for: preview.points.map(\.point))
        _cameraPosition = State(initialValue: .region(defaultRegion))
        _visibleRegion = State(initialValue: defaultRegion)
        _selectedStartFraction = State(initialValue: 0)
        _selectedEndFraction = State(initialValue: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Import GPX"))
                .font(.headline)
            Text(preview.name)
                .font(.title3)
            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Map(position: $cameraPosition, interactionModes: [.zoom, .pan]) {
                if allCoordinates.count > 1 {
                    MapPolyline(coordinates: allCoordinates)
                        .stroke(Color.secondary.opacity(0.45), lineWidth: 2)
                }

                if selectedCoordinates.count > 1 {
                    MapPolyline(coordinates: selectedCoordinates)
                        .stroke(.blue, lineWidth: 4)
                }

                if let first = selectedCoordinates.first {
                    Marker(L10n.t("Start"), coordinate: first)
                        .tint(.green)
                }

                if let last = selectedCoordinates.last {
                    Marker(L10n.t("End"), coordinate: last)
                        .tint(.red)
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion = context.region
            }
            .overlay(alignment: .topTrailing) {
                mapZoomControls
            }
            .frame(minHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(preview.canSelectTimeRange ? L10n.t("Time Range") : L10n.t("Waypoint Range"))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                GPXRangeSelector(
                    startFraction: $selectedStartFraction,
                    endFraction: $selectedEndFraction
                )
                .frame(height: 36)

                HStack {
                    Text(selectedRangeStartText)
                    Spacer()
                    Text(selectedRangeEndText)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(selectionSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !canImportSelection {
                Text(L10n.t("At least two points are required in the selected range."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.t("Cancel")) {
                    close()
                }
                Button(L10n.t("Import Selection")) {
                    onImport(
                        preview.canSelectTimeRange ? selectedTimeRange : nil,
                        preview.canSelectTimeRange ? nil : selectedPointRange
                    )
                    close()
                }
                .disabled(!canImportSelection)
            }
        }
        .padding()
        .frame(minWidth: 820, minHeight: 700)
    }

    private var selectedTimeRange: ClosedRange<Date>? {
        guard let fullTimeRange = preview.timeRange else { return nil }
        let duration = fullTimeRange.upperBound.timeIntervalSince(fullTimeRange.lowerBound)
        guard duration > 0 else { return nil }
        let lower = fullTimeRange.lowerBound.addingTimeInterval(duration * selectedStartFraction)
        let upper = fullTimeRange.lowerBound.addingTimeInterval(duration * selectedEndFraction)
        return lower...upper
    }

    private var selectedPointRange: ClosedRange<Int>? {
        guard !preview.points.isEmpty else { return nil }
        let maxIndex = preview.points.count - 1
        let lower = Int(floor(selectedStartFraction * Double(maxIndex)))
        let upper = Int(ceil(selectedEndFraction * Double(maxIndex)))
        let clampedLower = max(0, min(maxIndex, lower))
        let clampedUpper = max(clampedLower, min(maxIndex, upper))
        return clampedLower...clampedUpper
    }

    private var selectedPoints: [GPXTimestampedPoint] {
        if let selectedTimeRange {
            return preview.points(in: selectedTimeRange)
        }
        if let selectedPointRange {
            return preview.points(in: selectedPointRange)
        }
        return preview.points
    }

    private var allCoordinates: [CLLocationCoordinate2D] {
        preview.points.map { point in
            CLLocationCoordinate2D(latitude: point.point.lat, longitude: point.point.lon)
        }
    }

    private var selectedCoordinates: [CLLocationCoordinate2D] {
        selectedPoints.map { point in
            CLLocationCoordinate2D(latitude: point.point.lat, longitude: point.point.lon)
        }
    }

    private var canImportSelection: Bool {
        selectedPoints.count >= 2
    }

    private var summaryText: String {
        if let fullTimeRange = preview.timeRange {
            let duration = fullTimeRange.upperBound.timeIntervalSince(fullTimeRange.lowerBound)
            return L10n.f("%d points, duration: %@", preview.totalPointCount, formattedDuration(duration))
        }
        return L10n.f("%d points (without timestamps)", preview.totalPointCount)
    }

    private var selectionSummaryText: String {
        let base = L10n.f("%d of %d points in import range", selectedPoints.count, preview.totalPointCount)
        if let selectedTimeRange {
            let duration = selectedTimeRange.upperBound.timeIntervalSince(selectedTimeRange.lowerBound)
            return "\(base) (\(formattedDuration(duration)))"
        }
        if let selectedPointRange {
            return L10n.f(
                "%@ (WP %d-%d)",
                base,
                selectedPointRange.lowerBound + 1,
                selectedPointRange.upperBound + 1
            )
        }
        return base
    }

    private var selectedRangeStartText: String {
        if let selectedTimeRange {
            return formattedDate(selectedTimeRange.lowerBound)
        }
        if let selectedPointRange {
            return L10n.f("WP %d", selectedPointRange.lowerBound + 1)
        }
        return L10n.t("WP 1")
    }

    private var selectedRangeEndText: String {
        if let selectedTimeRange {
            return formattedDate(selectedTimeRange.upperBound)
        }
        if let selectedPointRange {
            return L10n.f("WP %d", selectedPointRange.upperBound + 1)
        }
        return L10n.t("WP 1")
    }

    private var mapZoomControls: some View {
        VStack(spacing: 8) {
            Button {
                zoomMap(by: 0.5)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .help(L10n.t("Zoom in"))

            Button {
                zoomMap(by: 2.0)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .help(L10n.t("Zoom out"))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private func zoomMap(by factor: Double) {
        let minDelta = 0.0005
        let maxDelta = 120.0

        var region = visibleRegion
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, minDelta), maxDelta)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, minDelta), maxDelta)
        visibleRegion = region
        cameraPosition = .region(region)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return L10n.t("n/a") }
        return Self.dateFormatter.string(from: date)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let resolved = max(0, duration)
        return Self.durationFormatter.string(from: resolved) ?? String(format: L10n.t("%.0fs"), resolved)
    }

    private static func mapRegion(for points: [GeoPoint]) -> MKCoordinateRegion {
        guard let first = points.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        }

        let latitudes = points.map(\.lat)
        let longitudes = points.map(\.lon)
        let minLat = latitudes.min() ?? first.lat
        let maxLat = latitudes.max() ?? first.lat
        let minLon = longitudes.min() ?? first.lon
        let maxLon = longitudes.max() ?? first.lon

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latDelta = max((maxLat - minLat) * 1.25, 0.01)
        let lonDelta = max((maxLon - minLon) * 1.25, 0.01)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.dropLeading]
        return formatter
    }()

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

struct GPXRangeSelector: View {
    @Binding var startFraction: Double
    @Binding var endFraction: Double

    @State private var startDragOrigin: Double?
    @State private var endDragOrigin: Double?
    @State private var rangeDragOrigin: (Double, Double)?

    private let handleDiameter: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(1, geometry.size.width - handleDiameter)
            let startX = CGFloat(startFraction) * trackWidth + (handleDiameter / 2)
            let endX = CGFloat(endFraction) * trackWidth + (handleDiameter / 2)
            let selectedWidth = max(endX - startX, handleDiameter / 2)
            let selectedMidX = startX + (selectedWidth / 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 8)
                    .padding(.horizontal, handleDiameter / 2)

                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: selectedWidth, height: 8)
                    .position(x: selectedMidX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if rangeDragOrigin == nil {
                                    rangeDragOrigin = (startFraction, endFraction)
                                }

                                guard let origin = rangeDragOrigin else { return }
                                let delta = Double(value.translation.width / trackWidth)
                                let span = origin.1 - origin.0
                                let minStart = 0.0
                                let maxStart = 1.0 - span
                                let clampedStart = min(max(origin.0 + delta, minStart), maxStart)
                                startFraction = clampedStart
                                endFraction = clampedStart + span
                            }
                            .onEnded { _ in
                                rangeDragOrigin = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleDiameter, height: handleDiameter)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .position(x: startX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if startDragOrigin == nil {
                                    startDragOrigin = startFraction
                                }

                                guard let origin = startDragOrigin else { return }
                                let delta = Double(value.translation.width / trackWidth)
                                startFraction = min(max(origin + delta, 0), endFraction)
                            }
                            .onEnded { _ in
                                startDragOrigin = nil
                            }
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: handleDiameter, height: handleDiameter)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .position(x: endX, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if endDragOrigin == nil {
                                    endDragOrigin = endFraction
                                }

                                guard let origin = endDragOrigin else { return }
                                let delta = Double(value.translation.width / trackWidth)
                                endFraction = max(min(origin + delta, 1), startFraction)
                            }
                            .onEnded { _ in
                                endDragOrigin = nil
                            }
                    )
            }
        }
    }
}

import XCTest
@testable import SimctlHelperUI

@MainActor
final class LocationFeatureTests: XCTestCase {
    func testCoordinateFormatterUsesDotSeparator() {
        let value = 52.520008
        let formatted = LocationCommandBuilder.formatCoordinate(value)
        XCTAssertEqual(formatted, "52.520008")
        XCTAssertFalse(formatted.contains(","))
    }

    func testStartArgumentsForIntervalRoute() throws {
        let route = SavedRoute(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Interval Route",
            waypoints: [
                GeoPoint(lat: 37.629538, lon: -122.395733),
                GeoPoint(lat: 40.628083, lon: -73.768254)
            ],
            speedMetersPerSecond: 260,
            updateMode: .interval(seconds: 1)
        )

        let args = try LocationCommandBuilder.startArguments(udid: "DEVICE-UDID", route: route)

        XCTAssertEqual(args[0], "location")
        XCTAssertEqual(args[1], "DEVICE-UDID")
        XCTAssertEqual(args[2], "start")
        XCTAssertEqual(args[3], "--speed=260.0")
        XCTAssertEqual(args[4], "--interval=1.0")
        XCTAssertEqual(args[5], "37.629538,-122.395733")
        XCTAssertEqual(args[6], "40.628083,-73.768254")
    }

    func testStartArgumentsForDistanceRoute() throws {
        let route = SavedRoute(
            name: "Distance Route",
            waypoints: [
                GeoPoint(lat: 48.137154, lon: 11.576124),
                GeoPoint(lat: 52.520008, lon: 13.404954)
            ],
            speedMetersPerSecond: 35,
            updateMode: .distance(meters: 100)
        )

        let args = try LocationCommandBuilder.startArguments(udid: "DEVICE-UDID", route: route)

        XCTAssertTrue(args.contains("--speed=35.0"))
        XCTAssertTrue(args.contains("--distance=100.0"))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("--interval=") }))
    }

    func testStartArgumentsUseStdinMode() throws {
        let route = SavedRoute(
            name: "Stdin Route",
            waypoints: [
                GeoPoint(lat: 48.137154, lon: 11.576124),
                GeoPoint(lat: 52.520008, lon: 13.404954)
            ],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )

        let args = try LocationCommandBuilder.startArguments(
            udid: "DEVICE-UDID",
            route: route,
            waypointInputMode: .stdin
        )

        XCTAssertEqual(args.last, "-")
        XCTAssertFalse(args.contains("48.137154,11.576124"))
    }

    func testWaypointSegmentsReturnsSingleSegmentForSmallRoute() throws {
        let route = SavedRoute(
            name: "Small",
            waypoints: [
                GeoPoint(lat: 48.0, lon: 11.0),
                GeoPoint(lat: 48.1, lon: 11.1),
                GeoPoint(lat: 48.2, lon: 11.2)
            ],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )

        let segments = try LocationCommandBuilder.waypointSegments(
            route: route,
            maxWaypointsPerSegment: 5,
            overlapCount: 1
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], route.waypoints)
    }

    func testWaypointSegmentsUsesOverlapForContinuity() throws {
        let route = SavedRoute(
            name: "Large",
            waypoints: [
                GeoPoint(lat: 1.0, lon: 1.0),
                GeoPoint(lat: 2.0, lon: 2.0),
                GeoPoint(lat: 3.0, lon: 3.0),
                GeoPoint(lat: 4.0, lon: 4.0),
                GeoPoint(lat: 5.0, lon: 5.0)
            ],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )

        let segments = try LocationCommandBuilder.waypointSegments(
            route: route,
            maxWaypointsPerSegment: 3,
            overlapCount: 1
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].map(\.lat), [1.0, 2.0, 3.0])
        XCTAssertEqual(segments[1].map(\.lat), [3.0, 4.0, 5.0])
    }

    func testWaypointSegmentsHandlesSmallMaxSegmentSize() throws {
        let route = SavedRoute(
            name: "Chain",
            waypoints: [
                GeoPoint(lat: 10.0, lon: 10.0),
                GeoPoint(lat: 11.0, lon: 11.0),
                GeoPoint(lat: 12.0, lon: 12.0),
                GeoPoint(lat: 13.0, lon: 13.0)
            ],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )

        let segments = try LocationCommandBuilder.waypointSegments(
            route: route,
            maxWaypointsPerSegment: 2,
            overlapCount: 1
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].map(\.lat), [10.0, 11.0])
        XCTAssertEqual(segments[1].map(\.lat), [11.0, 12.0])
        XCTAssertEqual(segments[2].map(\.lat), [12.0, 13.0])
    }

    func testRouteValidationFailsWithLessThanTwoWaypoints() {
        let route = SavedRoute(
            name: "Broken",
            waypoints: [GeoPoint(lat: 1, lon: 1)],
            speedMetersPerSecond: 20,
            updateMode: .interval(seconds: 1)
        )

        XCTAssertThrowsError(try route.validate())
    }

    func testRouteValidationFailsWithInvalidUpdateValue() {
        let route = SavedRoute(
            name: "Broken",
            waypoints: [
                GeoPoint(lat: 1, lon: 1),
                GeoPoint(lat: 2, lon: 2)
            ],
            speedMetersPerSecond: 20,
            updateMode: .distance(meters: 0)
        )

        XCTAssertThrowsError(try route.validate())
    }

    func testLocationLibraryRoundTrip() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("simctlhelperui-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let store = LocationLibraryStore(baseDirectoryURL: tempRoot)
        let library = LocationLibrary(
            locations: [
                SavedLocation(name: "Munich", point: GeoPoint(lat: 48.137154, lon: 11.576124))
            ],
            routes: [
                SavedRoute(
                    name: "Sample",
                    waypoints: [
                        GeoPoint(lat: 48.137154, lon: 11.576124),
                        GeoPoint(lat: 52.520008, lon: 13.404954)
                    ],
                    speedMetersPerSecond: 30,
                    updateMode: .interval(seconds: 2)
                )
            ],
            defaultLocationID: nil
        )

        try store.save(library)
        let loaded = try store.load()

        XCTAssertEqual(loaded, library)
    }

    func testGPXImportParsesTrackPoints() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>Morning Run</name>
            <trkseg>
              <trkpt lat="48.137154" lon="11.576124"></trkpt>
              <trkpt lat="52.520008" lon="13.404954"></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let route = try GPXRouteImporter.importRoute(from: data, fallbackName: "fallback")

        XCTAssertEqual(route.name, "Morning Run")
        XCTAssertEqual(route.waypoints.count, 2)
        XCTAssertEqual(route.waypoints[0].lat, 48.137154, accuracy: 0.000001)
        XCTAssertEqual(route.waypoints[0].lon, 11.576124, accuracy: 0.000001)
        XCTAssertEqual(route.waypoints[1].lat, 52.520008, accuracy: 0.000001)
        XCTAssertEqual(route.waypoints[1].lon, 13.404954, accuracy: 0.000001)
    }

    func testGPXPreviewParsesTrackPointTimestamps() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>Morning Ride</name>
            <trkseg>
              <trkpt lat="48.137154" lon="11.576124"><time>2026-02-01T10:00:00Z</time></trkpt>
              <trkpt lat="48.147154" lon="11.586124"><time>2026-02-01T10:10:00Z</time></trkpt>
              <trkpt lat="48.157154" lon="11.596124"><time>2026-02-01T10:20:00Z</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let preview = try GPXRouteImporter.preview(from: data, fallbackName: "fallback")

        XCTAssertEqual(preview.name, "Morning Ride")
        XCTAssertEqual(preview.totalPointCount, 3)
        XCTAssertTrue(preview.canSelectTimeRange)
        XCTAssertNotNil(preview.timeRange)
        XCTAssertEqual(preview.points.compactMap(\.timestamp).count, 3)
    }

    func testGPXImportFromSelectedTimeRangeFiltersPoints() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <name>Morning Ride</name>
            <trkseg>
              <trkpt lat="48.137154" lon="11.576124"><time>2026-02-01T10:00:00Z</time></trkpt>
              <trkpt lat="48.147154" lon="11.586124"><time>2026-02-01T10:10:00Z</time></trkpt>
              <trkpt lat="48.157154" lon="11.596124"><time>2026-02-01T10:20:00Z</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let preview = try GPXRouteImporter.preview(from: data, fallbackName: "fallback")
        let parser = ISO8601DateFormatter()
        let selectionStart = try XCTUnwrap(parser.date(from: "2026-02-01T09:59:00Z"))
        let selectionEnd = try XCTUnwrap(parser.date(from: "2026-02-01T10:11:00Z"))

        let route = try preview.route(selectedTimeRange: selectionStart...selectionEnd)

        XCTAssertEqual(route.waypoints.count, 2)
        XCTAssertEqual(route.waypoints[0].lat, 48.137154, accuracy: 0.000001)
        XCTAssertEqual(route.waypoints[1].lat, 48.147154, accuracy: 0.000001)
    }

    func testGPXImportFailsWhenSelectionContainsLessThanTwoPoints() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <trkseg>
              <trkpt lat="48.137154" lon="11.576124"><time>2026-02-01T10:00:00Z</time></trkpt>
              <trkpt lat="48.147154" lon="11.586124"><time>2026-02-01T10:10:00Z</time></trkpt>
              <trkpt lat="48.157154" lon="11.596124"><time>2026-02-01T10:20:00Z</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let preview = try GPXRouteImporter.preview(from: data, fallbackName: "fallback")
        let parser = ISO8601DateFormatter()
        let selectionStart = try XCTUnwrap(parser.date(from: "2026-02-01T10:19:00Z"))
        let selectionEnd = try XCTUnwrap(parser.date(from: "2026-02-01T10:21:00Z"))

        XCTAssertThrowsError(try preview.route(selectedTimeRange: selectionStart...selectionEnd)) { error in
            guard case GPXImportError.noRoutePointsInSelection = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testGPXImportFromSelectedPointRangeWithoutTimestampsFiltersPoints() throws {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Test">
          <trk>
            <trkseg>
              <trkpt lat="48.100000" lon="11.500000"></trkpt>
              <trkpt lat="48.200000" lon="11.600000"></trkpt>
              <trkpt lat="48.300000" lon="11.700000"></trkpt>
              <trkpt lat="48.400000" lon="11.800000"></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """

        let data = try XCTUnwrap(gpx.data(using: .utf8))
        let preview = try GPXRouteImporter.preview(from: data, fallbackName: "fallback")

        XCTAssertFalse(preview.canSelectTimeRange)

        let route = try preview.route(selectedPointRange: 1...2)

        XCTAssertEqual(route.waypoints.count, 2)
        XCTAssertEqual(route.waypoints[0].lat, 48.200000, accuracy: 0.000001)
        XCTAssertEqual(route.waypoints[1].lat, 48.300000, accuracy: 0.000001)
    }
}

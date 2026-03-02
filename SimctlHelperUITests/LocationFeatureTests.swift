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
}

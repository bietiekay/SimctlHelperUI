# SimctlHelperUI

![SimctlHelperUI Icon](screenshot/icon.png)

A macOS SwiftUI application that provides a graphical interface for `xcrun simctl`.
It helps manage iOS simulators and includes a dedicated Location Player for route and location simulation on booted devices.

![SimctlHelperUI Screenshot](screenshot/screenshot12.png)

## Feature Overview

- Device table with sortable columns (name, state, availability, device type, runtime).
- Simulator management:
  - Boot / Shutdown
  - Clone
  - Delete
  - Delete unavailable devices
- Location Player for booted devices:
  - Open from row context menu (`Open Location Player`)
  - Open by double-clicking a booted device row
  - Open from the action panel button on booted selected devices
- Per-device route playback control using `xcrun simctl location`:
  - Play / Pause / Resume / Stop
  - Reset to configured default location
  - Isolated sessions per simulator UDID
- Location and route library management:
  - Saved locations and saved routes
  - Direct rename actions for locations and routes
  - GPX route import
  - Library export/import as JSON
  - Selective import (choose which locations/routes to import)

## Location Player

The Location Player opens in its own window and is bound to a single simulator UDID.

### Window & Refresh Behavior

- The app opens a dedicated main window (`Device Overview`) on launch.
- The `Device Overview` window is no longer forced to the foreground when assigning/opening Location Player windows.
- Opening/focusing a Location Player window no longer restores focus back to the previously active window.
- The `Device Overview` device list refreshes automatically in the background every 10 seconds (non-blocking UI refresh).
- Location Player performs a one-time device status refresh on open.
- Continuous background polling (every few seconds) is currently disabled.
- `Refresh` in the main `Device Overview` toolbar is still available for immediate manual refresh.

### Location Features

- Library actions are split by scope:
  - `+` in the `Locations` section header adds a new saved location
  - Right-click a saved location for `Rename`, `Set Default`, and `Delete`
- Apply a static location with `simctl location <udid> set <lat>,<lon>`
- Rename saved locations
- Edit coordinates manually
- Edit location on map

### Route Features

- Library actions are split by scope:
  - `+` in the `Routes` section header adds a new route
  - Right-click a saved route for `Rename` and `Delete`
- Waypoint-based routes using `simctl location <udid> start ...`
- Rename saved routes
- Route parameters:
  - Speed (`--speed`)
  - Update mode interval (`--interval`) or distance (`--distance`)
- Playback controls:
  - `Play` starts route simulation
  - `Pause/Resume` uses process signals (`SIGSTOP` / `SIGCONT`), including fallback signaling for external `simctl location ... start` processes on long routes
  - `Stop` terminates route process and clears simulated location

### Map Editing

- Click to place points
- Drag-and-drop existing waypoint markers to reposition them
- Numbered waypoint markers
- Add mode toggle with visual state
- Search field above map to jump to places (`MKLocalSearch`)
- Zoom controls (`+` / `-`)

## Library Import/Export

- The app menu (`File`) provides:
  - `Import GPX Route...`
  - `Import Location/Route Library...`
  - `Export Location/Route Library...`
- These menu actions also work when no Location Player window is currently open:
  - A neutral Location Player window is opened/focused automatically
  - The requested import/export flow is then started
- In the selection sheet you can:
  - Select all/none for locations
  - Select all/none for routes
  - Import only chosen entries
- Import behavior:
  - Validates entries before import
  - Preserves existing data
  - Resolves ID collisions by generating new UUIDs

## Requirements

- macOS 14+
- Xcode with Command Line Tools
- iOS Simulator runtimes installed

## Installation

1. Clone repository:
   ```bash
   git clone https://github.com/yourusername/SimctlHelperUI.git
   cd SimctlHelperUI
   ```
2. Open project:
   ```bash
   open SimctlHelperUI.xcodeproj
   ```
3. Build and run (`Cmd+R`).

## Usage

1. Launch SimctlHelperUI.
2. Select a device in the device table.
3. Use the right action panel for clone/boot/shutdown/delete.
4. Open Location Player for booted devices:
   - context menu, or
   - double-click on a selected row (table primary action), or
   - action panel button.
5. In Location Player:
   - manage locations/routes,
   - rename selected locations/routes using `Rename`,
   - import GPX routes,
   - play/pause/resume/stop route playback,
   - export/import full library JSON.

## Architecture

The app follows MVVM.

- Models: simulator and location domain models (`SimctlModels.swift`, `LocationModels.swift`)
- Services:
  - `SimctlService`: command execution and session control for simctl
  - `LocationLibraryStore`: persistence for location/route library
  - `GPXRouteImporter`: GPX parsing into saved routes
- ViewModels:
  - `DeviceListViewModel`
  - `LocationPlayerViewModel`
- Views:
  - Main device list + actions
  - `LocationPlayerView` and map editing sheets

## Recent Changes (Documented)

- UI/UX polish + i18n v1 (DE/EN):
  - Reworked Location Player navigation from mode toggle to persistent sidebar sections (`Locations` + `Routes`) backed by `LibrarySelection`.
  - Migrated large modal workflows (Map Editor, GPX Preview, Library Import Selection) to dedicated resizable auxiliary windows with per-window autosaved frame state.
  - Introduced localization infrastructure (`L10n` + `Localizable.xcstrings`) and migrated visible UI labels, error messages, and generated default names to localized strings.
  - Added German as project localization region and enabled automatic language selection via system locale (`en`/`de`).
  - Refined main window density/spacing and adaptive panel sizing to reduce dead whitespace.
  - Added native minimum-size enforcement for Location Player windows (minimum equals default size) using system window constraints instead of manual resize correction.
  - Added semantic button highlighting for route/location execution controls (`Play/Pause/Resume/Stop`, `Set/Clear/Reset Location`).
  - Cleaned String Catalog metadata to avoid false-positive stale markers when using the `L10n` wrapper pattern.
- Added Location Player access via:
  - booted row context menu,
  - double-click on booted row,
  - action panel button.
- Added robust map workflow for location and waypoint editing.
- Added waypoint drag-and-drop with numbered markers.
- Added map search and zoom controls.
- Added fixed bottom action bar in map editor to keep save/cancel visible.
- Added Add Mode toggle behavior with active highlighting.
- Added GPX route import.
- Added direct rename actions for selected locations and routes in the Location Player library panel.
- Added library JSON export/import with selective import dialog.
- Added ignore rules for Xcode user data (`**/xcuserdata/`, `*.xcuserstate`).
- Fixed long-route playback control so `Pause/Resume` remains usable when `simctl` hands route execution to external processes.
- Changed app startup/main-scene handling to open `Device Overview` as the primary window.
- Removed automatic main-window foreground stealing when Location Player windows are created/updated.
- Reworked main device table open behavior to use table primary action (double-click) instead of per-cell gestures, improving row selection reliability.
- Simplified window focus coordination so main window and Location Player do not fight for key focus after opening/focusing player windows.
- Added non-blocking periodic background refresh for the main device list (10-second interval), while keeping manual refresh support.
- Disabled periodic device polling in Location Player (one-time refresh on open; manual refresh via main window).
- Added app-menu import/export commands for location/route data (File menu), wired to the existing import/export flows.
- Added menu fallback handling so import/export can be triggered even when no Location Player window is open.
- Added explicit `Quit SimctlHelperUI` menu entry and configured app termination when the last window closes.
- Reworked single-location preview map rendering to update pin placement reliably when switching selected locations.
- Fixed a teardown stability issue in tests/preview lifecycle around `LocationPlayerViewModel` observer updates and test service deallocation.

## License

BSD-2-Clause. See [LICENSE.md](LICENSE.md).

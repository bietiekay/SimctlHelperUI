# SimctlHelperUI

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
- Location Player performs a one-time device status refresh on open.
- Continuous background polling (every few seconds) is currently disabled.
- Use `Refresh` in the main `Device Overview` toolbar when you want to refresh the simulator list.

### Location Features

- Apply a static location with `simctl location <udid> set <lat>,<lon>`
- Rename saved locations
- Edit coordinates manually
- Edit location on map

### Route Features

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

- `Export All` writes the full location/route library to one JSON file.
- `Import...` reads a JSON library file and opens a selection sheet.
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
   - double-click on row, or
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
- Disabled periodic device polling in Location Player (one-time refresh on open; manual refresh via main window).

## License

BSD-2-Clause. See [LICENSE.md](LICENSE.md).

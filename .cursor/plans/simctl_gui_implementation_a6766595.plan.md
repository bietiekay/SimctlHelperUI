---
name: Simctl GUI Implementation
overview: Build a macOS SwiftUI app that wraps xcrun simctl commands, providing a GUI for listing, cloning, deleting, and booting/shutting down iOS simulators with sortable device information.
todos:
  - id: "1"
    content: Create SimctlModels.swift with Codable structs for JSON parsing (SimctlListResponse, SimDevice, SimRuntime, SimDeviceType)
    status: completed
  - id: "2"
    content: Create SimctlService.swift with methods to execute xcrun simctl commands (list, clone, delete, boot, shutdown)
    status: completed
  - id: "3"
    content: Create DeviceListViewModel.swift with @Published properties, sorting logic, and action methods
    status: completed
  - id: "4"
    content: Update ContentView.swift with Table view showing devices, sortable columns, and selection handling
    status: completed
  - id: "5"
    content: Create DeviceActionsView.swift for displaying selected device actions (clone, delete, boot/shutdown)
    status: completed
  - id: "6"
    content: Create CloneDeviceView.swift modal for entering new device name when cloning
    status: completed
  - id: "7"
    content: Update app configuration if needed (sandbox settings for xcrun command execution)
    status: completed
isProject: false
---

# SimctlHelperUI Implementation Plan

## Architecture Overview

The app will use a Model-View-ViewModel (MVVM) architecture with:

- **Models**: Device data structures matching the JSON format from `xcrun simctl list -j`
- **Service Layer**: Executes `xcrun simctl` commands and parses JSON responses
- **ViewModels**: Manages device list state, sorting, and actions
- **Views**: SwiftUI interface for displaying devices and actions

## Data Structure

Based on the JSON format, devices are organized by runtime (iOS/watchOS versions). Each device contains:

- `udid`: Unique device identifier
- `name`: Device name
- `state`: "Booted" or "Shutdown"
- `isAvailable`: Boolean availability status
- `deviceTypeIdentifier`: Links to device type info
- `runtimeIdentifier`: Derived from the parent runtime key
- Runtime version info (from runtime object)

## Implementation Steps

### 1. Create Data Models (`SimctlModels.swift`)

Create Swift structs matching the JSON structure:

- `SimctlListResponse`: Root response with devicetypes, runtimes, devices, pairs
- `SimDevice`: Individual device with all properties
- `SimRuntime`: Runtime information (iOS version, etc.)
- `SimDeviceType`: Device type information
- Helper computed properties for display (firmware version, device type name)

### 2. Create Simctl Service (`SimctlService.swift`)

Service class to execute `xcrun simctl` commands:

- `fetchDeviceList()`: Executes `xcrun simctl list -j`, parses JSON, returns `SimctlListResponse`
- `cloneDevice(udid:name:)`: Executes `xcrun simctl clone <udid> <name>`
- `deleteDevice(udid:)`: Executes `xcrun simctl delete <udid>`
- `bootDevice(udid:)`: Executes `xcrun simctl boot <udid>`
- `shutdownDevice(udid:)`: Executes `xcrun simctl shutdown <udid>`
- Error handling for command execution failures

### 3. Create ViewModel (`DeviceListViewModel.swift`)

Observable class managing device list state:

- `@Published var devices: [SimDevice]`: Flattened list of all devices
- `@Published var isLoading: Bool`: Loading state
- `@Published var errorMessage: String?`: Error handling
- `@Published var sortKey: SortKey`: Current sort column
- `@Published var sortOrder: SortOrder`: Ascending/descending
- `selectedDevice: SimDevice?`: Currently selected device
- Methods: `loadDevices()`, `refreshDevices()`, `cloneDevice()`, `deleteDevice()`, `bootDevice()`, `shutdownDevice()`
- Sorting logic for different columns

### 4. Create Main Content View (`ContentView.swift`)

Replace placeholder with:

- Toolbar with refresh button
- Table/List view showing devices with columns:
  - Name
  - State (Booted/Shutdown) with visual indicator
  - Availability (Available/Unavailable)
  - Device Type (e.g., "iPhone 17 Pro")
  - Runtime/Firmware Version (e.g., "iOS 26.2")
- Sortable column headers
- Selection handling
- Action buttons (Clone, Delete, Boot/Shutdown) enabled when device selected

### 5. Create Device Detail/Actions View (`DeviceActionsView.swift`)

Sidebar or bottom panel showing:

- Selected device details
- Action buttons:
  - Clone button → shows text field for new name → executes clone
  - Delete button → shows confirmation dialog → executes delete
  - Boot/Shutdown toggle button (shows "Boot" if shutdown, "Shutdown" if booted)

### 6. Create Clone Dialog (`CloneDeviceView.swift`)

Modal sheet or alert for cloning:

- Text field for new device name
- Validation (non-empty, unique name)
- Cancel/Clone buttons

### 7. Update App Configuration

Ensure app has necessary entitlements:

- May need to disable App Sandbox or add specific entitlements to execute `xcrun` commands
- Check if `ENABLE_APP_SANDBOX = YES` needs to be changed

## File Structure

```
SimctlHelperUI/
├── SimctlHelperUIApp.swift (existing)
├── ContentView.swift (replace)
├── Models/
│   └── SimctlModels.swift (new)
├── Services/
│   └── SimctlService.swift (new)
├── ViewModels/
│   └── DeviceListViewModel.swift (new)
└── Views/
    ├── DeviceActionsView.swift (new)
    └── CloneDeviceView.swift (new)
```

## Key Implementation Details

### JSON Parsing

- Use `JSONDecoder` with `Codable` protocols
- Handle nested structure: devices grouped by runtime identifier
- Flatten devices array for display while preserving runtime info

### Command Execution

- Use `Process` API to execute `xcrun simctl` commands
- Parse stdout/stderr for success/error
- Handle cases where commands fail (device already booted, doesn't exist, etc.)

### UI/UX Considerations

- Show loading indicator while fetching device list
- Display error messages for failed operations
- Auto-refresh device list after clone/delete operations
- Disable actions appropriately (e.g., can't boot already booted device)
- Visual indicators for device state (color coding)

### Sorting

- Support sorting by: Name, State, Availability, Device Type, Runtime Version
- Toggle ascending/descending on column header click
- Maintain sort state across refreshes

## Testing Considerations

- Test with various device states (booted, shutdown, unavailable)
- Test error cases (device not found, invalid names, etc.)
- Test sorting functionality
- Verify command execution works correctly


# planesign_mobile

A Flutter mobile app that connects over Bluetooth Low Energy (BLE) to a Raspberry Pi
("PlaneSign") to read status and send control commands. The Pi exposes a GATT server;
this app is the BLE central/client.

## Build, test, and lint

Requires the Flutter SDK version pinned in `pubspec.yaml` (`flutter: 3.32.4`, Dart `^3.4.0`).

- Install deps: `flutter pub get`
- Analyze/lint: `flutter analyze` (config in `analysis_options.yaml`)
- Format: `dart format .`
- Run: `flutter run`
- Build Android bundle: `flutter build appbundle`
- Regenerate launcher icons after changing `assets/icon/icon.png`: `dart run flutter_launcher_icons`

There is currently no `test/` directory. If you add tests, run the whole suite with
`flutter test` and a single file/test with `flutter test test/foo_test.dart --plain-name "test name"`.
Pure helper functions (e.g. `extractUptimeFromOutput`, `dockerRuntimeDisplayFromRaw`,
`updateCheckDisplayFromRaw`) are the easiest units to cover.

## Architecture

- `lib/main.dart` — app root. Watches `FlutterBluePlus.adapterState` and shows either
  `ScanScreen` (adapter on) or `BluetoothOffScreen`. A `BluetoothAdapterStateObserver`
  auto-pops `DeviceScreen` when the adapter turns off.
- `lib/screens/scan_screen.dart` — scans for devices advertising the PlaneSign master
  service UUID and lists them.
- `lib/screens/device_screen.dart` — the core screen. Connects to a device, discovers
  services, and reads/subscribes to every characteristic. All device features (temperature,
  hostname/IP, uptime, Wi-Fi status/scan/config, Docker container control, version, update
  check, system update + log, reboot) are driven from here.
- `lib/utils/` — BLE helpers (`ble_utils.dart`), a re-emitting stream wrapper +
  string parsing (`utils.dart`), a `BluetoothDevice` connect/disconnect extension with
  connection-state streams (`extra.dart`), and pure "raw string → display model" parsers
  (`docker_status.dart`, `temperature.dart`, `wifi_signal.dart`).
- `lib/widgets/` — reusable BLE tiles (scan result, characteristic, descriptor, system device).

Data flow: the Pi is the source of truth. On connect, `DeviceScreen` discovers services,
reads all readable characteristics, and subscribes to notify/indicate ones. Values are stored
in a `Map<String, String>` keyed by the characteristic's `uuid.str128`. Commands are sent by
writing a UTF-8 encoded string to a control characteristic (e.g. `write(utf8.encode('reboot'))`,
`'update'`, Docker commands). UI cards then re-render from the updated map.

## Related project: the PlaneSign Pi (source of truth for BLE)

This app is the BLE **client**; the Raspberry Pi server lives in the separate repo
[`dmod/PlaneSign`](https://github.com/dmod/PlaneSign). The BLE contract is defined there and
is authoritative — the UUID constants in this app must match it exactly:

- `ble/README.md` — human-readable table of every characteristic: UUID, read/write/notify
  flags, and description. Read this first when adding or changing a feature.
- `ble/planesign_ble.py` — the BlueZ GATT server implementation (`PLANESIGN_MASTER_UUID`,
  each characteristic class's `CHRC_UUID`, and Docker/image constants).

When adding a characteristic here, get its UUID and behavior from those files rather than
inventing one. The GitHub MCP server is configured in `.vscode/mcp.json` — use its
`get_file_contents` / `search_code` tools to fetch the current definitions from `dmod/PlaneSign`.

## Conventions

- **BLE characteristics are addressed by hard-coded UUID constants** declared at the top of
  the screen that uses them (see the `...CharUUID` block in `device_screen.dart` and
  `planesignMasterUUID` in `scan_screen.dart`). These must match the Pi's GATT server exactly.
  Look characteristics up with `findCharacteristicByUuid(_services, uuid)` — it matches both
  128-bit and 16-bit forms case-insensitively.
- **Always key the value map by `characteristic.uuid.str128`** (not `.str`) so lookups by the
  full UUID constant work.
- **Decode incoming bytes** with `decodeBleUtf8String` (allows malformed, strips nulls, trims).
- **Commands are plain UTF-8 strings** written to a control characteristic; device responses
  are strings the parser functions turn into display models. Keep the "raw string → model"
  parsing logic in the `lib/utils/*` pure functions, not in widgets, so it stays testable.
- **Guard async actions**: check the connection is `connected` and use per-action `_isXxxBusy`
  flags to prevent overlapping BLE operations; always reset the flag in `finally`.
- **Connection stability**: `DeviceScreen` auto-reconnects (up to `_maxReconnectAttempts`) via
  `extra.dart`'s `connectAndUpdateStream` / `disconnectAndUpdateStream`. Preserve this pattern
  and always `cancel()` stream subscriptions and timers in `dispose()`.
- **User feedback** goes through `Snackbar.show(ABC.c, ..., success: bool)`, wrapping errors
  with `prettyException(...)`.
- **Lint relaxations** in `analysis_options.yaml` are intentional: `avoid_print` and several
  `prefer_const*` rules are disabled, `use_key_in_widget_constructors` is off, and
  `unnecessary_breaks` is enforced. Don't re-enable them to satisfy analyzer noise.
- **Versioning**: `pubspec.yaml` `version` uses a `major.minor.patch+YYYYMMDDNN` build number.
- **Formatting**: Dart line length is 120 (`.vscode/settings.json`), and format-on-save is on;
  run `dart format .` if editing outside the IDE.

## CI

`.github/workflows/android-release.yml.disabled` is a disabled workflow that builds an Android
App Bundle on push to `main` using the Flutter version from `pubspec.yaml`. Rename it (drop
`.disabled`) to enable release builds.

# LocalDrop

Turn your Android phone into a **local-network file transfer hub**. The app runs
an embedded HTTP server, and any other device on the same Wi-Fi opens a URL in
its browser to **download from** and **upload to** the phone — no app install
needed on the other side.

Everything is bidirectional, PIN-protected, and streams files straight to/from
disk (no full-file buffering), so multi-GB videos transfer fast without spiking
memory.

---

## Features

- **Embedded HTTP server** running inside a foreground service (survives
  backgrounding).
- **Bidirectional transfer** — browser users download single files (with
  HTTP **Range** support for seeking/resume) or a **multi-file ZIP** (built
  on the fly), and upload files via drag-and-drop or a file picker.
- **PIN-based sessions** — a fresh 6-digit PIN is shown on the phone each
  start (toggleable to a fixed PIN). The browser enters it once and gets a
  signed, in-memory session token (cookie + `Authorization` header).
- **QR code** of the connection URL so a laptop/phone can scan-and-connect.
- **Live progress** with speed (MB/s) in both the Flutter app and the web UI,
  via Server-Sent Events.
- **Configurable shared folder** (defaults to an app-owned `LocalDrop`
  folder; changeable with Android's Storage Access Framework picker).
- **Automatic port fallback** if the preferred port is taken.

---

## Architecture

```
Phone (Flutter app)                         Browser on another device
┌───────────────────────────┐              ┌──────────────────────────┐
│ Foreground service isolate │  HTTP/Wi-Fi  │  index.html + app.js      │
│  LocalServer (shelf)      │ ◄──────────► │  • PIN entry              │
│   • AuthManager           │   REST + SSE  │  • File browser + ZIP     │
│   • TransferManager (SSE) │              │  • Drag-drop upload        │
│   • StreamingZipEncoder   │              └──────────────────────────┘
└───────────────────────────┘
        │  sendDataToMain / sendDataToTask
        ▼
  AppController (UI isolate) → Home screen + Settings
```

- **`lib/server/`** — pure-Dart, framework-free code that also runs inside the
  foreground-service isolate (no `rootBundle` dependency):
  - `local_server.dart` — `shelf` + `shelf_router` HTTP server and handlers.
  - `session_manager.dart` — PIN + in-memory token sessions.
  - `transfer_manager.dart` — transfer registry, SSE fan-out, throttled UI
    updates.
  - `zip_encoder.dart` — memory-bounded **streaming** ZIP writer (STORE +
    data descriptors + incremental CRC32), no whole-file buffering.
  - `web_assets.dart` — the browser HTML/CSS/JS embedded as string constants
    (so the non-Flutter service isolate can serve them without `rootBundle`).
- **`lib/services/`** — `foreground_service.dart` (task handler + start
  callback) and `shared_folder.dart` (SAF picker + settings persistence).
- **`lib/state/app_controller.dart`** — `ChangeNotifier` wiring lifecycle,
  network discovery, and task events to the UI.
- **`lib/ui/`** — Material 3 home screen (QR, PIN, transfers, start/stop),
  transfer list, and settings.
- **`assets/web/`** — the same browser files served to clients.

> Why embedded web assets? The foreground service runs in a separate Dart
> isolate where Flutter's `rootBundle` is unavailable. Embedding the three
> web files as Dart string constants keeps the server self-contained.

---

## Build & run

### Prerequisites

- [Flutter](https://flutter.dev) **3.16+** (Dart 3.2+)
- Android SDK (API 21+, target 34) and either a device or emulator on the same
  Wi-Fi you'll test from.
- `flutter_foreground_task` v9 needs **Kotlin 1.9.10+** and **Gradle 8.6+**
  (already set in `android/`).

### Steps

```bash
# 1. Fetch dependencies
flutter pub get

# 2. Make sure the native (Android) scaffold + Gradle wrapper exist.
#    If you cloned just the Dart sources, regenerate the platform project:
flutter create --platforms=android .

# 3. Run on a connected device / emulator
flutter run

# 4. Release APK
flutter build apk --release
```

### Using it

1. Tap **Start Server**. The phone shows the local URL, a QR code, and a 6-digit
   PIN.
2. On another device, open the URL (scan the QR, or type it). Enter the PIN.
3. In the browser: select files → **Download selected as ZIP**, click a file to
   download it, or switch to the **Upload** tab and drag files in.

---

## Android permissions & manifest

Declared in `android/app/src/main/AndroidManifest.xml`:

| Permission | Why |
| --- | --- |
| `INTERNET` | The embedded HTTP server binds a socket. |
| `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` | Local IP discovery (`network_info_plus`). |
| `READ/WRITE_EXTERNAL_STORAGE` (≤ SDK 32/29) | Broad storage access fallback. The default share folder is app-owned (no permission needed); SAF-selected folders are granted via the picker. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` | Required to run the server in a foreground service. |
| `POST_NOTIFICATIONS` (≤ 33) | Show the "server running" notification. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Optional: let the service run long-term. |

The `com.pravera.flutter_foreground_task.service.ForegroundService` entry and
`android:usesCleartextTraffic="true"` (the server is plain HTTP on the LAN) are
also configured.

---

## Regenerating the embedded web assets

If you edit `assets/web/{index.html,styles.css,app.js}`, regenerate the Dart
constants so the server serves your changes:

```bash
python3 tool/gen_web_assets.py   # (or re-run the generator you prefer)
```

`lib/server/web_assets.dart` is generated — keep it in sync with `assets/web`.

---

## Out of scope (future work)

- Internet/relay transfers (this is local-network-only by design — that's the
  speed advantage).
- iOS support.
- User accounts / multiple PINs.
- Hardened multi-client concurrency (a single active browser session is the v1
  target; a second client authenticating will still work but isn't engineered
  around).

## Notes & edge cases handled

- **Port in use** → the server tries the next port automatically.
- **Folder permission denied** → the app shows an error and refuses to start.
- **Very large files** → uploads stream straight to disk; downloads stream
  from the file and support `Range` for resume/seek. Memory stays bounded.
- **Storage full / write error** → transfer is marked failed and reported to
  both the web UI and the phone.

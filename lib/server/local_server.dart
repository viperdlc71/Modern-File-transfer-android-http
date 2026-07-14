import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

import '../models/file_item.dart';
import '../models/transfer.dart';
import 'session_manager.dart';
import 'transfer_manager.dart';
import 'web_assets.dart';
import 'zip_encoder.dart';

/// Embedded HTTP server that runs inside the foreground-service isolate and
/// exposes the shared folder to any browser on the local network.
class LocalServer {
  final SessionManager sessionManager;
  late final TransferManager transferManager;
  String sharedFolder;
  final void Function(Map<String, dynamic> event)? onEvent;

  HttpServer? _server;
  int? port;
  int _counter = 0;

  late final shelf_router.Router _router;

  LocalServer({
    required this.sessionManager,
    required this.sharedFolder,
    this.onEvent,
  }) {
    transferManager = TransferManager(onChanged: reportProgress);
    _router = shelf_router.Router();
    _registerRoutes();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Starts the server on [preferredPort], falling back to the next free port
  /// automatically (handles "port in use" without crashing the app).
  Future<int> start({int preferredPort = 8080, int maxTries = 40}) async {
    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addMiddleware(_authMiddleware())
        .addHandler(_router.call);

    HttpServer? server;
    int? chosen;
    for (int i = 0; i < maxTries; i++) {
      final tryPort = preferredPort + i;
      try {
        server = await shelf_io.serve(handler, InternetAddress.anyIPv4, tryPort);
        chosen = tryPort;
        break;
      } on SocketException {
        if (i == maxTries - 1) rethrow;
      }
    }
    _server = server!;
    // Disable auto-compression: we stream large files directly and don't want
    // shelf to buffer the whole payload in order to compress it.
    _server!.autoCompress = false;
    port = chosen;
    return chosen!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    port = null;
    if (s != null) await s.close(force: true);
    transferManager.dispose();
  }

  // ---------------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------------

  void _registerRoutes() {
    _router.get('/', _indexHandler);
    _router.get('/styles.css', _cssHandler);
    _router.get('/app.js', _jsHandler);
    _router.get('/favicon.ico', _faviconHandler);
    _router.post('/api/auth', _authHandler);
    _router.get('/api/files', _filesHandler);
    _router.get('/api/download/<name>', _downloadHandler);
    _router.get('/api/download-zip', _downloadZipHandler);
    _router.post('/api/upload', _uploadHandler);
    _router.get('/api/progress/<id>', _progressHandler);
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request req) async {
        final path = req.requestedUri.path;
        if (_isPublic(path)) return inner(req);
        final token = extractToken(req.headers);
        if (sessionManager.isValid(token)) return inner(req);
        return shelf.Response(
          401,
          body: jsonErrorBody('unauthorized'),
          headers: _jsonHeaders(),
        );
      };
    };
  }

  bool _isPublic(String path) =>
      path == '/' ||
      path == '/styles.css' ||
      path == '/app.js' ||
      path == '/favicon.ico' ||
      path.startsWith('/api/auth');

  // ---------------------------------------------------------------------------
  // Handlers
  // ---------------------------------------------------------------------------

  shelf.Response _indexHandler(shelf.Request req) => shelf.Response.ok(
        WebAssets.indexHtml,
        headers: {'Content-Type': WebAssets.indexHtmlType},
      );

  shelf.Response _cssHandler(shelf.Request req) => shelf.Response.ok(
        WebAssets.stylesCss,
        headers: {'Content-Type': WebAssets.stylesCssType},
      );

  shelf.Response _jsHandler(shelf.Request req) => shelf.Response.ok(
        WebAssets.appJs,
        headers: {'Content-Type': WebAssets.appJsType},
      );

  shelf.Response _faviconHandler(shelf.Request req) =>
      shelf.Response(204, headers: {'Content-Type': 'image/x-icon'});

  Future<shelf.Response> _authHandler(shelf.Request req) async {
    String? pin;
    try {
      final body =
          jsonDecode(await req.readAsString()) as Map<String, dynamic>;
      pin = body['pin'] as String?;
    } catch (_) {
      pin = null;
    }
    if (pin != null && sessionManager.checkPin(pin)) {
      final token = sessionManager.createSession();
      return shelf.Response.ok(
        jsonEncode({'token': token}),
        headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': sessionCookie(token),
        },
      );
    }
    return shelf.Response(
      401,
      body: jsonErrorBody('bad-pin'),
      headers: _jsonHeaders(),
    );
  }

  Future<shelf.Response> _filesHandler(shelf.Request req) async {
    final dir = Directory(sharedFolder);
    if (!await dir.exists()) {
      return shelf.Response(
        500,
        body: jsonEncode({'error': 'folder-missing', 'path': sharedFolder}),
        headers: _jsonHeaders(),
      );
    }
    final items = <FileItem>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        final stat = await entity.stat();
        items.add(FileItem(
          name: p.basename(entity.path),
          size: stat.size,
          modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
          type: p.extension(entity.path).replaceFirst('.', '').toLowerCase(),
        ));
      }
    }
    items.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return shelf.Response.ok(
      encodeFileItems(items),
      headers: _jsonHeaders(),
    );
  }

  Future<shelf.Response> _downloadHandler(
    shelf.Request req,
    String name,
  ) async {
    final File file;
    try {
      file = _resolve(name);
    } catch (_) {
      return _notFound();
    }
    if (!await file.exists()) return _notFound();
    final stat = await file.stat();
    final id = _newTransferId();
    final transfer = transferManager.create(
      id,
      p.basename(file.path),
      TransferDirection.download,
      totalBytes: stat.size,
    );

    final rangeHeader = req.headers['range'];
    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        final startStr = match.group(1);
        final endStr = match.group(2);
        var start = startStr != null && startStr.isNotEmpty
            ? int.parse(startStr)
            : 0;
        var end = endStr != null && endStr.isNotEmpty
            ? int.parse(endStr)
            : stat.size - 1;
        if (end >= stat.size) end = stat.size - 1;
        if (start > end || start >= stat.size) {
          return shelf.Response(
            416,
            headers: {'Content-Range': 'bytes */${stat.size}'},
          );
        }
        final length = end - start + 1;
        final stream = _track(file.openRead(start, end + 1), transfer);
        return shelf.Response(
          206,
          body: stream,
          headers: {
            'Content-Type': 'application/octet-stream',
            'Content-Length': '$length',
            'Content-Range': 'bytes $start-$end/${stat.size}',
            'Accept-Ranges': 'bytes',
            'Content-Disposition': _attachment(p.basename(file.path)),
            'X-Transfer-Id': id,
          },
        );
      }
    }

    final stream = _track(file.openRead(), transfer);
    return shelf.Response(
      200,
      body: stream,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${stat.size}',
        'Accept-Ranges': 'bytes',
        'Content-Disposition': _attachment(p.basename(file.path)),
        'X-Transfer-Id': id,
      },
    );
  }

  Future<shelf.Response> _downloadZipHandler(shelf.Request req) async {
    final raw = req.url.queryParameters['files'] ?? '';
    final names = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final entries = <(File, String)>[];
    var total = 0;
    for (final n in names) {
      try {
        final f = _resolve(n);
        if (await f.exists()) {
          final s = await f.stat();
          entries.add((f, p.basename(f.path)));
          total += s.size;
        }
      } catch (_) {
        // skip unresolvable / unsafe names
      }
    }
    if (entries.isEmpty) {
      return shelf.Response(
        400,
        body: jsonErrorBody('no-valid-files'),
        headers: _jsonHeaders(),
      );
    }
    final id = _newTransferId();
    final transfer = transferManager.create(
      id,
      'localdrop.zip',
      TransferDirection.download,
      totalBytes: total,
    );
    final controller = StreamController<List<int>>();
    unawaited(_streamZip(entries, controller, transfer));
    return shelf.Response(
      200,
      body: controller.stream,
      headers: {
        'Content-Type': 'application/zip',
        'Content-Disposition': 'attachment; filename="localdrop.zip"',
        'X-Transfer-Id': id,
      },
    );
  }

  Future<void> _streamZip(
    List<(File, String)> entries,
    StreamController<List<int>> controller,
    Transfer transfer,
  ) async {
    try {
      final encoder = StreamingZipEncoder(
        controller,
        onBytes: (bytesWritten) {
          final delta = bytesWritten - transfer.transferredBytes;
          if (delta > 0) transferManager.addBytes(transfer.id, delta);
        },
      );
      for (final (file, name) in entries) {
        final modified = (await file.stat()).modified;
        await encoder.addFile(name, file.openRead(), modified: modified);
      }
      await encoder.close();
      transferManager.complete(transfer.id);
    } catch (e) {
      transferManager.fail(transfer.id, 'zip-error');
      if (!controller.isClosed) controller.close();
    }
  }

  Future<shelf.Response> _uploadHandler(shelf.Request req) async {
    final id = req.url.queryParameters['id'] ?? _newTransferId();
    final contentType = req.headers['content-type'];
    if (contentType == null) {
      return shelf.Response(
        400,
        body: jsonErrorBody('missing-content-type'),
        headers: _jsonHeaders(),
      );
    }
    final boundary = HeaderValue.parse(contentType).parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      return shelf.Response(
        400,
        body: jsonErrorBody('missing-boundary'),
        headers: _jsonHeaders(),
      );
    }

    final transformer = MimeMultipartTransformer(boundary);
    final parts = transformer.bind(req.read());
    String? savedPath;

    await for (final part in parts) {
      final cd = part.headers['content-disposition'];
      if (cd == null) continue;
      final disp = HeaderValue.parse(cd);
      final filename = disp.parameters['filename'];
      if (filename == null || filename.isEmpty) continue;

      final safe = _safeName(filename);
      final target = File(p.join(sharedFolder, safe));
      final transfer = transferManager.create(
        id,
        safe,
        TransferDirection.upload,
      );
      final raf = await target.open(mode: FileMode.write);
      try {
        await for (final chunk in part) {
          if (chunk.isEmpty) continue;
          await raf.writeFrom(chunk);
          transferManager.addBytes(id, chunk.length);
        }
        await raf.close();
      } catch (e) {
        await raf.close().catchError((_) {});
        transferManager.fail(id, 'write-error');
        return shelf.Response(
          500,
          body: jsonErrorBody('write-failed'),
          headers: _jsonHeaders(),
        );
      }
      transferManager.complete(id);
      savedPath = target.path;
    }

    if (savedPath == null) {
      return shelf.Response(
        400,
        body: jsonErrorBody('no-file-part'),
        headers: _jsonHeaders(),
      );
    }
    return shelf.Response.ok(
      jsonEncode({'ok': true, 'path': savedPath}),
      headers: _jsonHeaders(),
    );
  }

  shelf.Response _progressHandler(shelf.Request req, String id) {
    final controller = StreamController<String>();
    Timer? heartbeat;
    void emit(String event) {
      if (!controller.isClosed) controller.add(event);
    }

    void done() {
      heartbeat?.cancel();
      if (!controller.isClosed) controller.close();
    }

    transferManager.subscribe(id, emit, done);
    heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      emit(': ping\n\n');
    });

    final body = controller.stream.map((s) => utf8.encode(s));
    return shelf.Response(
      200,
      body: body,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Resolves a (possibly attacker-supplied) name into a [File] inside the
  /// shared folder, rejecting any path-traversal attempt.
  File _resolve(String name) {
    final clean = name
        .split('/')
        .where((seg) => seg.isNotEmpty && seg != '.' && seg != '..')
        .join('/');
    final full = p.normalize(p.join(sharedFolder, clean));
    final base = p.normalize(sharedFolder);
    if (!full.startsWith('$base${p.separator}') && full != base) {
      throw const FormatException('path traversal');
    }
    return File(full);
  }

  String _safeName(String name) {
    final base = p.basename(name);
    return base.replaceAll(RegExp(r'[^\w.\- ]'), '_');
  }

  Stream<List<int>> _track(
    Stream<List<int>> source,
    Transfer transfer,
  ) async* {
    try {
      await for (final chunk in source) {
        if (chunk.isNotEmpty) {
          transferManager.addBytes(transfer.id, chunk.length);
        }
        yield chunk;
      }
      transferManager.complete(transfer.id);
    } catch (_) {
      transferManager.fail(transfer.id, 'read-error');
    }
  }

  String _newTransferId() {
    _counter++;
    return 't${_counter}_${Random().nextInt(1 << 30)}';
  }

  shelf.Response _notFound() => shelf.Response(
        404,
        body: jsonErrorBody('not-found'),
        headers: _jsonHeaders(),
      );

  Map<String, String> _jsonHeaders() => {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
      };

  String _attachment(String filename) =>
      'attachment; filename="${Uri.encodeComponent(filename)}"';

  void reportProgress() {
    onEvent?.call({
      'type': 'progress',
      'transfers': encodeTransfers(transferManager.snapshot()),
    });
  }
}

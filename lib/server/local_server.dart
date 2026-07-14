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
  final List<String> _logs = [];
  static const int _maxLogs = 500;

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

  void _log(String message) {
    final ts = DateTime.now().toIso8601String();
    _logs.add('[$ts] $message');
    if (_logs.length > _maxLogs) _logs.removeRange(0, _logs.length - _maxLogs);
    stderr.writeln(message);
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
    _router.get('/api/logs', _logsHandler);
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request req) async {
        final path = req.requestedUri.path;
        if (_isPublic(path)) {
          _log('public ${req.method} $path');
          return inner(req);
        }
        final token = extractToken(req.headers);
        if (sessionManager.isValid(token)) {
          _log('auth ok ${req.method} $path');
          return inner(req);
        }
        _log('auth failed ${req.method} $path');
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
      path.startsWith('/api/auth') ||
      path == '/api/logs';

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
      _log('auth success');
      final token = sessionManager.createSession();
      return shelf.Response.ok(
        jsonEncode({'token': token}),
        headers: {
          'Content-Type': 'application/json',
          'Set-Cookie': sessionCookie(token),
        },
      );
    }
    _log('auth failure');
    return shelf.Response(
      401,
      body: jsonErrorBody('bad-pin'),
      headers: _jsonHeaders(),
    );
  }

  Future<shelf.Response> _filesHandler(shelf.Request req) async {
    final rawPath = req.url.queryParameters['path'] ?? '';
    final requested = p.normalize(p.join(sharedFolder, rawPath));
    final base = p.normalize(sharedFolder);
    if (!requested.startsWith(base) && requested != base) {
      return shelf.Response(
        400,
        body: jsonErrorBody('invalid-path'),
        headers: _jsonHeaders(),
      );
    }
    final dir = Directory(requested);
    if (!await dir.exists()) {
      return shelf.Response(
        404,
        body: jsonErrorBody('folder-not-found'),
        headers: _jsonHeaders(),
      );
    }
    final items = <FileItem>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is File) {
        final stat = await entity.stat();
        items.add(FileItem(
          name: name,
          size: stat.size,
          modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
          type: p.extension(entity.path).replaceFirst('.', '').toLowerCase(),
          path: rawPath,
        ));
      } else if (entity is Directory) {
        items.add(FileItem(
          name: name,
          size: 0,
          modifiedSeconds: 0,
          type: 'dir',
          isDirectory: true,
          path: rawPath,
        ));
      }
    }
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _log('files listed path=${rawPath.isEmpty ? '/' : rawPath} count=${items.length}');
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
      _log('download not-found name=$name');
      return _notFound();
    }
    if (!await file.exists()) {
      _log('download missing name=$name');
      return _notFound();
    }
    final stat = await file.stat();
    final id = _newTransferId();
    final transfer = transferManager.create(
      id,
      p.basename(file.path),
      TransferDirection.download,
      totalBytes: stat.size,
    );
    _log('download started id=$id name=${p.basename(file.path)} size=${stat.size}');

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
          _log('download range-invalid id=$id name=${p.basename(file.path)}');
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
    _log('zip requested names=${names.join(',')}');
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
      _log('zip no-valid-files');
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
    _log('zip started id=$id entries=${entries.length} total=$total');
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
      _log('zip completed id=${transfer.id} bytes=${transfer.transferredBytes}');
    } catch (e) {
      transferManager.fail(transfer.id, 'zip-error');
      _log('zip error id=${transfer.id}: $e');
      if (!controller.isClosed) controller.close();
    }
  }

  Future<shelf.Response> _uploadHandler(shelf.Request req) async {
    final id = req.url.queryParameters['id'] ?? _newTransferId();
    _log('upload started id=$id');
    final contentType = req.headers['content-type'];
    if (contentType == null) {
      _log('upload missing-content-type id=$id');
      return shelf.Response(
        400,
        body: jsonErrorBody('missing-content-type'),
        headers: _jsonHeaders(),
      );
    }
    final boundary = HeaderValue.parse(contentType).parameters['boundary'];
    if (boundary == null || boundary.isEmpty) {
      _log('upload missing-boundary id=$id');
      return shelf.Response(
        400,
        body: jsonErrorBody('missing-boundary'),
        headers: _jsonHeaders(),
      );
    }

    final transformer = MimeMultipartTransformer(boundary);
    final parts = transformer.bind(req.read());
    String? savedPath;
    String? savedName;

    try {
      await for (final part in parts) {
        final cd = part.headers['content-disposition'];
        if (cd == null) continue;
        final disp = HeaderValue.parse(cd);
        final filename = disp.parameters['filename'];
        if (filename == null || filename.isEmpty) continue;

        final rawName = p.basename(filename);
        final safe = _safeName(rawName);
        savedName = safe;
        final target = File(p.join(sharedFolder, safe));
        final transfer = transferManager.create(
          id,
          safe,
          TransferDirection.upload,
        );
        _log('upload file id=$id name=$safe');
        final raf = await target.open(mode: FileMode.write);
        try {
          var totalBytes = 0;
          await for (final chunk in part) {
            if (chunk.isEmpty) continue;
            await raf.writeFrom(chunk);
            totalBytes += chunk.length;
            transferManager.addBytes(id, chunk.length);
          }
          await raf.close();
          _log('upload file-written id=$id name=$safe bytes=$totalBytes');
        } catch (e) {
          await raf.close().catchError((_) {});
          transferManager.fail(id, 'write-error');
          _log('upload write-error id=$id name=$safe: $e');
          return shelf.Response(
            500,
            body: jsonErrorBody('write-failed'),
            headers: _jsonHeaders(),
          );
        }
        transferManager.complete(id);
        savedPath = target.path;
      }
    } on SocketException catch (e) {
      _log('upload socket-error id=$id name=$savedName: $e');
      return shelf.Response(
        500,
        body: jsonErrorBody('connection-lost'),
        headers: _jsonHeaders(),
      );
    } on FormatException catch (e) {
      _log('upload format-error id=$id name=$savedName: $e');
      return shelf.Response(
        400,
        body: jsonErrorBody('invalid-filename'),
        headers: _jsonHeaders(),
      );
    } catch (e) {
      _log('upload unexpected-error id=$id name=$savedName: $e');
      return shelf.Response(
        500,
        body: jsonErrorBody('upload-failed'),
        headers: _jsonHeaders(),
      );
    }

    if (savedPath == null) {
      _log('upload no-file-part id=$id');
      return shelf.Response(
        400,
        body: jsonErrorBody('no-file-part'),
        headers: _jsonHeaders(),
      );
    }
    _log('upload completed id=$id path=$savedPath');
    return shelf.Response.ok(
      jsonEncode({'ok': true, 'path': savedPath}),
      headers: _jsonHeaders(),
    );
  }

  shelf.Response _logsHandler(shelf.Request req) {
    final lines = _logs.join('\n');
    return shelf.Response.ok(
      lines,
      headers: {'Content-Type': 'text/plain; charset=utf-8'},
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

  Directory _resolveDir(String name) {
    final clean = name
        .split('/')
        .where((seg) => seg.isNotEmpty && seg != '.' && seg != '..')
        .join('/');
    final full = p.normalize(p.join(sharedFolder, clean));
    final base = p.normalize(sharedFolder);
    if (!full.startsWith('$base${p.separator}') && full != base) {
      throw const FormatException('path traversal');
    }
    return Directory(full);
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
      _log('download completed id=${transfer.id} name=${transfer.fileName} bytes=${transfer.transferredBytes}');
    } on SocketException catch (e) {
      transferManager.fail(transfer.id, 'connection-lost');
      _log('download aborted id=${transfer.id} name=${transfer.fileName}: $e');
    } catch (e) {
      transferManager.fail(transfer.id, 'read-error');
      _log('download error id=${transfer.id} name=${transfer.fileName}: $e');
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

  String _attachment(String filename) {
    final encoded = Uri.encodeComponent(filename).replaceAll("'", "%27");
    final sanitized = filename.replaceAll(RegExp(r'[^\x00-\x7F]'), '?').replaceAll('"', "'");
    return 'attachment; filename="$sanitized"; filename*=UTF-8\'\'$encoded';
  }

  void reportProgress() {
    onEvent?.call({
      'type': 'progress',
      'transfers': encodeTransfers(transferManager.snapshot()),
    });
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// A streaming ZIP writer that emits a STORE (no compression) archive without
/// buffering whole files in memory — each file's bytes are streamed straight
/// to the [sink] as they arrive, so multi-GB files transfer without spiking
/// memory. Uses ZIP data descriptors so the (unknown) sizes/CRC are written
/// after each file's payload.
class StreamingZipEncoder {
  final StreamSink<List<int>> _sink;
  final void Function(int totalBytesWritten)? onBytes;

  final List<int> _buf = <int>[];
  int _offset = 0;
  int _totalWritten = 0;
  final List<_CentralRecord> _centrals = [];
  final int _flushThreshold;

  StreamingZipEncoder(
    this._sink, {
    this.onBytes,
    int flushThreshold = 64 * 1024,
  }) : _flushThreshold = flushThreshold;

  /// Adds a single file from a byte stream. [name] is the entry path inside the
  /// archive (use `/` separators). [modified] drives the DOS timestamp.
  Future<void> addFile(
    String name,
    Stream<List<int>> content, {
    DateTime? modified,
  }) async {
    final nameBytes = utf8.encode(name);
    final localOffset = _offset;
    final crc = _Crc32();
    int size = 0;

    final header = <int>[];
    _w32(header, 0x04034b50); // local file header signature
    _w16(header, 20); // version needed to extract
    _w16(header, 0x0008); // general purpose flag (bit 3: data descriptor)
    _w16(header, 0); // compression method = store
    final dos = _dosDateTime((modified ?? DateTime.now()).toLocal());
    _w16(header, dos.time);
    _w16(header, dos.date);
    _w32(header, 0); // crc-32 (filled in data descriptor)
    _w32(header, 0); // compressed size (data descriptor)
    _w32(header, 0); // uncompressed size (data descriptor)
    _w16(header, nameBytes.length);
    _w16(header, 0); // extra field length
    header.addAll(nameBytes);
    _write(header);

    await for (final chunk in content) {
      if (chunk.isEmpty) continue;
      crc.add(chunk);
      size += chunk.length;
      _write(chunk);
      await _drain();
    }

    final descriptor = <int>[];
    _w32(descriptor, 0x08074b50); // data descriptor signature
    _w32(descriptor, crc.value);
    _w32(descriptor, size); // compressed size (store)
    _w32(descriptor, size); // uncompressed size
    _write(descriptor);

    _centrals.add(_CentralRecord(
      nameBytes: nameBytes,
      crc: crc.value,
      size: size,
      localOffset: localOffset,
      time: dos.time,
      date: dos.date,
    ));
  }

  /// Finalises the archive: writes the central directory and the
  /// end-of-central-directory record, then closes the sink.
  Future<void> close() async {
    final centralStart = _offset;
    final central = <int>[];
    for (final c in _centrals) {
      _w32(central, 0x02014b50); // central directory file header
      _w16(central, 20); // version made by
      _w16(central, 20); // version needed
      _w16(central, 0x0008);
      _w16(central, 0); // method = store
      _w16(central, c.time);
      _w16(central, c.date);
      _w32(central, c.crc);
      _w32(central, c.size);
      _w32(central, c.size);
      _w16(central, c.nameBytes.length);
      _w16(central, 0); // extra field length
      _w16(central, 0); // file comment length
      _w16(central, 0); // disk number start
      _w16(central, 0); // internal file attributes
      _w32(central, 0); // external file attributes
      _w32(central, c.localOffset);
      central.addAll(c.nameBytes);
    }
    _write(central);
    final centralSize = _offset - centralStart;

    final eocd = <int>[];
    _w32(eocd, 0x06054b50); // end of central directory signature
    _w16(eocd, 0); // number of this disk
    _w16(eocd, 0); // disk with start of central directory
    _w16(eocd, _centrals.length); // central dir records on this disk
    _w16(eocd, _centrals.length); // total central dir records
    _w32(eocd, centralSize);
    _w32(eocd, centralStart);
    _w16(eocd, 0); // comment length
    _write(eocd);

    await _drain(force: true);
    await _sink.close();
  }

  void _write(List<int> bytes) {
    if (bytes.isEmpty) return;
    _buf.addAll(bytes);
    _offset += bytes.length;
    _totalWritten += bytes.length;
    onBytes?.call(_totalWritten);
  }

  Future<void> _drain({bool force = false}) async {
    if (_buf.isEmpty) return;
    if (!force && _buf.length < _flushThreshold) return;
    final out = Uint8List.fromList(_buf);
    _buf.clear();
    await _sink.add(out);
  }
}

class _CentralRecord {
  final List<int> nameBytes;
  final int crc;
  final int size;
  final int localOffset;
  final int time;
  final int date;
  _CentralRecord({
    required this.nameBytes,
    required this.crc,
    required this.size,
    required this.localOffset,
    required this.time,
    required this.date,
  });
}

void _w32(List<int> b, int v) {
  b.addAll([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
}

void _w16(List<int> b, int v) {
  b.addAll([v & 0xff, (v >> 8) & 0xff]);
}

/// DOS date/time from a [DateTime] (local).
({int time, int date}) _dosDateTime(DateTime dt) {
  final time = ((dt.hour & 0x1f) << 11) |
      ((dt.minute & 0x3f) << 5) |
      ((dt.second ~/ 2) & 0x1f);
  final date = (((dt.year - 1980) & 0x7f) << 9) |
      ((dt.month & 0xf) << 5) |
      (dt.day & 0x1f);
  return (time: time, date: date);
}

/// Incremental CRC-32 (IEEE 802.3) implementation — no whole-file buffering.
class _Crc32 {
  int _crc = 0xFFFFFFFF;

  void add(List<int> bytes) {
    for (final b in bytes) {
      _crc = _crcTable[(_crc ^ b) & 0xff] ^ (_crc >> 8);
    }
  }

  int get value => _crc ^ 0xFFFFFFFF;
}

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  const poly = 0xEDB88320;
  final table = List<int>.filled(256, 0);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) == 1 ? (poly ^ (c >> 1)) : (c >> 1);
    }
    table[n] = c;
  }
  return table;
}

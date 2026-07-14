import 'dart:convert';
import 'dart:math';

/// Holds the active PIN and issues in-memory session tokens.
///
/// Tokens are simple random opaque strings stored in memory for the lifetime
/// of the server process. No JWT / signing complexity is needed for a local
/// network utility.
class SessionManager {
  final String pin;
  final Duration sessionTtl;
  final Map<String, DateTime> _sessions = {};

  SessionManager(
    this.pin, {
    this.sessionTtl = const Duration(hours: 12),
  });

  static String generatePin() {
    final rnd = Random.secure();
    return (100000 + rnd.nextInt(900000)).toString();
  }

  bool checkPin(String pin) => pin == this.pin;

  String createSession() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final token = base64Url.encode(bytes);
    _sessions[token] = DateTime.now().add(sessionTtl);
    return token;
  }

  bool isValid(String? token) {
    if (token == null || token.isEmpty) return false;
    final expiry = _sessions[token];
    if (expiry == null) return false;
    if (expiry.isBefore(DateTime.now())) {
      _sessions.remove(token);
      return false;
    }
    return true;
  }

  void revoke(String token) => _sessions.remove(token);

  void clear() => _sessions.clear();

  int get activeSessionCount => _sessions.length;
}

/// Extracts a session token from a request, looking at the `Authorization`
/// header first, then the `localdrop_session` cookie.
String? extractToken(Map<String, String> headers) {
  final auth = headers['authorization'];
  if (auth != null && auth.toLowerCase().startsWith('bearer ')) {
    return auth.substring(7).trim();
  }
  final cookie = headers['cookie'];
  if (cookie != null) {
    for (final part in cookie.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2 && kv[0] == 'localdrop_session') {
        return kv[1];
      }
    }
  }
  return null;
}

/// Builds the Set-Cookie header value for a freshly issued token.
String sessionCookie(String token) =>
    'localdrop_session=$token; Path=/; Max-Age=43200; HttpOnly; SameSite=Lax';

/// Convenience JSON error body helper.
List<int> jsonErrorBody(String error) =>
    utf8.encode(jsonEncode({'error': error}));

import 'dart:io';

/// Holds a client certificate configured before the user has logged in.
/// Used when the Jellyfin server requires mTLS on all endpoints including
/// the public info API, preventing a chicken-and-egg problem where we
/// need to test the server URL before we have a user record.
class PreLoginCertificate {
  static String? path;
  static String? password;
  static String? name;

  static bool get isConfigured => path != null && password != null;

  static SecurityContext? createSecurityContext() {
    if (path == null || password == null) return null;
    return SecurityContext(withTrustedRoots: true)
      ..useCertificateChain(path!, password: password)
      ..usePrivateKey(path!, password: password);
  }

  static void clear() {
    path = null;
    password = null;
    name = null;
  }
}

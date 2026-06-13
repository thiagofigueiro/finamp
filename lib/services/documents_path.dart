/// Cached path to the application documents directory.
/// Set during app initialization so it's available synchronously
/// everywhere, including in SecurityContext creation which runs
/// in synchronous constructors.
String? cachedDocumentsPath;

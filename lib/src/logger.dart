import 'downloader.dart';

enum DownloadManagerLogLevel {
  none,
  warning,
  debug,
  verbose,
}

class DownloadLogger {
  void log(String message, DownloadManagerLogLevel level) {
    if (DownloadManager.logLevel.index >= level.index) {
      print(message);
    }
  }

  void warning(String message) {
    if (DownloadManager.logLevel.index >=
        DownloadManagerLogLevel.warning.index) {
      print(message);
    }
  }

  void debug(String message) {
    if (DownloadManager.logLevel.index >= DownloadManagerLogLevel.debug.index) {
      print(message);
    }
  }

  void verbose(String message) {
    if (DownloadManager.logLevel.index >=
        DownloadManagerLogLevel.verbose.index) {
      print(message);
    }
  }
}

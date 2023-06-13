enum DownloadStatus { queued, downloading, completed, failed, paused, canceled }

extension DownloadStatusExtension on DownloadStatus {
  bool get isCompleted {
    switch (this) {
      case DownloadStatus.completed:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        return true;
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
      case DownloadStatus.paused:
        return false;
    }
  }

  bool get isInactive {
    switch (this) {
      case DownloadStatus.paused:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        return true;
      case DownloadStatus.completed:
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return false;
    }
  }
}

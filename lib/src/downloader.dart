import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:collection/collection.dart';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_download_manager/flutter_download_manager.dart';

import 'logger.dart';

class DownloadManager {
  static DownloadManagerLogLevel logLevel = DownloadManagerLogLevel.none;
  final _log = DownloadLogger();

  final _cache = <String, DownloadTask>{};
  final _queue = Queue<DownloadRequest>();
  final dio = Dio();
  static const partialExtension = ".partial";
  static const tempExtension = ".temp";

  final urlsAdded = StreamController<String>();
  final urlsRemoved = StreamController<String>();

  int maxConcurrentTasks = 2;
  final _runningTasks = <String>{};

  static final DownloadManager _dm = new DownloadManager._internal();

  DownloadManager._internal() {
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      logPrint: _log.debug,
      retries: 3, // number of retries before a failure
      retryDelays: const [
        Duration(seconds: 1), // wait 1 sec before first retry
        Duration(seconds: 2), // wait 2 sec before second retry
        Duration(seconds: 3), // wait 3 sec before third retry
      ],
    ));
  }

  factory DownloadManager({int? maxConcurrentTasks}) {
    if (maxConcurrentTasks != null) {
      _dm.maxConcurrentTasks = maxConcurrentTasks;
    }
    return _dm;
  }

  void Function(int, int) createCallback(url, int partialFileLength) =>
      (int received, int total) {
        getDownload(url)?.progress.value =
            (received + partialFileLength) / (total + partialFileLength);

        if (total == -1) {}
      };

  Future<void> download(String url, String savePath, cancelToken,
      {forceDownload = false}) async {
    late String partialFilePath;
    late File partialFile;
    try {
      var task = getDownload(url);

      if (task == null || task.status.value == DownloadStatus.canceled) {
        _log.warning('task not found for url: $url');
        return;
      }
      setStatus(task, DownloadStatus.downloading);

      _log.debug('start download url: $url');

      var file = File(savePath.toString());
      partialFilePath = savePath + partialExtension;
      partialFile = File(partialFilePath);

      var fileExist = await file.exists();
      var partialFileExist = await partialFile.exists();

      if (fileExist) {
        _log.debug("file exists");
        setStatus(task, DownloadStatus.completed);
      } else if (partialFileExist) {
        _log.debug("partial file exists");

        var partialFileLength = await partialFile.length();

        var response = await dio.download(
          url,
          partialFilePath + tempExtension,
          onReceiveProgress: createCallback(url, partialFileLength),
          options: Options(
            headers: {HttpHeaders.rangeHeader: 'bytes=$partialFileLength-'},
          ),
          cancelToken: cancelToken,
          deleteOnError: true,
        );

        if (response.statusCode == HttpStatus.partialContent) {
          var ioSink = partialFile.openWrite(mode: FileMode.writeOnlyAppend);
          var _f = File(partialFilePath + tempExtension);
          await ioSink.addStream(_f.openRead());
          await _f.delete();
          await ioSink.close();
          await partialFile.rename(savePath);

          setStatus(task, DownloadStatus.completed);
        }
      } else {
        var response = await dio.download(
          url,
          partialFilePath,
          onReceiveProgress: createCallback(url, 0),
          cancelToken: cancelToken,
          deleteOnError: false,
        );

        if (response.statusCode == HttpStatus.ok) {
          _log.debug("download completed successfully");
          await partialFile.rename(savePath);
          setStatus(task, DownloadStatus.completed);
        } else {
          _log.debug("download failed: ${response.statusCode}");
          setStatus(task, DownloadStatus.failed);
        }
      }
    } catch (e) {
      var task = getDownload(url);
      if (task == null) {
        _log.debug("download stopped: task not found (deleted?)");
      } else if (task.status.value != DownloadStatus.canceled &&
          task.status.value != DownloadStatus.paused) {
        _log.warning("download failed: $e");
        setStatus(task, DownloadStatus.failed);
        _runningTasks.remove(url);

        _startExecution();

        rethrow;
      } else if (task.status.value == DownloadStatus.paused) {
        _log.debug("download stopped: task was paused");
        final ioSink = partialFile.openWrite(mode: FileMode.writeOnlyAppend);
        final f = File(partialFilePath + tempExtension);
        if (await f.exists()) {
          await ioSink.addStream(f.openRead());
        }
        await ioSink.close();
      }
    }

    _runningTasks.remove(url);
    _startExecution();
  }

  void disposeNotifiers(DownloadTask task) {
    // task.status.dispose();
    // task.progress.dispose();
  }

  void setStatus(DownloadTask task, DownloadStatus status) {
    task.status.value = status;

    if (status.isCompleted) {
      disposeNotifiers(task);
    }
  }

  DownloadTask addDownload(String url, String savedDir) {
    assert(url.isNotEmpty);

    if (savedDir.isEmpty) {
      savedDir = ".";
    }

    _log.debug("add download url: $url, savedDir: $savedDir");

    var isDirectory = Directory(savedDir).existsSync();
    var downloadFilename = isDirectory
        ? savedDir + Platform.pathSeparator + getFileNameFromUrl(url)
        : savedDir;

    return _addDownloadRequest(DownloadRequest(url, downloadFilename));
  }

  DownloadTask _addDownloadRequest(DownloadRequest downloadRequest) {
    var task = _cache[downloadRequest.url];
    if (task != null) {
      // do nothing if request is the same and download is not completed
      if (task.request == downloadRequest && !task.status.value.isCompleted) {
        return task;
      }
      _removeDownloadRequest(task);
    }

    final request = DownloadRequest(downloadRequest.url, downloadRequest.path);
    task = DownloadTask(request);
    _queue.add(request);

    _cache[downloadRequest.url] = task;

    _startExecution();

    urlsAdded.add(downloadRequest.url);

    return task;
  }

  void _removeDownloadRequest(DownloadTask task) {
    task.request.cancelToken.cancel();
    _queue.remove(task);
    _runningTasks.remove(task.request.url);
  }

  void pauseDownload(String url) {
    _log.debug("pause download url: $url");

    var task = getDownload(url);
    if (task == null) {
      return;
    }

    setStatus(task, DownloadStatus.paused);
    _removeDownloadRequest(task);
  }

  void cancelDownload(String url) {
    _log.debug("cancel download url: $url");

    var task = getDownload(url);
    if (task == null) {
      return;
    }

    setStatus(task, DownloadStatus.canceled);
    _removeDownloadRequest(task);
  }

  void resumeDownload(String url) {
    print("resume download url: $url");

    var task = getDownload(url);
    if (task == null) {
      return;
    }

    setStatus(task, DownloadStatus.queued);
    task.request.cancelToken = CancelToken();
    _queue.add(task.request);

    _startExecution();
  }

  void removeDownload(String url) {
    print("remove download url: $url");

    cancelDownload(url);
    _cache.remove(url);
    urlsRemoved.add(url);
  }

  // Do not immediately call getDownload After addDownload, rather use the returned DownloadTask from addDownload
  DownloadTask? getDownload(String url) {
    return _cache[url];
  }

  Future<DownloadStatus> whenDownloadComplete(
    DownloadTask task, {
    Duration timeout = const Duration(hours: 2),
  }) async =>
      task.whenDownloadComplete(timeout: timeout);

  List<DownloadTask> getAllDownloads() => _cache.values.toList();

  // Batch Download Mechanism
  void addBatchDownloads(List<String> urls, String savedDir) {
    urls.forEach((url) {
      addDownload(url, savedDir);
    });
  }

  List<DownloadTask?> getBatchDownloads(List<String> urls) =>
      urls.map((e) => _cache[e]).toList();

  void pauseBatchDownloads(List<String> urls) {
    urls.forEach((element) {
      pauseDownload(element);
    });
  }

  void cancelBatchDownloads(List<String> urls) {
    urls.forEach((element) {
      cancelDownload(element);
    });
  }

  void resumeBatchDownloads(List<String> urls) {
    urls.forEach((element) {
      resumeDownload(element);
    });
  }

  ValueNotifier<double> getBatchDownloadProgress(List<String> urls) {
    ValueNotifier<double> progress = ValueNotifier(0);
    var total = urls.length;

    if (total == 0) {
      return progress;
    }

    if (total == 1) {
      return getDownload(urls.first)?.progress ?? progress;
    }

    var progressMap = Map<String, double>();

    urls.forEach((url) {
      var task = getDownload(url);

      if (task != null) {
        progressMap[url] = 0.0;

        if (task.status.value.isCompleted) {
          progressMap[url] = 1.0;
          progress.value = progressMap.values.sum / total;
        }

        var progressListener;
        progressListener = () {
          progressMap[url] = task.progress.value;
          progress.value = progressMap.values.sum / total;
        };

        task.progress.addListener(progressListener);

        var listener;
        listener = () {
          if (task.status.value.isCompleted) {
            progressMap[url] = 1.0;
            progress.value = progressMap.values.sum / total;
            task.status.removeListener(listener);
            task.progress.removeListener(progressListener);
          }
        };

        task.status.addListener(listener);
      } else {
        total--;
      }
    });

    return progress;
  }

  Future<bool> whenBatchDownloadsComplete(
    List<DownloadTask> tasks, {
    Duration timeout = const Duration(hours: 2),
  }) async {
    var completer = Completer<bool>();

    var completed = 0;
    var total = tasks.length;

    for (final task in tasks) {
      if (task.status.value.isCompleted) {
        completed++;
        if (completed >= total) {
          completer.complete(true);
          break;
        }
      }

      var listener;
      listener = () {
        if (task.status.value.isDownloadFinished) {
          task.status.removeListener(listener);

          completed++;
          if (completed >= total) {
            completer.complete(true);
          }
        }
      };

      task.status.addListener(listener);
    }

    return completer.future.timeout(timeout);
  }

  void _startExecution() async {
    if (_runningTasks.length >= maxConcurrentTasks || _queue.isEmpty) {
      return;
    }

    while (_queue.isNotEmpty && _runningTasks.length < maxConcurrentTasks) {
      var currentRequest = _queue.removeFirst();

      _runningTasks.add(currentRequest.url);

      _log.debug('Concurrent workers: ${_runningTasks.length}');
      _log.verbose('Active downloads:');
      for (var url in _runningTasks) {
        _log.verbose('- $url');
      }

      download(
        currentRequest.url,
        currentRequest.path,
        currentRequest.cancelToken,
      );

      await Future.delayed(Duration(milliseconds: 500), null);
    }
  }

  /// This function is used for get file name with extension from url
  String getFileNameFromUrl(String url) => url.split('/').last;
}

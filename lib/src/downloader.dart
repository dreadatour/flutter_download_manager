import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:collection/collection.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_download_manager/flutter_download_manager.dart';

class DownloadManager {
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

  DownloadManager._internal();

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
        return;
      }
      setStatus(task, DownloadStatus.downloading);

      if (kDebugMode) {
        print(url);
      }
      var file = File(savePath.toString());
      partialFilePath = savePath + partialExtension;
      partialFile = File(partialFilePath);

      var fileExist = await file.exists();
      var partialFileExist = await partialFile.exists();

      if (fileExist) {
        if (kDebugMode) {
          print("File Exists");
        }
        setStatus(task, DownloadStatus.completed);
      } else if (partialFileExist) {
        if (kDebugMode) {
          print("Partial File Exists");
        }

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
          await partialFile.rename(savePath);
          setStatus(task, DownloadStatus.completed);
        }
      }
    } catch (e) {
      var task = getDownload(url);
      if (task == null) {
        return;
      }

      if (task.status.value != DownloadStatus.canceled &&
          task.status.value != DownloadStatus.paused) {
        setStatus(task, DownloadStatus.failed);
        _runningTasks.remove(url);

        _startExecution();

        rethrow;
      } else if (task.status.value == DownloadStatus.paused) {
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

  Future<DownloadTask> addDownload(String url, String savedDir) async {
    assert(url.isNotEmpty);

    if (savedDir.isEmpty) {
      savedDir = ".";
    }

    var isDirectory = await Directory(savedDir).exists();
    var downloadFilename = isDirectory
        ? savedDir + Platform.pathSeparator + getFileNameFromUrl(url)
        : savedDir;

    return _addDownloadRequest(DownloadRequest(url, downloadFilename));
  }

  Future<DownloadTask> _addDownloadRequest(
    DownloadRequest downloadRequest,
  ) async {
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

  Future<void> pauseDownload(String url) async {
    if (kDebugMode) {
      print("Pause Download");
    }

    var task = getDownload(url);
    if (task == null) {
      return;
    }

    setStatus(task, DownloadStatus.paused);
    _removeDownloadRequest(task);
  }

  Future<void> cancelDownload(String url) async {
    if (kDebugMode) {
      print("Cancel Download");
    }

    var task = getDownload(url);
    if (task == null) {
      return;
    }

    setStatus(task, DownloadStatus.canceled);
    _removeDownloadRequest(task);
  }

  Future<void> resumeDownload(String url) async {
    if (kDebugMode) {
      print("Resume Download");
    }

    var task = getDownload(url);
    if (task == null) {
      return;
    }

    setStatus(task, DownloadStatus.queued);
    task.request.cancelToken = CancelToken();
    _queue.add(task.request);

    _startExecution();
  }

  Future<void> removeDownload(String url) async {
    cancelDownload(url);
    _cache.remove(url);
    urlsRemoved.add(url);
  }

  // Do not immediately call getDownload After addDownload, rather use the returned DownloadTask from addDownload
  DownloadTask? getDownload(String url) {
    return _cache[url];
  }

  Future<DownloadStatus> whenDownloadComplete(String url,
      {Duration timeout = const Duration(hours: 2)}) async {
    var task = getDownload(url);

    if (task != null) {
      return task.whenDownloadComplete(timeout: timeout);
    } else {
      return Future.error("Not found");
    }
  }

  List<DownloadTask> getAllDownloads() {
    return _cache.values.toList();
  }

  // Batch Download Mechanism
  Future<void> addBatchDownloads(List<String> urls, String savedDir) async {
    urls.forEach((url) {
      addDownload(url, savedDir);
    });
  }

  List<DownloadTask?> getBatchDownloads(List<String> urls) {
    return urls.map((e) => _cache[e]).toList();
  }

  Future<void> pauseBatchDownloads(List<String> urls) async {
    urls.forEach((element) {
      pauseDownload(element);
    });
  }

  Future<void> cancelBatchDownloads(List<String> urls) async {
    urls.forEach((element) {
      cancelDownload(element);
    });
  }

  Future<void> resumeBatchDownloads(List<String> urls) async {
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

  Future<List<DownloadTask?>?> whenBatchDownloadsComplete(List<String> urls,
      {Duration timeout = const Duration(hours: 2)}) async {
    var completer = Completer<List<DownloadTask?>?>();

    var completed = 0;
    var total = urls.length;

    urls.forEach((url) {
      var task = getDownload(url);

      if (task != null) {
        if (task.status.value.isCompleted) {
          completed++;

          if (completed == total) {
            completer.complete(getBatchDownloads(urls));
          }
        }

        var listener;
        listener = () {
          if (task.status.value.isCompleted) {
            completed++;

            if (completed == total) {
              completer.complete(getBatchDownloads(urls));
              task.status.removeListener(listener);
            }
          }
        };

        task.status.addListener(listener);
      } else {
        total--;

        if (total == 0) {
          completer.complete(null);
        }
      }
    });

    return completer.future.timeout(timeout);
  }

  void _startExecution() async {
    if (_runningTasks.length >= maxConcurrentTasks || _queue.isEmpty) {
      return;
    }

    while (_queue.isNotEmpty && _runningTasks.length < maxConcurrentTasks) {
      var currentRequest = _queue.removeFirst();

      _runningTasks.add(currentRequest.url);
      if (kDebugMode) {
        print('Concurrent workers: ${_runningTasks.length}');
        print('Active downloads:');
        for (var url in _runningTasks) {
          print('- $url');
        }
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

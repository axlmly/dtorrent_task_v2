import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:test/test.dart';

void main() {
  const payload = [1, 2, 3, 4, 5, 6, 7, 8];
  late Directory root;
  late TorrentTask task;
  late TorrentModel model;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('torrent_recheck_');
    final info = Uint8List.fromList([
      ...ascii.encode('d6:lengthi8e4:name9:video.mp4'
          '12:piece lengthi4e6:pieces40:'),
      ...sha1.convert(payload.sublist(0, 4)).bytes,
      ...sha1.convert(payload.sublist(4)).bytes,
      101,
    ]);
    model = TorrentParser.parseFromInfoBytes(info);
    task = TorrentTask.newTask(model, root.path, true);
    await task.prepare();
    final file = task.fileManager!.files.single;
    await File(file.filePath).writeAsBytes(payload);
  });
  tearDown(() async {
    await task.dispose();
    await root.delete(recursive: true);
  });

  test('recovers unrecorded pieces from renamed files and persists them',
      () async {
    final manager = task.fileManager!;
    await manager.moveFile(manager.files.single.torrentFilePath,
        '${root.path}${Platform.pathSeparator}renamed.mp4',
        validateAfterMove: false);
    expect(manager.localBitfield.completedPieces, isEmpty);
    final result = await manager.recheck();
    expect(result.isValid, isTrue);
    expect(manager.localBitfield.completedPieces, [0, 1]);
    expect(manager.files.single.completed, isTrue);
    expect(task.pieceManager!.pieces[0]!.isCompletelyWritten, isTrue);
    await task.dispose();
    task = TorrentTask.newTask(model, root.path, true);
    await task.prepare();
    expect(task.fileManager!.localBitfield.completedPieces, [0, 1]);
    expect(task.fileManager!.files.single.completed, isTrue);
    expect(task.fileManager!.files.single.filePath, endsWith('renamed.mp4'));
  });

  test('clears corrupt pieces and restores their request queue', () async {
    final manager = task.fileManager!;
    await manager.recheck();
    final access = await File(manager.files.single.filePath).open(
      mode: FileMode.writeOnlyAppend,
    );
    await access.setPosition(4);
    await access.writeByte(99);
    await access.close();
    final result = await manager.recheck();
    expect(result.invalidPieces, [1]);
    expect(manager.localBitfield.completedPieces, [0]);
    expect(manager.files.single.downloadedBytes, 4);
    expect(task.pieceManager!.pieces[1]!.flushed, isFalse);
    expect(task.pieceManager!.pieces[1]!.haveAvailableSubPiece(), isTrue);
  });

  test('short files cannot pass through zero-filled buffers', () async {
    await File(task.fileManager!.files.single.filePath).writeAsBytes([1, 2, 3]);
    final result = await task.fileManager!.recheck();
    expect(result.invalidPieces, [0, 1]);
    expect(task.fileManager!.localBitfield.completedPieces, isEmpty);
  });
}

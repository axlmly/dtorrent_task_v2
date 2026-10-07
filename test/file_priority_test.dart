import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:test/test.dart';

void main() {
  test('a piece shared by a skipped and a normal file is not skipped', () {
    const pieceLength = 16;
    final model = TorrentModel(
      name: 'priority-test',
      files: [
        TorrentFileModel(path: 'skipped.bin', length: 1, offset: 0),
        TorrentFileModel(path: 'selected.bin', length: 1, offset: 1),
        TorrentFileModel(path: 'later.bin', length: 1, offset: pieceLength),
      ],
      infoHashBuffer: Uint8List(20),
      pieceLength: pieceLength,
      pieces: [Uint8List(20), Uint8List(20)],
      announces: const [],
      nodes: const [],
      length: pieceLength + 1,
      version: TorrentVersion.v1,
    );
    final priorities = FilePriorityManager(model)
      ..setPriority(0, FilePriority.skip)
      ..setPriority(2, FilePriority.skip);

    expect(priorities.isPieceSkipped(0), isFalse);
    expect(priorities.getSkippedPieces(), {1});
    expect(priorities.getPiecesByPriority()[FilePriority.normal], {0});
    expect(priorities.getPiecesByPriority()[FilePriority.skip], {1});
  });
}

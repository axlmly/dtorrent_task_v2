import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:test/test.dart';

void main() {
  test('task accepts a custom Azureus peer id prefix', () {
    final model = TorrentModel(
      name: 'test.bin',
      files: [
        TorrentFileModel(path: 'test.bin', length: 1, offset: 0),
      ],
      infoHashBuffer: Uint8List(20),
      pieceLength: 16 * 1024,
      pieces: [Uint8List(20)],
      announces: const [],
      nodes: const [],
      length: 1,
      version: TorrentVersion.v1,
    );

    final task = TorrentTask.newTask(
      model,
      '/tmp/dtorrent-peer-id-test',
      false,
      null,
      null,
      null,
      null,
      false,
      null,
      null,
      null,
      '-QB0001-',
    );
    expect(task.peerId.length, 20);
    expect(task.peerId.startsWith('-QB0001-'), isTrue);
  });

  test('pure v2 metadata exposes piece roots and a 32-byte info hash', () {
    final pieceData = Uint8List.fromList(List<int>.filled(16 * 1024, 7));
    final pieceRoot = MerkleTreeHelper.calculatePieceRoot(pieceData);
    final info = <String, dynamic>{
      'meta version': 2,
      'name': 'v2.bin',
      'piece length': 16 * 1024,
      'file tree': {
        'v2.bin': {
          '': {
            'length': pieceData.length,
            'pieces root': pieceRoot,
          },
        },
      },
    };

    final model = TorrentParser.parseBytes(
      Uint8List.fromList(encode({'info': info})),
    );
    expect(model.version, TorrentVersion.v2);
    expect(model.infoHashBuffer.length, 32);
    expect(model.pieces, hasLength(1));
    expect(model.pieces!.single, orderedEquals(pieceRoot));
  });
}

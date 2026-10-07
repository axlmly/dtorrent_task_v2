import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:dtorrent_task_v2/src/piece/base_piece_selector.dart';
import 'package:test/test.dart';

void main() {
  late TorrentModel torrent;
  late PieceManager pieces;
  late Peer peer;

  setUp(() {
    const pieceLength = 16 * 1024;
    const pieceCount = 7;
    torrent = TorrentModel(
      name: 'selector-test',
      files: [
        TorrentFileModel(
          path: 'video.bin',
          length: pieceLength * pieceCount,
          offset: 0,
        ),
      ],
      infoHashBuffer: Uint8List(20),
      pieceLength: pieceLength,
      pieces: [
        for (var index = 0; index < pieceCount; index++) Uint8List(20),
      ],
      announces: const [],
      nodes: const [],
      length: pieceLength * pieceCount,
      version: TorrentVersion.v1,
    );
    final bitfield = Bitfield.createEmptyBitfield(torrent.pieces!.length);
    pieces = PieceManager.createPieceManager(
      BasePieceSelector(),
      torrent,
      bitfield,
    );
    peer = Peer.newTCPPeer(
      CompactAddress(InternetAddress.loopbackIPv4, 6881),
      List<int>.generate(20, (index) => index),
      pieces.length,
      null,
      PeerSource.manual,
    );
    for (var index = 0; index < pieces.length; index++) {
      peer.updateRemoteBitfield(index, true);
      pieces[index]!.addAvailablePeer(peer);
    }
  });

  tearDown(() async {
    await peer.dispose('test complete');
  });

  test('base selector skips suggested pieces marked skip', () {
    final selector = BasePieceSelector()..setSkippedPieces([0]);

    final selected = selector.selectPiece(peer, pieces, false, {0});

    expect(selected, isNotNull);
    expect(selected!.index, isNot(0));
  });

  test('advanced selector skips suggested pieces marked skip', () {
    final selector =
        AdvancedSequentialPieceSelector(SequentialConfig.forVideoStreaming())
          ..initialize(pieces.length, torrent.pieceLength)
          ..setSkippedPieces([0]);

    final selected = selector.selectPiece(peer, pieces, false, {0});

    expect(selected, isNotNull);
    expect(selected!.index, isNot(0));
  });
}

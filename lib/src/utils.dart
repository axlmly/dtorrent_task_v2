import 'dart:convert';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';

String generatePeerId([String prefix = idPrefix]) {
  if (prefix.length != 8 || prefix.codeUnits.any((byte) => byte > 255)) {
    throw ArgumentError.value(
      prefix,
      'prefix',
      'must contain exactly 8 single-byte characters',
    );
  }
  var r = randomBytes(9);
  var base64Str = base64Encode(r);
  var id = prefix + base64Str;
  return id;
}

String normalizePeerId(String peerId) {
  if (peerId.length != 20 || peerId.codeUnits.any((byte) => byte > 255)) {
    throw ArgumentError.value(
      peerId,
      'peerId',
      'must contain exactly 20 single-byte characters',
    );
  }
  return peerId;
}

List<int>? hexString2Buffer(String hexStr) {
  // ignore: prefer_is_empty
  if (hexStr.isEmpty || hexStr.length.remainder(2) != 0) return null;
  var size = hexStr.length ~/ 2;
  var re = <int>[];
  for (var i = 0; i < size; i++) {
    var s = hexStr.substring(i * 2, i * 2 + 2);
    var byte = int.parse(s, radix: 16);
    re.add(byte);
  }
  return re;
}

/// pow(2, 14)
///
/// download piece max size
const defaultRequestLength = 16384;

/// pow(2,17)
///
/// Remote is request piece length large or eqaul this length
/// , it must close the connection
const maxRequestLength = 131072;

import 'dart:io';
import 'dart:typed_data';
import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:crypto/crypto.dart';
import 'torrent_model.dart';
import 'torrent_file_model.dart';
import 'file_tree.dart';
import 'torrent_version.dart';
import '../file/file_attributes.dart';
import 'package:logging/logging.dart';

var _log = Logger('TorrentParser');

/// Parser for .torrent files with full support for BEP 3 (v1) and BEP 52 (v2)
class TorrentParser {
  /// Parse a torrent file from disk
  static Future<TorrentModel> parse(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ArgumentError('Torrent file does not exist: $filePath');
    }

    final bytes = await file.readAsBytes();
    return parseBytes(bytes);
  }

  /// Parse torrent from bytes
  static TorrentModel parseBytes(Uint8List bytes) {
    final decoded = decode(bytes);
    if (decoded is! Map) {
      throw FormatException('Invalid torrent file: root must be a dictionary');
    }

    // Convert Map<dynamic, dynamic> to Map<String, dynamic>
    final data = Map<String, dynamic>.from(decoded);
    return _parseTorrent(data, bytes);
  }

  /// Parse torrent from decoded bencoded dictionary
  ///
  /// This is useful when you have already decoded the torrent data
  /// (e.g., from metadata downloader)
  static TorrentModel parseFromMap(Map<String, dynamic> torrentMap) {
    // Re-encode to bytes for hash calculation
    final encoded = encode(torrentMap);
    return _parseTorrent(torrentMap, encoded);
  }

  /// Parse a torrent model from the raw bencoded **info dictionary** bytes
  /// (the payload delivered by BEP 09 magnet metadata exchange).
  ///
  /// The info hash is computed directly from [infoBytes], so it matches the
  /// magnet link's infohash exactly. Re-encoding a decoded map can change the
  /// bytes (e.g. `pieces`), which would produce a different hash and make
  /// tracker announces fail.
  ///
  /// [announces] are attached so the task announces to the magnet trackers,
  /// and [nodes] are attached as DHT bootstrap nodes.
  static TorrentModel parseFromInfoBytes(
    Uint8List infoBytes, {
    List<Uri> announces = const [],
    List<Uri> nodes = const [],
  }) {
    final decoded = decode(infoBytes);
    if (decoded is! Map) {
      throw FormatException(
          'Invalid info dictionary: root must be a dictionary');
    }
    final data = <String, dynamic>{
      'info': Map<String, dynamic>.from(decoded),
    };
    if (announces.isNotEmpty) {
      data['announce'] = announces.first.toString();
      data['announce-list'] = [
        for (final a in announces) [a.toString()],
      ];
    }
    if (nodes.isNotEmpty) {
      data['nodes'] = [
        for (final n in nodes) [n.host, n.port],
      ];
    }
    return _parseTorrent(data, null, explicitInfoBytes: infoBytes);
  }

  /// Parse torrent from decoded bencoded data
  static TorrentModel _parseTorrent(
      Map<String, dynamic> data, Uint8List? originalBytes,
      {Uint8List? explicitInfoBytes}) {
    final infoRaw = data['info'];
    if (infoRaw is! Map) {
      throw FormatException(
          'Invalid torrent file: missing or invalid info dictionary');
    }
    final info = Map<String, dynamic>.from(infoRaw);

    // Detect version
    final version = _detectVersion(info, data);
    _log.info('Detected torrent version: $version');

    // Parse name - can be String or Uint8List from bencode
    final nameRaw = info['name'];
    String? name;
    if (nameRaw is String) {
      name = nameRaw;
    } else if (nameRaw is Uint8List) {
      name = String.fromCharCodes(nameRaw);
    } else if (nameRaw is List<int>) {
      name = String.fromCharCodes(nameRaw);
    }
    if (name == null || name.isEmpty) {
      throw FormatException(
          'Invalid torrent file: missing name in info dictionary');
    }

    // Parse piece length
    final pieceLength = info['piece length'] as int?;
    if (pieceLength == null || pieceLength <= 0) {
      throw FormatException(
          'Invalid torrent file: missing or invalid piece length');
    }

    // Parse announces
    final announces = _parseAnnounces(data);

    // Parse nodes (DHT)
    final nodes = _parseNodes(data);

    // Parse files and pieces based on version
    List<TorrentFileModel> files = [];
    List<Uint8List>? pieces;
    int? length;
    Map<String, FileTreeEntry>? fileTree;
    Map<String, Uint8List>? pieceLayers;
    Uint8List? rootHash;
    Uint8List? infoDictBytes;
    int? metaVersion;

    if (version == TorrentVersion.v1 || version == TorrentVersion.hybrid) {
      // Parse v1 structure
      if (info.containsKey('length')) {
        // Single file
        length = info['length'] as int?;
        if (length == null) {
          throw FormatException(
              'Invalid torrent file: length must be an integer');
        }
        final attrs = FileAttributes.parse(info['attr']);
        files = [
          TorrentFileModel(
            path: name,
            length: length,
            offset: 0,
            attributes: attrs,
            symlinkPath: _parsePathList(info['symlink path']),
          )
        ];
      } else if (info.containsKey('files')) {
        // Multiple files
        final filesList = info['files'] as List?;
        if (filesList == null) {
          throw FormatException('Invalid torrent file: files must be a list');
        }
        files = _parseV1Files(filesList, name);
      } else {
        throw FormatException('Invalid torrent file: missing length or files');
      }

      // Parse pieces (v1)
      if (info.containsKey('pieces')) {
        final piecesData = info['pieces'] as Uint8List?;
        if (piecesData != null) {
          pieces = _parsePieces(piecesData);
        }
      }
    }

    if (version == TorrentVersion.v2 || version == TorrentVersion.hybrid) {
      // Parse v2 structure
      metaVersion = info['meta version'] as int?;

      // Parse file tree
      if (info.containsKey('file tree')) {
        final treeData = info['file tree'];
        fileTree = FileTreeHelper.parseFileTree(treeData);
      }

      // Parse piece layers (in root dict, not info dict)
      if (data.containsKey('piece layers')) {
        final layersData = data['piece layers'];
        if (layersData is Map) {
          pieceLayers = _parsePieceLayers(layersData);
        }
      }

      // Parse root hash
      if (info.containsKey('root hash')) {
        final rootHashData = info['root hash'] as Uint8List?;
        if (rootHashData != null && rootHashData.length == 32) {
          rootHash = rootHashData;
        }
      }

      // If we have file tree but no v1 files, extract files from tree
      if (fileTree != null && (version == TorrentVersion.v2 || files.isEmpty)) {
        final treeFiles = FileTreeHelper.extractFiles(fileTree, '');
        if (files.isEmpty) {
          // Convert FileTreeFile to TorrentFileModel
          var offset = 0;
          files = treeFiles.map((tf) {
            final file = TorrentFileModel(
              path: tf.path,
              length: tf.length,
              offset: offset,
              attributes: tf.attributes,
              isPaddingFile: tf.isPaddingFile,
              symlinkPath: tf.symlinkPath,
            );
            offset += tf.length;
            return file;
          }).toList();
        }
      }
    }

    // Calculate info hash
    Uint8List infoHashBuffer;
    // Prefer explicitly supplied info-dict bytes (magnet metadata) so the
    // hash is computed from the exact original bytes.
    final effectiveInfoBytes = explicitInfoBytes ??
        (originalBytes != null ? _extractInfoDictBytes(originalBytes) : null);
    infoDictBytes = effectiveInfoBytes;
    if (effectiveInfoBytes != null) {
      final hash = (version == TorrentVersion.v2 ||
              version == TorrentVersion.hybrid)
          ? sha256.convert(effectiveInfoBytes)
          : sha1.convert(effectiveInfoBytes);
      infoHashBuffer = Uint8List.fromList(hash.bytes);
    } else {
      throw FormatException(
          'Cannot calculate info hash without original bytes');
    }

    return TorrentModel(
      name: name,
      files: files,
      infoHashBuffer: infoHashBuffer,
      pieceLength: pieceLength,
      pieces: pieces,
      announces: announces,
      nodes: nodes,
      length: length,
      version: version,
      metaVersion: metaVersion,
      fileTree: fileTree,
      pieceLayers: pieceLayers,
      rootHash: rootHash,
      infoDictBytes: infoDictBytes,
      rawData: data,
    );
  }

  /// Detect torrent version from info dict and root dict
  static TorrentVersion _detectVersion(
      Map<String, dynamic> info, Map<String, dynamic> root) {
    final metaVersion = info['meta version'] as int?;
    final hasFileTree = info.containsKey('file tree');
    final hasPieces = info.containsKey('pieces');
    final hasPieceLayers = root.containsKey('piece layers');

    // v2 torrent: meta version == 2, has file tree
    if (metaVersion == 2 && hasFileTree) {
      // Check if it's hybrid (has both v1 and v2 structures)
      if (hasPieces && hasPieceLayers) {
        return TorrentVersion.hybrid;
      }
      return TorrentVersion.v2;
    }

    // v1 torrent: has pieces, no meta version or meta version != 2
    if (hasPieces && (metaVersion == null || metaVersion != 2)) {
      return TorrentVersion.v1;
    }

    // Default to v1 for compatibility
    return TorrentVersion.v1;
  }

  /// Parse announce URLs
  static List<Uri> _parseAnnounces(Map<String, dynamic> data) {
    final announces = <Uri>[];

    // Try announce-list first (BEP 0012)
    if (data.containsKey('announce-list')) {
      final announceList = data['announce-list'] as List?;
      if (announceList != null) {
        for (var tier in announceList) {
          if (tier is List) {
            for (var url in tier) {
              String? urlString;
              if (url is String) {
                urlString = url;
              } else if (url is Uint8List) {
                urlString = String.fromCharCodes(url);
              } else if (url is List<int>) {
                urlString = String.fromCharCodes(url);
              }
              if (urlString != null) {
                try {
                  announces.add(Uri.parse(urlString));
                } catch (e) {
                  _log.warning('Invalid announce URL: $urlString', e);
                }
              }
            }
          }
        }
      }
    }

    // Fallback to single announce
    if (announces.isEmpty && data.containsKey('announce')) {
      final announceRaw = data['announce'];
      String? announce;
      if (announceRaw is String) {
        announce = announceRaw;
      } else if (announceRaw is Uint8List) {
        announce = String.fromCharCodes(announceRaw);
      } else if (announceRaw is List<int>) {
        announce = String.fromCharCodes(announceRaw);
      }
      if (announce != null) {
        try {
          announces.add(Uri.parse(announce));
        } catch (e) {
          _log.warning('Invalid announce URL: $announce', e);
        }
      }
    }

    return announces;
  }

  /// Parse DHT nodes
  static List<Uri> _parseNodes(Map<String, dynamic> data) {
    final nodes = <Uri>[];

    if (data.containsKey('nodes')) {
      final nodesData = data['nodes'];
      if (nodesData is List) {
        for (var node in nodesData) {
          if (node is List && node.length == 2) {
            final hostRaw = node[0];
            String? host;
            if (hostRaw is String) {
              host = hostRaw;
            } else if (hostRaw is Uint8List) {
              host = String.fromCharCodes(hostRaw);
            } else if (hostRaw is List<int>) {
              host = String.fromCharCodes(hostRaw);
            }
            final port = node[1] as int?;
            if (host != null && port != null) {
              try {
                nodes.add(Uri.parse('udp://$host:$port'));
              } catch (e) {
                _log.warning('Invalid node: $host:$port', e);
              }
            }
          }
        }
      }
    }

    return nodes;
  }

  /// Parse v1 files list
  static List<TorrentFileModel> _parseV1Files(List filesList, String basePath) {
    final files = <TorrentFileModel>[];
    var offset = 0;

    for (var fileData in filesList) {
      if (fileData is! Map) continue;

      final length = fileData['length'] as int?;
      if (length == null) continue;
      final attrs = FileAttributes.parse(fileData['attr']);
      final symlinkPath = _parsePathList(fileData['symlink path']);

      final pathList = fileData['path'] as List?;
      String path;
      if (pathList != null && pathList.isNotEmpty) {
        path = pathList.map((p) {
          if (p is String) {
            return p;
          } else if (p is Uint8List) {
            return String.fromCharCodes(p);
          } else if (p is List<int>) {
            return String.fromCharCodes(p);
          } else {
            return p.toString();
          }
        }).join('/');
        if (basePath.isNotEmpty) {
          path = '$basePath/$path';
        }
      } else {
        path = basePath;
      }

      files.add(TorrentFileModel(
        path: path,
        length: length,
        offset: offset,
        attributes: attrs,
        symlinkPath: symlinkPath,
      ));

      offset += length;
    }

    return files;
  }

  /// Parse piece hashes from pieces string
  static List<Uint8List> _parsePieces(Uint8List piecesData) {
    const pieceHashLength = 20; // SHA-1 hash length
    if (piecesData.length % pieceHashLength != 0) {
      throw FormatException(
          'Invalid pieces data: length must be multiple of $pieceHashLength');
    }

    final pieces = <Uint8List>[];
    for (var i = 0; i < piecesData.length; i += pieceHashLength) {
      pieces.add(piecesData.sublist(i, i + pieceHashLength));
    }

    return pieces;
  }

  /// Parse piece layers from bencoded data
  static Map<String, Uint8List> _parsePieceLayers(
      Map<dynamic, dynamic> layersData) {
    final pieceLayers = <String, Uint8List>{};

    for (var entry in layersData.entries) {
      final key = entry.key;
      final value = entry.value;

      // Key should be hex string of piece root hash
      String keyString;
      if (key is Uint8List) {
        keyString = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      } else if (key is String) {
        keyString = key;
      } else {
        continue;
      }

      // Value should be Uint8List of piece layer data
      if (value is Uint8List) {
        pieceLayers[keyString] = value;
      }
    }

    return pieceLayers;
  }

  static List<String>? _parsePathList(dynamic value) {
    if (value is! List) return null;
    final segments = <String>[];
    for (final item in value) {
      if (item is String) {
        if (item.isNotEmpty) segments.add(item);
      } else if (item is Uint8List) {
        final decoded = String.fromCharCodes(item);
        if (decoded.isNotEmpty) segments.add(decoded);
      } else if (item is List<int>) {
        final decoded = String.fromCharCodes(item);
        if (decoded.isNotEmpty) segments.add(decoded);
      }
    }
    if (segments.isEmpty) return null;
    return segments;
  }

  /// Extract the raw bytes of the `info` dictionary from bencoded torrent
  /// data, for info-hash calculation.
  ///
  /// Uses a proper bencode walk (skipping over string payloads) instead of a
  /// naive `d`/`e` byte scan, which produced wrong slices when string values
  /// (e.g. `pieces`) contained `0x64`/`0x65` bytes.
  static Uint8List? _extractInfoDictBytes(Uint8List torrentBytes) {
    try {
      if (torrentBytes.isEmpty || torrentBytes[0] != 0x64) {
        return null; // not a dictionary
      }
      var i = 1;
      while (i < torrentBytes.length && torrentBytes[i] != 0x65) {
        final keyStart = i;
        i = _skipBencoded(torrentBytes, i);
        final key = String.fromCharCodes(torrentBytes.sublist(keyStart, i));
        final valueStart = i;
        i = _skipBencoded(torrentBytes, i);
        if (key == 'info') {
          return torrentBytes.sublist(valueStart, i);
        }
      }
      return null;
    } catch (e) {
      _log.warning('Failed to extract info dict bytes', e);
      return null;
    }
  }

  /// Returns the index just past the bencoded value starting at [i].
  static int _skipBencoded(Uint8List b, int i) {
    final c = b[i];
    if (c == 0x64) {
      // dictionary
      i++;
      while (b[i] != 0x65) {
        i = _skipBencoded(b, i); // key
        i = _skipBencoded(b, i); // value
      }
      return i + 1;
    }
    if (c == 0x6c) {
      // list
      i++;
      while (b[i] != 0x65) {
        i = _skipBencoded(b, i);
      }
      return i + 1;
    }
    if (c == 0x69) {
      // integer
      while (b[i] != 0x65) {
        i++;
      }
      return i + 1;
    }
    // byte string: <length>:<bytes>
    var j = i;
    while (b[j] != 0x3a) {
      j++;
    }
    final len = int.parse(String.fromCharCodes(b.sublist(i, j)));
    return j + 1 + len;
  }
}

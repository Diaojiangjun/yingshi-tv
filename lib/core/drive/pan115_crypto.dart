import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 115 App 接口使用的 m115 载荷编解码。
///
/// 算法与 115driver 的 m115 实现一致：16 字节随机 key + XOR + 反转 +
/// RSA（e=65537）填充加密，最后 Base64。只用于分享下载接口的 `data` 参数。
class Pan115Crypto {
  Pan115Crypto._();

  static final BigInt _modulus = BigInt.parse(
    '8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021'
    '36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633'
    '8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1'
    '0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683',
    radix: 16,
  );
  static final BigInt _exponent = BigInt.parse('10001', radix: 16);
  static final int _keyLength = (_modulus.bitLength + 7) ~/ 8;

  static final List<int> _xorKeySeed = <int>[
    0xf0,
    0xe5,
    0x69,
    0xae,
    0xbf,
    0xdc,
    0xbf,
    0x8a,
    0x1a,
    0x45,
    0xe8,
    0xbe,
    0x7d,
    0xa6,
    0x73,
    0xb8,
    0xde,
    0x8f,
    0xe7,
    0xc4,
    0x45,
    0xda,
    0x86,
    0xc4,
    0x9b,
    0x64,
    0x8b,
    0x14,
    0x6a,
    0xb4,
    0xf1,
    0xaa,
    0x38,
    0x01,
    0x35,
    0x9e,
    0x26,
    0x69,
    0x2c,
    0x86,
    0x00,
    0x6b,
    0x4f,
    0xa5,
    0x36,
    0x34,
    0x62,
    0xa6,
    0x2a,
    0x96,
    0x68,
    0x18,
    0xf2,
    0x4a,
    0xfd,
    0xbd,
    0x6b,
    0x97,
    0x8f,
    0x4d,
    0x8f,
    0x89,
    0x13,
    0xb7,
    0x6c,
    0x8e,
    0x93,
    0xed,
    0x0e,
    0x0d,
    0x48,
    0x3e,
    0xd7,
    0x2f,
    0x88,
    0xd8,
    0xfe,
    0xfe,
    0x7e,
    0x86,
    0x50,
    0x95,
    0x4f,
    0xd1,
    0xeb,
    0x83,
    0x26,
    0x34,
    0xdb,
    0x66,
    0x7b,
    0x9c,
    0x7e,
    0x9d,
    0x7a,
    0x81,
    0x32,
    0xea,
    0xb6,
    0x33,
    0xde,
    0x3a,
    0xa9,
    0x59,
    0x34,
    0x66,
    0x3b,
    0xaa,
    0xba,
    0x81,
    0x60,
    0x48,
    0xb9,
    0xd5,
    0x81,
    0x9c,
    0xf8,
    0x6c,
    0x84,
    0x77,
    0xff,
    0x54,
    0x78,
    0x26,
    0x5f,
    0xbe,
    0xe8,
    0x1e,
    0x36,
    0x9f,
    0x34,
    0x80,
    0x5c,
    0x45,
    0x2c,
    0x9b,
    0x76,
    0xd5,
    0x1b,
    0x8f,
    0xcc,
    0xc3,
    0xb8,
    0xf5,
  ];

  static final List<int> _xorClientKey = <int>[
    0x78,
    0x06,
    0xad,
    0x4c,
    0x33,
    0x86,
    0x5d,
    0x18,
    0x4c,
    0x01,
    0x3f,
    0x46,
  ];

  /// 生成一次请求使用的 16 字节 key。
  static Uint8List generateKey() {
    final random = Random.secure();
    final key = Uint8List(16);
    for (var i = 0; i < key.length; i++) {
      key[i] = random.nextInt(256);
    }
    return key;
  }

  /// 编码为 App 接口的 `data` 参数。
  static String encode(Map<String, Object?> payload, Uint8List key) {
    final body = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final buffer = Uint8List(16 + body.length)
      ..setRange(0, 16, key)
      ..setRange(16, 16 + body.length, body);
    final payloadView = Uint8List.sublistView(buffer, 16);
    _xorTransform(payloadView, _deriveKey(key, 4));
    _reverse(payloadView);
    _xorTransform(payloadView, _xorClientKey);
    return base64.encode(_rsaEncrypt(buffer));
  }

  /// 解码响应里的加密载荷；key 必须与 [encode] 时相同。
  static Map<String, Object?> decode(String input, Uint8List key) {
    final data = _rsaDecrypt(base64.decode(input));
    if (data.length <= 16) return const <String, Object?>{};
    final body = Uint8List.fromList(data.sublist(16));
    _xorTransform(body, _deriveKey(data.sublist(0, 16), 12));
    _reverse(body);
    _xorTransform(body, _deriveKey(key, 4));
    final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
    return decoded is Map
        ? decoded.map((key, value) => MapEntry(key.toString(), value))
        : const <String, Object?>{};
  }

  static List<int> _deriveKey(List<int> seed, int size) {
    final key = List<int>.filled(size, 0);
    for (var i = 0; i < size; i++) {
      key[i] = (seed[i] + _xorKeySeed[size * i]) & 0xff;
      key[i] ^= _xorKeySeed[size * (size - i - 1)];
    }
    return key;
  }

  static void _xorTransform(List<int> data, List<int> key) {
    final dataSize = data.length;
    final keySize = key.length;
    final mod = dataSize % 4;
    for (var i = 0; i < mod; i++) {
      data[i] ^= key[i % keySize];
    }
    for (var i = mod; i < dataSize; i++) {
      data[i] ^= key[(i - mod) % keySize];
    }
  }

  static void _reverse(List<int> data) {
    var left = 0;
    var right = data.length - 1;
    while (left < right) {
      final temp = data[left];
      data[left] = data[right];
      data[right] = temp;
      left++;
      right--;
    }
  }

  static Uint8List _rsaEncrypt(List<int> input) {
    final output = BytesBuilder(copy: false);
    for (var offset = 0; offset < input.length;) {
      final size = min(_keyLength - 11, input.length - offset);
      _rsaEncryptSlice(input.sublist(offset, offset + size), output);
      offset += size;
    }
    return output.takeBytes();
  }

  static void _rsaEncryptSlice(List<int> input, BytesBuilder output) {
    final padSize = _keyLength - input.length - 3;
    final random = Random.secure();
    final block = Uint8List(_keyLength);
    block[0] = 0;
    block[1] = 2;
    for (var i = 0; i < padSize; i++) {
      block[2 + i] = random.nextInt(255) + 1;
    }
    block[padSize + 2] = 0;
    block.setRange(padSize + 3, _keyLength, input);
    final encrypted = _bytesToBigInt(block).modPow(_exponent, _modulus);
    output.add(_bigIntToBytes(encrypted, _keyLength));
  }

  static Uint8List _rsaDecrypt(Uint8List input) {
    final output = BytesBuilder(copy: false);
    for (var offset = 0; offset < input.length;) {
      final size = min(_keyLength, input.length - offset);
      final block = input.sublist(offset, offset + size);
      final decrypted = _bytesToBigInt(block).modPow(_exponent, _modulus);
      final bytes = _bigIntToBytes(decrypted, _keyLength);
      for (var i = 1; i < bytes.length; i++) {
        if (bytes[i] == 0) {
          output.add(bytes.sublist(i + 1));
          break;
        }
      }
      offset += size;
    }
    return output.takeBytes();
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var current = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (current & BigInt.from(0xff)).toInt();
      current = current >> 8;
    }
    return out;
  }
}

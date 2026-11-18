// Passwords and agent tokens, encrypted by Windows (DPAPI) for the Windows account that saved them: a copy of the
// settings file on another PC, or read by another account, does not reveal them.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectC = Int32 Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _ProtectD = int Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _UnprotectC = Int32 Function(Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _UnprotectD = int Function(Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _LocalFreeC = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeD = Pointer<Void> Function(Pointer<Void>);

const _noUi = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

class Secret {
  static final _crypt = DynamicLibrary.open('crypt32.dll');
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt.lookupFunction<_ProtectC, _ProtectD>('CryptProtectData');
  static final _unprotect = _crypt.lookupFunction<_UnprotectC, _UnprotectD>('CryptUnprotectData');
  static final _localFree = _kernel.lookupFunction<_LocalFreeC, _LocalFreeD>('LocalFree');

  static String encrypt(String plain) {
    if (plain.isEmpty || !Platform.isWindows) return plain;
    final bytes = utf8.encode(plain);
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final data = calloc<Uint8>(bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      input.ref
        ..cbData = bytes.length
        ..pbData = data;
      if (_protect(input, nullptr, nullptr, nullptr, nullptr, _noUi, output) == 0) {
        throw StateError('Windows refused to encrypt the secret.');
      }
      final res = base64.encode(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return 'dpapi:$res';
    } finally {
      calloc.free(data);
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// A value that was not encrypted is returned as is; one encrypted by another Windows account comes back empty.
  static String decrypt(String value) {
    if (!value.startsWith('dpapi:') || !Platform.isWindows) return value;
    final bytes = base64.decode(value.substring(6));
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final data = calloc<Uint8>(bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      input.ref
        ..cbData = bytes.length
        ..pbData = data;
      if (_unprotect(input, nullptr, nullptr, nullptr, nullptr, _noUi, output) == 0) return '';
      final res = utf8.decode(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return res;
    } finally {
      calloc.free(data);
      calloc.free(input);
      calloc.free(output);
    }
  }
}

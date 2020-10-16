import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';


/// Wraps the Win32 VerQueryValue API call.
///
/// This class exists to allow injecting alternate metadata in tests without
/// building multiple custom test binaries.
@visibleForTesting
class VersionInfoQuerier {
  /// Returns the value for [key] in [versionInfo]s English strings section, or
  /// null if there is no such entry, or if versionInfo is null.
  getStringValue(Pointer<Uint8> versionInfo, key) {
    if (versionInfo == null) {
      return null;
    }
    const kEnUsLanguageCode = '040904e4'; // FIXME this key should be chosen dynamically
    final keyPath = TEXT('\\StringFileInfo\\$kEnUsLanguageCode\\$key');
    final length = allocate<Uint32>();
    final valueAddress = allocate<IntPtr>();
    try {
      if (VerQueryValue(versionInfo, keyPath, valueAddress, length) == 0) {
        return null;
      }
      return Pointer<Utf16>.fromAddress(valueAddress.value)
          .unpackString(length.value);
    } finally {
      free(keyPath);
      free(length);
      free(valueAddress);
    }
  }
}

class PathProviderWindows extends PlatformInterface {
  /// The object to use for performing VerQueryValue calls.
  @visibleForTesting
  VersionInfoQuerier versionInfoQuerier = VersionInfoQuerier();

  PathProviderWindows() {
    print('Yeah should work...');
    MethodChannel methodChannel = MethodChannel('plugins.flutter.io/package_info');
    methodChannel.setMethodCallHandler(handle);
  }

  Future<Map<String, dynamic>> handle(MethodCall call) async {
    if(call.method=='getAll') {
      final Map<String, dynamic> map = Map<String, dynamic>();
      map["packageName"] = 'packageName';
      map["buildNumber"] = 'buildNumber';

      String companyName;
      String productName;
      String version;

      final Pointer<Utf16> moduleNameBuffer =
      allocate<Uint16>(count: MAX_PATH + 1).cast<Utf16>();
      final Pointer<Uint32> unused = allocate<Uint32>();
      Pointer<Uint8> infoBuffer;
      try {
        // Get the module name.
        final moduleNameLength = GetModuleFileName(0, moduleNameBuffer, MAX_PATH);
        if (moduleNameLength == 0) {
          final error = GetLastError();
          throw WindowsException(error);
        }

        // From that, load the VERSIONINFO resource
        int infoSize = GetFileVersionInfoSize(moduleNameBuffer, unused);
        if (infoSize != 0) {
          infoBuffer = allocate<Uint8>(count: infoSize);
          if (GetFileVersionInfo(moduleNameBuffer, 0, infoSize, infoBuffer) ==
              0) {
            free(infoBuffer);
            infoBuffer = null;
          }
        }
        companyName = _sanitizedDirectoryName(
            versionInfoQuerier.getStringValue(infoBuffer, 'CompanyName'));
        productName = _sanitizedDirectoryName(
            versionInfoQuerier.getStringValue(infoBuffer, 'ProductName'));
        version = _sanitizedDirectoryName(
            versionInfoQuerier.getStringValue(infoBuffer, 'FileVersion'));

        // If there was no product name, use the executable name.
        if (productName == null) {
          //productName = path.basenameWithoutExtension(
          //    moduleNameBuffer.unpackString(moduleNameLength));
        }
      } finally {
        free(moduleNameBuffer);
        free(unused);
        if (infoBuffer != null) {
          free(infoBuffer);
        }
      }

      map["appName"] = productName;
      map["version"] = version;

      return map;
    } else {
      throw UnimplementedError(call.method + '() has not been implemented.');
    }
  }

  /// Returns the relative path string to append to the root directory returned
  /// by Win32 APIs for application storage (such as RoamingAppDir) to get a
  /// directory that is unique to the application.
  ///
  /// The convention is to use company-name\product-name\. This will use that if
  /// possible, using the data in the VERSIONINFO resource, with the following
  /// fallbacks:
  /// - If the company name isn't there, that component will be dropped.
  /// - If the product name isn't there, it will use the exe's filename (without
  ///   extension).
  String _getApplicationSpecificSubdirectory() {

  }

  /// Makes [rawString] safe as a directory component. See
  /// https://docs.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions
  ///
  /// If after sanitizing the string is empty, returns null.
  String _sanitizedDirectoryName(String rawString) {
    if (rawString == null) {
      return null;
    }
    String sanitized = rawString
    // Replace banned characters.
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
    // Remove trailing whitespace.
        .trimRight()
    // Ensure that it does not end with a '.'.
        .replaceAll(RegExp(r'[.]+$'), '');
    const kMaxComponentLength = 255;
    if (sanitized.length > kMaxComponentLength) {
      sanitized = sanitized.substring(0, kMaxComponentLength);
    }
    return sanitized.isEmpty ? null : sanitized;
  }
}
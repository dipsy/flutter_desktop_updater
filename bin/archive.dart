import "dart:convert";
import "dart:io";

import "package:cryptography_plus/cryptography_plus.dart";
import "package:desktop_updater/src/app_archive.dart";
import "package:yaml/yaml.dart" as yaml;

import "helper/copy.dart";

Future<String> getFileHash(File file) async {
  try {
    // Dosya içeriğini okuyun
    final List<int> fileBytes = await file.readAsBytes();

    // blake2s algoritmasıyla hash hesaplayın

    final hash = await Blake2b().hash(fileBytes);

    // Hash'i utf-8 base64'e dönüştürün ve geri döndürün
    return base64.encode(hash.bytes);
  } catch (e) {
    print("Error reading file ${file.path}: $e");
    return "";
  }
}

Future<String?> genFileHashes({required String? path}) async {
  print("Generating file hashes for $path");

  if (path == null) {
    throw Exception("Desktop Updater: Executable path is null");
  }

  final dir = Directory(path);

  print("Directory path: ${dir.path}");

  // Eğer belirtilen yol bir dizinse
  if (await dir.exists()) {
    // temp dizinindeki dosyaları kopyala
    // dir + output.txt dosyası oluşturulur
    final outputFile = File("${dir.path}${Platform.pathSeparator}hashes.json");

    // Çıktı dosyasını açıyoruz
    final sink = outputFile.openWrite();

    // ignore: prefer_final_locals
    var hashList = <FileHashModel>[];

    // Dizin içindeki tüm dosyaları döngüyle okuyoruz
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          !entity.path.endsWith("hashes.json") &&
          !entity.path.endsWith(".DS_Store")) {
        // Dosyanın hash'ini al
        final hash = await getFileHash(entity);
        final foundPath = entity.path.substring(dir.path.length + 1);

        // Dosya yolunu ve hash değerini yaz
        if (hash.isNotEmpty) {
          final hashObj = FileHashModel(
            filePath: foundPath,
            calculatedHash: hash,
            length: entity.lengthSync(),
          );
          hashList.add(hashObj);
        }
      }
    }

    // Dosya hash'lerini json formatına çevir
    final jsonStr = jsonEncode(hashList);

    // Çıktı dosyasına yaz
    sink.write(jsonStr);

    // Çıktıyı kaydediyoruz
    await sink.close();
    return outputFile.path;
  } else {
    throw Exception("Desktop Updater: Directory does not exist");
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print("PLATFORM must be specified: macos, windows, linux");
    print("Usage: dart run desktop_updater:archive <platform> [app_name]");
    exit(1);
  }

  final platform = args[0];
  String? customAppName;
  
  if (args.length > 1) {
    customAppName = args[1];
  }

  if (platform != "macos" && platform != "windows" && platform != "linux") {
    print("PLATFORM must be specified: macos, windows, linux");
    print("Usage: dart run desktop_updater:archive <platform> [app_name]");
    exit(1);
  }

  // Go to dist directory and get all folder names
  final distDir = Directory("dist");

  if (!await distDir.exists()) {
    print("dist folder could not be found");
    exit(1);
  }

  /// Sort folders by name, it will be the build number,
  /// and get the last one, biggest build number
  final folders = await distDir.list().toList();
  folders.sort((a, b) => a.path.compareTo(b.path));

  final lastBuildNumberFolder = folders.last;

  // Get all files in the last folder path
  final files = await Directory(lastBuildNumberFolder.path).list().toList();

  var platformFound = false;
  String? foundDirectory;
  String? foundVersion;
  String? foundBuildNumber;

  /// Check if there is a file in given platform
  for (final file in files) {
    if (file is Directory) {
      // desktop_updater_example-0.1.1+2-macos.app
      // version is 0.1.1, build number is 2, platform is macos, name is appNamePubspec variable
      final version = file.path.split("-").elementAt(1).split("+").first;
      final buildNumber =
          file.path.split("-").elementAt(1).split("+").last.split("-").first;
      final foundPlatform = file.path.split("-").last.split(".").first;

      if (foundPlatform == platform) {
        platformFound = true;
        foundDirectory = file.path;
        foundVersion = version;
        foundBuildNumber = buildNumber;
      }
    }
  }

  if (!platformFound || foundDirectory == null) {
    print("File not found for platform: $platform");
    exit(1);
  } else {
    print("Using archive: $foundDirectory");
  }

  /// Check if the file is a zip file
  // if (!foundDirectory.endsWith(".app")) {
  //   print("File is not a zip file");
  //   exit(1);
  // }

  // Get current build name and number from pubspec.yaml
  final pubspec = File("pubspec.yaml");
  final pubspecContent = await pubspec.readAsString();
  final appNameFromPubspec =
      RegExp(r"name: (.+)").firstMatch(pubspecContent)!.group(1);
  
  // Try to get app name from desktop_updater config
  String? configAppName;
  try {
    final yamlDoc = yaml.loadYaml(pubspecContent);
    if (yamlDoc is Map && yamlDoc.containsKey("desktop_updater")) {
      final desktopUpdater = yamlDoc["desktop_updater"];
      if (desktopUpdater is Map && desktopUpdater.containsKey("app_name")) {
        configAppName = desktopUpdater["app_name"].toString();
      }
    }
  } catch (e) {
    // Ignore parsing errors
  }
  
  // Use pubspec name for folder, but config name for display
  final appNameForFolder = appNameFromPubspec;
  final appNameForDisplay = customAppName ?? configAppName ?? appNameFromPubspec;

  if (platform == "windows") {
    await copyDirectory(
      Directory(
        foundDirectory,
      ),
      Directory(
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  } else if (platform == "macos") {
    // Find the actual .app directory within foundDirectory
    final foundDir = Directory(foundDirectory);
    final apps = foundDir
        .listSync()
        .where((entity) => entity.path.endsWith(".app"))
        .toList();
    
    if (apps.isNotEmpty) {
      await copyDirectory(
        Directory("${apps.first.path}/Contents"),
        Directory(
          "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
        ),
      );
    } else {
      // Fallback to expected name
      await copyDirectory(
        Directory("$foundDirectory/$appNameForDisplay.app/Contents"),
        Directory(
          "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
        ),
      );
    }
  } else if (platform == "linux") {
    await copyDirectory(
      Directory(foundDirectory),
      Directory(
        "${lastBuildNumberFolder.path}/$foundVersion+$foundBuildNumber-$platform",
      ),
    );
  }

  await genFileHashes(
    path:
        "${lastBuildNumberFolder.path}${Platform.pathSeparator}$foundVersion+$foundBuildNumber-$platform",
  );

  return;
}

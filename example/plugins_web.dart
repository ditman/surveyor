import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/type_system.dart' show TypeSystem;
import 'package:analyzer/file_system/file_system.dart' hide File;
import 'package:analyzer/source/line_info.dart';
import 'package:csv/csv.dart';
import 'package:path/path.dart' as path;
import 'package:surveyor/src/common.dart';
import 'package:surveyor/src/driver.dart';
import 'package:surveyor/src/visitors.dart';

final Set<String> evilLibraries = {
  'dart:io',
};

final String _kImportsEvilLibraryKey = 'importsEvilLibrary';
final String _kExportsEvilLibraryKey = 'exportsEvilLibrary';
final String _kUsesEvilLibraryKey = 'privateReturnsEvilLibrary';
final String _kExposesEvilLibraryKey = 'publicReturnsEvilLibrary';
final String _kCallsMethodsOfEvilLibraryKey = 'callsEvilLibrary';

final List<dynamic> csvHeader = [
  "Plugin",
  "# Imports",
  "# Exports",
  "# Private returns",
  "# Public returns",
  "# Calls",
  "Imports",
  "Exports",
  "Private returns",
  "Public returns",
  "Calls",
];

/// Checks if a plugin is going to be easy/hard to port/use in flutter web.
/// 
/// Download the target packages with pq/pub_crawl, with something similar to:
/// 
/// dart path/to/pub_crawl.dart fetch --criteria flutter --max 100000
/// 
/// Then run this like so:
///
/// dart path/to/example/plugins_web.dart third_party/cache
main(List<String> args) async {
  if (args.length == 1) {
    final dir = args[0];
    if (!File('$dir/pubspec.yaml').existsSync()) {
      print("Recursing into '$dir'...");
      args = Directory(dir).listSync().map((f) => f.path).toList()..sort();
      dirCount = args.length;
      print('(Found $dirCount subdirectories.)');
    }
  }

  if (_debuglimit != null) {
    print('Limiting analysis to $_debuglimit packages.');
  }

  final stopwatch = Stopwatch()..start();

  final driver = Driver.forArgs(args);
  driver.forceSkipInstall = true;
  driver.showErrors = false;
  driver.resolveUnits = true;
  driver.pubspecVisitor = WebPluginIdentifier();
  driver.visitor = WebPluginsCollector();

  await driver.analyze();

  String csv = const ListToCsvConverter().convert(_formatOutput(pluginMetadata));

  print('Writing out.csv...');
  File('out.csv').writeAsStringSync(csv);

  print(
      '(Elapsed time: ${Duration(milliseconds: stopwatch.elapsedMilliseconds)})');
}

// Formats the output 
List<List<dynamic>> _formatOutput(Map<String, Map<String, dynamic>> metadata) {
  List<List<dynamic>> output = [csvHeader];

  metadata.forEach((String plugin, Map<String, dynamic> meta) {
    output.add([
      plugin,
      meta[_kImportsEvilLibraryKey].length,
      meta[_kExportsEvilLibraryKey].length,
      meta[_kUsesEvilLibraryKey].length,
      meta[_kExposesEvilLibraryKey].length,
      meta[_kCallsMethodsOfEvilLibraryKey] .length,
      meta[_kImportsEvilLibraryKey].join("\n"),
      meta[_kExportsEvilLibraryKey].join("\n"),
      meta[_kUsesEvilLibraryKey].join("\n"),
      meta[_kExposesEvilLibraryKey].join("\n"),
      meta[_kCallsMethodsOfEvilLibraryKey].join("\n"),
    ]);
  });

  return output;
}

int dirCount;

Set<String> plugins = {};
Map<String, Map<String, dynamic>> pluginMetadata = Map();

/// If non-zero, stops once limit is reached (for debugging).
int _debuglimit; //500;

// Marks which packages are flutter plugins by looking at their pubspec.
class WebPluginIdentifier extends PubspecVisitor {
  @override
  void visit(PubspecFile file) {
    final String baseDir = path.basename(path.dirname(file.file.path));
    String pluginClass = "";
    try {
      pluginClass = file.yaml['flutter']['plugin']['pluginClass'];
      plugins.add(baseDir);
      pluginMetadata[baseDir] = Map.from({
        _kImportsEvilLibraryKey: <String>{},
        _kExportsEvilLibraryKey: <String>{},
        _kUsesEvilLibraryKey: <String>{},
        _kExposesEvilLibraryKey: <String>{},
        _kCallsMethodsOfEvilLibraryKey: <String>{},
        // Conditional imports? Other things?
      });
    } catch(e) {
      // Not a plugin
    }
  }
}

// Based on [ApiUseCollector]
class WebPluginsCollector extends RecursiveAstVisitor
    implements PreAnalysisCallback, PostAnalysisCallback, AstContext {

  int count = 0;
  String filePath;
  Folder currentFolder;
  LineInfo lineInfo;
  String get currentPlugin => path.basename(currentFolder.path);
  String get currentFile => filePath.replaceAll(currentFolder.path, '');

  WebPluginsCollector();

  // Returns filename@line:column - extra_info
  String _getPrettyLocation(int nodeOffset, String extraInfo) {
    var location = lineInfo.getLocation(nodeOffset);
    return '$currentFile@${location.lineNumber}:${location.columnNumber} - $extraInfo';
  }

  @override
  void preAnalysis(AnalysisContext context,
      {bool subDir, DriverCommands commandCallback}) {
    if (subDir) {
      ++dirCount;
    }
    currentFolder = context.contextRoot.root;
    String dirName = path.basename(context.contextRoot.root.path);

    print("Analyzing '$dirName' • [${++count}/$dirCount]...");
  }

  _shouldSkip() => !plugins.contains(currentPlugin);

  // Visits an import/export directive and sees if it's evil
  _visitImportExportDirective(NamespaceDirective node, String outputKey) {
    if (_shouldSkip()) return;

    if (evilLibraries.contains(node.uriContent)) {
      String info = _getPrettyLocation(node.offset, '${node.uriContent}');
      pluginMetadata[currentPlugin][outputKey].add(info);
    }
  }

  // Checks what plugins import problematic packages
  @override
  visitImportDirective(ImportDirective node) {
    _visitImportExportDirective(node, _kImportsEvilLibraryKey);
    return super.visitImportDirective(node);
  }

  // Checks if the plugin re-exports problematic packages
  @override
  visitExportDirective(ExportDirective node) {
    _visitImportExportDirective(node, _kExportsEvilLibraryKey);
    return super.visitExportDirective(node);
  }

  // Visit something that has a returnType and a name, and
  // probably is a function
  _visitFunctionOrMethodDeclaration(dynamic node) async {
    if (_shouldSkip()) return;

    DartType returnType = node.returnType?.type;
    DartType flattened;

    if (returnType?.element?.session != null) {
      TypeSystem ts = await returnType.element.session.typeSystem;
      flattened = ts.flatten(returnType); // Converts Future<T> and FutureOr<T> (and other <T>s) to T
    }

    String library = flattened?.element?.library?.identifier;

    if (evilLibraries.contains(library)) {
      bool isPrivate = node.name.name.startsWith('_');
      String info = _getPrettyLocation(node.offset, '$library - ${node.name.name}:${flattened.name}');
      if (isPrivate) {
        pluginMetadata[currentPlugin][_kUsesEvilLibraryKey].add(info);
      } else {
        pluginMetadata[currentPlugin][_kExposesEvilLibraryKey].add(info);
      }
    }

  }

  // Checks declared methods that return types of the evil packages
  @override
  visitMethodDeclaration(MethodDeclaration node) async {
    await _visitFunctionOrMethodDeclaration(node);
    return super.visitMethodDeclaration(node);
  }

  // Checks functions that return types of the evil packages
  @override
  visitFunctionDeclaration(FunctionDeclaration node) async {
    await _visitFunctionOrMethodDeclaration(node);
    return super.visitFunctionDeclaration(node);
  }

  // Checks what methods are being called
  @override
  visitMethodInvocation(MethodInvocation node) {
    if (_shouldSkip()) return null;

    // It seems realTarget may be null when calling naked functions
    DartType targetType = node.realTarget?.staticType ?? node.staticInvokeType;

    final String targetLibrary = targetType?.element?.library?.identifier;

    if (evilLibraries.contains(targetLibrary)) {
      String info = _getPrettyLocation(node.offset, '$targetLibrary - $targetType.${node.methodName.name}');
      pluginMetadata[currentPlugin][_kCallsMethodsOfEvilLibraryKey].add(info);
    }

    return super.visitMethodInvocation(node);
  }

  // Visit access properties on objects
  @override
  visitPropertyAccess(PropertyAccess node) {
    if (_shouldSkip()) return null;

    DartType targetType = node.realTarget?.staticType;
    final String targetLibrary = targetType?.element?.library?.identifier;

    if (evilLibraries.contains(targetLibrary)) {
      String info = _getPrettyLocation(node.offset, '$targetLibrary - $targetType.${node.propertyName.name}');
      pluginMetadata[currentPlugin][_kCallsMethodsOfEvilLibraryKey].add(info);
    }

    return super.visitPropertyAccess(node);
  }

  // Visits prefixed identifiers, like static getters (Platform.isIOS...)
  @override
  visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (_shouldSkip()) return null;

    DartType targetType = node.prefix.staticType;
    final String targetLibrary = targetType?.element?.library?.identifier;

    if (evilLibraries.contains(targetLibrary)) {
      String info = _getPrettyLocation(node.offset, '$targetLibrary - $targetType.${node.identifier.name}');
      pluginMetadata[currentPlugin][_kCallsMethodsOfEvilLibraryKey].add(info);
    }

    return super.visitPrefixedIdentifier(node);
  }

  @override
  void postAnalysis(AnalysisContext context, DriverCommands cmd) {
    cmd.continueAnalyzing = _debuglimit == null || count < _debuglimit;
  }

  @override
  void setLineInfo(LineInfo lineInfo) {
    this.lineInfo = lineInfo;
  }

  @override
  void setFilePath(String filePath) {
    this.filePath = filePath;
  }
}

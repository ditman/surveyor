import 'dart:async';
import 'dart:convert';
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
  'dart:_http', // Reexported from dart:io
  'dart:_internal', // Reexported from dart:io
};

final String _kCreatesInstanceKey = 'createsInstance';
final String _kImportsEvilLibraryKey = 'importsEvilLibrary';
final String _kUsesEvilLibraryKey = 'privateReturnsEvilLibrary';
final String _kExposesEvilLibraryKey = 'publicReturnsEvilLibrary';
final String _kCallsMethodsOfEvilLibraryKey = 'callsEvilLibrary';

final List<String> csvHeader = [
  "Plugin",
  "# Imports",
  "# Private returns",
  "# Public returns",
  "# Calls",
  "# Instantiations",
  "Popularity",
  "Overall score",
  "Imports",
  "Private returns",
  "Public returns",
  "Calls",
  "Instantiations",
];

/// Parses an index.json file produced by pub_crawl, and returns a Map that this script can use
Map<String, DownloadedPluginMetadata> _parseDownloadedMetadataFile(File json) {
  Map<String, DownloadedPluginMetadata> metadata = {};
  // Decode json...
  Map<String, dynamic> parsedJson = jsonDecode(json.readAsStringSync());
  // parsedJson is a Map<String, Map<String, dynamic>> but we need to shuffle the data
  parsedJson.forEach((String k, dynamic v) {
    String pluginName = v['sourcePath'];
    metadata[pluginName] = DownloadedPluginMetadata(score: v['score'], popularity: v['popularity'], name: k);
  });

  return metadata;
}

// https://github.com/dart-lang/sdk/issues/2626 :sad_trombone:
// typedef PluginProblems = Map<String, Map<String, Set<Problem>>>;

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
    File downloadedMetadata = File('$dir/../index.json');
    if (downloadedMetadata.existsSync()) {
      // Load it
      print("Metadata file found!");
      downloadPluginMetadata = _parseDownloadedMetadataFile(downloadedMetadata);
    }
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

  String csv =
      const ListToCsvConverter().convert(_formatOutput(pluginMetadata));

  print('Writing out.csv...');
  File('out.csv').writeAsStringSync(csv);

  print('Writing histograms...');

  String callsCsv = const ListToCsvConverter().convert(_formatHistogram(
      _getHistogram(pluginMetadata, _kCallsMethodsOfEvilLibraryKey), "Method"));
  File('calls.csv').writeAsStringSync(callsCsv);

  String constructorsCsv = const ListToCsvConverter().convert(_formatHistogram(
      _getHistogram(pluginMetadata, _kCreatesInstanceKey), "Constructor"));
  File('constructors.csv').writeAsStringSync(constructorsCsv);

  print(
      '(Elapsed time: ${Duration(milliseconds: stopwatch.elapsedMilliseconds)})');
}

class HistogramValue {
  int totalHits;
  Set<String> uniques = {};

  HistogramValue(value) {
    totalHits = 1;
    uniques.add(value);
  }

  void addHit(String value) {
    totalHits++;
    uniques.add(value);
  }

  @override
  String toString() {
    return '$totalHits - $uniques';
  }
}

// Counts all distincts values of a given 'key' in the set of Problems
Map<String, HistogramValue> _getHistogram(
    Map<String, Map<String, Set<Problem>>> metadata, String key) {
  Map<String, HistogramValue> histogram = <String, HistogramValue>{};

  metadata.forEach((String plugin, Map<String, Set<Problem>> meta) {
    meta[key].forEach((Problem problem) {
      histogram.update(problem.description,
          (HistogramValue currentValue) => currentValue..addHit(plugin),
          ifAbsent: () => HistogramValue(plugin));
    });
  });

  return histogram;
}

// Formats the histogram as CSV
List<List<dynamic>> _formatHistogram(
    Map<String, HistogramValue> histogram, String key) {
  List<List<dynamic>> out = [
    [key, "Count", "Uniques"]
  ];

  histogram.forEach((String description, HistogramValue value) {
    out.add([description, value.totalHits, value.uniques.length]);
  });

  return out;
}

// Formats the output 
List<List<dynamic>> _formatOutput(Map<String, Map<String, Set<Problem>>> metadata) {
  List<List<dynamic>> output = [csvHeader];

  metadata.forEach((String plugin, Map<String, Set<Problem>> meta) {
    // Warn of libraries where we detected imports, but nothing else!
    int numProblems = 0;
    int numImports = meta[_kImportsEvilLibraryKey].length;

    meta.forEach((key, Set<Problem> problems) {
      numProblems += problems.length;
    });

    bool shouldBeReviewed = 
      (numImports > 0 && (numProblems <= numImports)) // Unused imports?
      || (numImports == 0 && numProblems > 0) // Used bad lib without imports?
      || downloadPluginMetadata[plugin] == null; // How did we get here?

    if (shouldBeReviewed) {
      print('*** Needs review: $plugin');
    }

    output.add([
      plugin,
      meta[_kImportsEvilLibraryKey].length,
      meta[_kUsesEvilLibraryKey].length,
      meta[_kExposesEvilLibraryKey].length,
      meta[_kCallsMethodsOfEvilLibraryKey].length,
      meta[_kCreatesInstanceKey].length,
      downloadPluginMetadata[plugin]?.popularity ?? "",
      downloadPluginMetadata[plugin]?.score ?? "",
      meta[_kImportsEvilLibraryKey].join("\n"),
      meta[_kUsesEvilLibraryKey].join("\n"),
      meta[_kExposesEvilLibraryKey].join("\n"),
      meta[_kCallsMethodsOfEvilLibraryKey].join("\n"),
      meta[_kCreatesInstanceKey].join("\n"),
    ]);
  });

  return output;
}

int dirCount;

Set<String> plugins = {};
// plugin -> category -> Set<Problem>
Map<String, Map<String, Set<Problem>>> pluginMetadata = {};

// The metadata that was downloaded by pub_crawl
Map<String, DownloadedPluginMetadata> downloadPluginMetadata = {};

class DownloadedPluginMetadata {
  String name;
  double score;
  double popularity;
  DownloadedPluginMetadata({this.name, this.score, this.popularity});
  @override
  String toString() => 'Plugin: $name. Popularity: $popularity. Overall: $score';
}

class Problem {
  String location;
  String description;
  String library;
  Problem(this.location, this.description, [this.library]);
  @override
  String toString() =>
      '$location${library != null ? " - " + library : ""} - $description';
}

/// If non-zero, stops once limit is reached (for debugging).
int _debuglimit; // = 500;

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
        _kImportsEvilLibraryKey: <Problem>{},
        // _kExportsEvilLibraryKey: <String>{},
        _kUsesEvilLibraryKey: <Problem>{},
        _kExposesEvilLibraryKey: <Problem>{},
        _kCallsMethodsOfEvilLibraryKey: <Problem>{},
        _kCreatesInstanceKey: <Problem>{},
        // Conditional imports? Other things?
      });
    } catch (e) {
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
  Set<String> exports = <String>{}; // Keep track of the "exports" of this package, to see what's private/public

  WebPluginsCollector();

  // Returns a boolean indicating if the currently observed symbol is
  // considered public or private
  bool _isPrivate(int nodeOffset, {String methodName}) {
    if (methodName.startsWith('_')) {
      return true;
    } else {
      // Check if we're looking inside /lib
      String currentDir = path.dirname(currentFile);
      if (currentDir == '/lib') {
        return false; // Public method defined on public file -> public
      } else {
        // Check if the currentFile has been exported...
        final bool exported =
            exports.toList().any((export) => currentFile.endsWith(export));
        return !exported;
      }
    }
  }

  // Returns filename@line:column [extraInfo]
  String _getPrettyLocation(int nodeOffset, {String extraInfo}) {
    var location = lineInfo.getLocation(nodeOffset);
    String prettyLocation =
        '$currentFile@${location.lineNumber}:${location.columnNumber}';
    if (extraInfo != null) {
      prettyLocation += ' $extraInfo';
    }
    return prettyLocation;
  }

  // Converts Future<T> and FutureOr<T> (and other <T>s) to T
  FutureOr<DartType> _flattenType(DartType type) async {
    DartType flattened;

    // Speed up tdlib, because await typeSystem is slowww in that pkg (ended up deleting the pkg ;) )
    // if (!type.displayName.contains('<') || type.displayName.startsWith('Map<')) return type;
    if (type?.element?.session != null) {
      TypeSystem ts = await type.element.session.typeSystem;
      flattened = ts.flatten(type);
    }
    return flattened;
  }

  // Returns the name of the library where a (flattened) type is defined
  FutureOr<String> _getLibraryForType(DartType type) {
    return type?.element?.library?.identifier;
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
    if (evilLibraries.contains(node.uriContent)) {
      pluginMetadata[currentPlugin][outputKey]
          .add(Problem(_getPrettyLocation(node.offset), node.uriContent));
    }
  }

  // Checks what plugins import problematic packages
  @override
  visitImportDirective(ImportDirective node) {
    if (_shouldSkip()) return super.visitImportDirective(node);
    _visitImportExportDirective(node, _kImportsEvilLibraryKey);
    return super.visitImportDirective(node);
  }

  String _cleanExportUri(String uri) =>
      uri.replaceAll('./', '').replaceAll(RegExp(r"package:[^/]+/"), '');

  @override
  visitExportDirective(ExportDirective node) {
    if (_shouldSkip()) return super.visitExportDirective(node);
    exports.add(_cleanExportUri(node.uriContent));
    return super.visitExportDirective(node);
  }

  @override
  visitPartDirective(PartDirective node) {
    if (_shouldSkip()) return super.visitPartDirective(node);
    exports.add(_cleanExportUri(node.uriContent));
    return super.visitPartDirective(node);
  }

  // Checks if instantiation of ojects of classes from problematic packages
  @override
  visitInstanceCreationExpression(InstanceCreationExpression node) async {
    if (_shouldSkip()) return super.visitInstanceCreationExpression(node);
    DartType type = await _flattenType(node.staticType);
    String library = _getLibraryForType(type);

    if (evilLibraries.contains(library)) {
      pluginMetadata[currentPlugin][_kCreatesInstanceKey]
          .add(Problem(_getPrettyLocation(node.offset), type.toString()));
    }

    return super.visitInstanceCreationExpression(node);
  }

  // Visit something that has a returnType and a name, and
  // probably is a function
  _visitFunctionOrMethodDeclaration(dynamic node) async {
    DartType flattened = await _flattenType(node.returnType?.type);
    String library = _getLibraryForType(flattened);
    if (evilLibraries.contains(library)) {
      String methodName = node.name.name;
      bool isPrivate = _isPrivate(node.offset, methodName: methodName);
      if (isPrivate) {
        pluginMetadata[currentPlugin][_kUsesEvilLibraryKey].add(
          Problem(_getPrettyLocation(node.offset, extraInfo: methodName), flattened.name)
        );
      } else {
        pluginMetadata[currentPlugin][_kExposesEvilLibraryKey].add(
          Problem(_getPrettyLocation(node.offset, extraInfo: methodName), flattened.name)
        );
      }
    }
  }

  // Checks declared methods that return types of the evil packages
  @override
  visitMethodDeclaration(MethodDeclaration node) async {
    if (_shouldSkip()) return super.visitMethodDeclaration(node);
    await _visitFunctionOrMethodDeclaration(node);
    return super.visitMethodDeclaration(node);
  }

  // Checks functions that return types of the evil packages
  @override
  visitFunctionDeclaration(FunctionDeclaration node) async {
    if (_shouldSkip()) return super.visitFunctionDeclaration(node);
    await _visitFunctionOrMethodDeclaration(node);
    return super.visitFunctionDeclaration(node);
  }

  // Finds method calls of evil libraries (calls to getters/properties)
  _visitCallsOnEvilLibrary(DartType type, String name, dynamic node) {
    final String library = _getLibraryForType(type);

    if (evilLibraries.contains(library)) {
      pluginMetadata[currentPlugin][_kCallsMethodsOfEvilLibraryKey]
          .add(Problem(_getPrettyLocation(node.offset), '$type.$name'));
    }
  }

  // Checks what methods are being called
  @override
  visitMethodInvocation(MethodInvocation node) {
    if (_shouldSkip()) return super.visitMethodInvocation(node);

    // It seems realTarget may be null when calling naked functions
    DartType type = node.realTarget?.staticType ?? node.staticInvokeType;
    String name = node.methodName.name;
    _visitCallsOnEvilLibrary(type, name, node);

    return super.visitMethodInvocation(node);
  }

  // Visit access properties on objects
  @override
  visitPropertyAccess(PropertyAccess node) {
    if (_shouldSkip()) return super.visitPropertyAccess(node);

    DartType type = node.realTarget?.staticType;
    String name = node.propertyName.name;
    _visitCallsOnEvilLibrary(type, name, node);

    return super.visitPropertyAccess(node);
  }

  // Visits prefixed identifiers, like static getters (Platform.isIOS...)
  @override
  visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (_shouldSkip()) return super.visitPrefixedIdentifier(node);

    DartType type = node.prefix.staticType;
    String name = node.identifier.name;
    _visitCallsOnEvilLibrary(type, name, node);

    return super.visitPrefixedIdentifier(node);
  }

  @override
  void postAnalysis(AnalysisContext context, DriverCommands cmd) {
    exports = {};
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

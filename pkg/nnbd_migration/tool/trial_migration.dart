// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This is a hacked-together client of the NNBD migration API, intended for
// early testing of the migration process.  It runs a small hardcoded set of
// packages through the migration engine and outputs statistics about the
// result of migration, as well as categories (and counts) of exceptions that
// occurred.

import 'dart:io';

import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:args/args.dart';
import 'package:nnbd_migration/nnbd_migration.dart';
import 'package:path/path.dart' as path;

import 'src/multi_future_tracker.dart';
import 'src/package.dart';

ArgResults parseArguments(List<String> args) {
  ArgParser argParser = ArgParser();
  ArgResults parsedArgs;

  argParser.addFlag('clean',
      abbr: 'c',
      defaultsTo: false,
      help: 'Recursively delete the playground directory before beginning.');

  argParser.addFlag('help', abbr: 'h', help: 'Display options');

  argParser.addFlag('exception_node_only',
      defaultsTo: false,
      negatable: true,
      help: 'Only print the exception node instead of the full stack trace.');

  argParser.addFlag('update',
      abbr: 'u',
      defaultsTo: false,
      negatable: true,
      help: 'Auto-update fetched packages in the playground.');

  argParser.addOption('sdk',
      abbr: 's',
      defaultsTo: path.dirname(path.dirname(Platform.resolvedExecutable)),
      help: 'Select the root of the SDK to analyze against for this run '
          '(compiled with --nnbd).  For example: ../../xcodebuild/DebugX64NNBD/dart-sdk');

  argParser.addMultiOption(
    'git_packages',
    abbr: 'g',
    defaultsTo: [],
    help: 'Shallow-clone the given git repositories into a playground area,'
        ' run pub get on them, and migrate them.',
  );

  argParser.addMultiOption(
    'manual_packages',
    abbr: 'm',
    defaultsTo: [],
    help: 'Run migration against packages in these directories.  Does not '
        'run pub get, any git commands, or any other preparation.',
  );

  argParser.addMultiOption(
    'packages',
    abbr: 'p',
    defaultsTo: [],
    help: 'The list of SDK packages to run the migration against.',
  );

  try {
    parsedArgs = argParser.parse(args);
  } on ArgParserException {
    stderr.writeln(argParser.usage);
    exit(1);
  }
  if (parsedArgs['help'] as bool) {
    print(argParser.usage);
    exit(0);
  }

  if (parsedArgs.rest.length > 1) {
    throw 'invalid args. Specify *one* argument to get exceptions of interest.';
  }
  return parsedArgs;
}

main(List<String> args) async {
  ArgResults parsedArgs = parseArguments(args);

  Sdk sdk = Sdk(parsedArgs['sdk'] as String);

  warnOnNoAssertions();
  warnOnNoSdkNnbd(sdk);

  Playground playground =
      Playground(defaultPlaygroundPath, parsedArgs['clean'] as bool);

  List<Package> packages = [
    for (String package in parsedArgs['packages'] as Iterable<String>)
      SdkPackage(package),
    for (String package in parsedArgs['manual_packages'] as Iterable<String>)
      ManualPackage(package),
  ];

  // Limit the number of simultaneous git/pub commands.
  MultiFutureTracker futureTracker =
      MultiFutureTracker(Platform.numberOfProcessors);

  for (String package in parsedArgs['git_packages'] as Iterable<String>) {
    await futureTracker.addFutureFromClosure(() async => packages.add(
        await GitPackage.gitPackageFactory(
            package, playground, parsedArgs['update'] as bool)));
  }

  await futureTracker.wait();

  String categoryOfInterest =
      parsedArgs.rest.isEmpty ? null : parsedArgs.rest.single;

  var listener = _Listener(categoryOfInterest,
      printExceptionNodeOnly: parsedArgs['exception_node_only'] as bool);
  assert(listener.numExceptions == 0);
  for (var package in packages) {
    print('Migrating $package');
    var testUri = thisSdkUri.resolve(package.packagePath);
    var contextCollection = AnalysisContextCollectionImpl(
        includedPaths: [testUri.toFilePath()], sdkPath: sdk.sdkPath);

    var files = <String>{};
    var previousExceptionCount = listener.numExceptions;
    for (var context in contextCollection.contexts) {
      var localFiles =
          context.contextRoot.analyzedFiles().where((s) => s.endsWith('.dart'));
      files.addAll(localFiles);
      var migration = NullabilityMigration(listener, permissive: true);
      for (var file in localFiles) {
        var resolvedUnit = await context.currentSession.getResolvedUnit(file);
        migration.prepareInput(resolvedUnit);
      }
      for (var file in localFiles) {
        var resolvedUnit = await context.currentSession.getResolvedUnit(file);
        migration.processInput(resolvedUnit);
      }
      migration.finish();
    }

    print('  ${files.length} files found');
    var exceptionCount = listener.numExceptions - previousExceptionCount;
    print('  $exceptionCount exceptions in this package');
  }
  print('${listener.numTypesMadeNullable} types made nullable');
  print('${listener.numNullChecksAdded} null checks added');
  print('${listener.numMetaImportsAdded} meta imports added');
  print('${listener.numRequiredAnnotationsAdded} required annotations added');
  print('${listener.numDeadCodeSegmentsFound} dead code segments found');
  print('${listener.numExceptions} exceptions in '
      '${listener.groupedExceptions.length} categories');
  print('Exception categories:');
  var sortedExceptions = listener.groupedExceptions.entries.toList();
  sortedExceptions.sort((e1, e2) => e2.value.length.compareTo(e1.value.length));
  for (var entry in sortedExceptions) {
    print('  ${entry.key} (x${entry.value.length})');
  }

  if (categoryOfInterest == null) {
    print('\n(Note: to show stack traces & nodes for a particular failure,'
        ' rerun with a search string as an argument.)');
  }
}

void printWarning(String warn) {
  stderr.writeln('''
!!!
!!! Warning! $warn
!!!
''');
}

void warnOnNoAssertions() {
  try {
    assert(false);
  } catch (e) {
    return;
  }

  printWarning("You didn't --enable-asserts!");
}

void warnOnNoSdkNnbd(Sdk sdk) {
  try {
    if (sdk.isNnbdSdk) return;
  } catch (e) {
    printWarning('Unable to determine whether this SDK supports NNBD');
    return;
  }
  printWarning(
      'SDK at ${sdk.sdkPath} not compiled with --nnbd, use --sdk option');
}

class _Listener implements NullabilityMigrationListener {
  /// Set this to `true` to cause just the exception nodes to be printed when
  /// `_Listener.categoryOfInterest` is non-null.  Set this to `false` to cause
  /// the full stack trace to be printed.
  final bool printExceptionNodeOnly;

  /// Set this to a non-null value to cause any exception to be printed in full
  /// if its category contains the string.
  final String categoryOfInterest;

  final groupedExceptions = <String, List<String>>{};

  int numExceptions = 0;

  int numTypesMadeNullable = 0;

  int numNullChecksAdded = 0;

  int numMetaImportsAdded = 0;

  int numRequiredAnnotationsAdded = 0;

  int numDeadCodeSegmentsFound = 0;

  _Listener(this.categoryOfInterest, {this.printExceptionNodeOnly = false});

  @override
  void addEdit(SingleNullabilityFix fix, SourceEdit edit) {
    if (edit.replacement == '?' && edit.length == 0) {
      ++numTypesMadeNullable;
    } else if (edit.replacement == '!' && edit.length == 0) {
      ++numNullChecksAdded;
    } else if (edit.replacement == "import 'package:meta/meta.dart';\n" &&
        edit.length == 0) {
      ++numMetaImportsAdded;
    } else if (edit.replacement == 'required ' && edit.length == 0) {
      ++numRequiredAnnotationsAdded;
    } else if ((edit.replacement == '/* ' ||
            edit.replacement == ' /*' ||
            edit.replacement == '; /*') &&
        edit.length == 0) {
      ++numDeadCodeSegmentsFound;
    } else if ((edit.replacement == '*/ ' || edit.replacement == ' */') &&
        edit.length == 0) {
      // Already counted
    } else {
      print('addEdit($fix, $edit)');
    }
  }

  @override
  void addFix(SingleNullabilityFix fix) {}

  @override
  void reportException(
      Source source, AstNode node, Object exception, StackTrace stackTrace) {
    var category = _classifyStackTrace(stackTrace.toString().split('\n'));
    String detail = '''
In file $source
While processing $node
Exception $exception
$stackTrace
''';
    if (categoryOfInterest != null && category.contains(categoryOfInterest)) {
      if (printExceptionNodeOnly) {
        print('$node');
      } else {
        print(detail);
      }
    }
    (groupedExceptions[category] ??= []).add(detail);
    ++numExceptions;
  }

  String _classifyStackTrace(List<String> stackTrace) {
    for (var entry in stackTrace) {
      if (entry.contains('EdgeBuilder._unimplemented')) continue;
      if (entry.contains('_AssertionError._doThrowNew')) continue;
      if (entry.contains('_AssertionError._throwNew')) continue;
      if (entry.contains('NodeBuilder._unimplemented')) continue;
      if (entry.contains('Object.noSuchMethod')) continue;
      if (entry.contains('List.[] (dart:core-patch/growable_array.dart')) {
        continue;
      }
      return entry;
    }
    return '???';
  }
}

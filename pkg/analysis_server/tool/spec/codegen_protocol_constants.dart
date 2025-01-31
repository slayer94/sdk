// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_tool/tools.dart';

import 'api.dart';
import 'codegen_dart.dart';
import 'from_html.dart';

final GeneratedFile clientTarget = GeneratedFile(
    '../analysis_server_client/lib/src/protocol/protocol_constants.dart',
    (String pkgPath) async {
  CodegenVisitor visitor = CodegenVisitor(readApi(pkgPath));
  return visitor.collectCode(visitor.visitApi);
});

final GeneratedFile serverTarget = GeneratedFile(
    'lib/protocol/protocol_constants.dart', (String pkgPath) async {
  CodegenVisitor visitor = CodegenVisitor(readApi(pkgPath));
  return visitor.collectCode(visitor.visitApi);
});

/**
   * Generate a name from the [domainName], [kind] and [name] components.
   */
String generateConstName(String domainName, String kind, String name) {
  List<String> components = <String>[];
  components.addAll(_split(domainName));
  components.add(kind);
  components.addAll(_split(name));
  return _fromComponents(components);
}

/**
 * A visitor that produces Dart code defining constants associated with the API.
 */
class CodegenVisitor extends DartCodegenVisitor with CodeGenerator {
  CodegenVisitor(Api api) : super(api) {
    codeGeneratorSettings.commentLineLength = 79;
    codeGeneratorSettings.languageName = 'dart';
  }

  /**
   * Generate all of the constants associates with the [api].
   */
  void generateConstants() {
    writeln("const String PROTOCOL_VERSION = '${api.version}';");
    writeln();
    _ConstantVisitor visitor = _ConstantVisitor(api);
    visitor.visitApi();
    List<_Constant> constants = visitor.constants;
    constants.sort((first, second) => first.name.compareTo(second.name));
    for (_Constant constant in constants) {
      generateContant(constant);
    }
  }

  /**
   * Generate the given [constant].
   */
  void generateContant(_Constant constant) {
    write('const String ');
    write(constant.name);
    write(' = ');
    write(constant.value);
    writeln(';');
  }

  @override
  visitApi() {
    outputHeader(year: '2017');
    writeln();
    generateConstants();
  }
}

/**
 * A representation of a constant that is to be generated.
 */
class _Constant {
  /**
   * The name of the constant.
   */
  final String name;

  /**
   * The value of the constant.
   */
  final String value;

  /**
   * Initialize a newly created constant.
   */
  _Constant(this.name, this.value);
}

/**
 * A visitor that visits an API to compute a list of constants to be generated.
 */
class _ConstantVisitor extends HierarchicalApiVisitor {
  /**
   * The list of constants to be generated.
   */
  List<_Constant> constants = <_Constant>[];

  /**
   * Initialize a newly created visitor to visit the given [api].
   */
  _ConstantVisitor(Api api) : super(api);

  @override
  void visitNotification(Notification notification) {
    String domainName = notification.domainName;
    String event = notification.event;

    String constantName = generateConstName(domainName, 'notification', event);
    constants.add(_Constant(constantName, "'$domainName.$event'"));
    _addFieldConstants(constantName, notification.params);
  }

  @override
  void visitRequest(Request request) {
    String domainName = request.domainName;
    String method = request.method;

    String requestConstantName =
        generateConstName(domainName, 'request', method);
    constants.add(_Constant(requestConstantName, "'$domainName.$method'"));
    _addFieldConstants(requestConstantName, request.params);

    String responseConstantName =
        generateConstName(domainName, 'response', method);
    _addFieldConstants(responseConstantName, request.result);
  }

  /**
   * Generate a constant for each of the fields in the given [type], where the
   * name of each constant will be composed from the [parentName] and the name
   * of the field.
   */
  void _addFieldConstants(String parentName, TypeObject type) {
    if (type == null) {
      return;
    }
    type.fields.forEach((TypeObjectField field) {
      String name = field.name;
      List<String> components = <String>[];
      components.add(parentName);
      components.addAll(_split(name));
      String fieldConstantName = _fromComponents(components);
      constants.add(_Constant(fieldConstantName, "'$name'"));
    });
  }
}

/**
   * Return a name generated by converting each of the given [components] to an
   * uppercase equivalent, then joining them with underscores.
   */
String _fromComponents(List<String> components) =>
    components.map((String component) => component.toUpperCase()).join('_');

/**
   * Return the components of the given [string] that are indicated by an upper
   * case letter.
   */
Iterable<String> _split(String first) {
  RegExp regExp = RegExp('[A-Z]');
  List<String> components = <String>[];
  int start = 1;
  int index = first.indexOf(regExp, start);
  while (index >= 0) {
    components.add(first.substring(start - 1, index));
    start = index + 1;
    index = first.indexOf(regExp, start);
  }
  components.add(first.substring(start - 1));
  return components;
}

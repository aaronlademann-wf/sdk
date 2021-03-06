// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analysis_server/src/edit/nnbd_migration/migration_info.dart';
import 'package:analysis_server/src/edit/nnbd_migration/path_mapper.dart';
import 'package:analysis_server/src/edit/nnbd_migration/resources/resources.g.dart'
    as resources;
import 'package:path/path.dart' as path;

/// Instrumentation display output for a library that was migrated to use
/// non-nullable types.
class InstrumentationRenderer {
  /// Information for a whole migration, so that libraries can reference each
  /// other.
  final MigrationInfo migrationInfo;

  /// Whether the migration has been applied already or not.
  final bool hasBeenApplied;

  /// An object used to map the file paths of analyzed files to the file paths
  /// of the HTML files used to view the content of those files.
  final PathMapper pathMapper;

  /// Creates an output object for the given library info.
  InstrumentationRenderer(
      this.migrationInfo, this.pathMapper, this.hasBeenApplied);

  /// Returns the path context used to manipulate paths.
  path.Context get pathContext => migrationInfo.pathContext;

  /// Builds an HTML view of the instrumentation information.
  String render() {
    Map<String, String> variables = {
      'root': migrationInfo.includedRoot,
      'dartPageScript': resources.migration_js,
      'dartPageStyle': resources.migration_css,
      'highlightJsPath': migrationInfo.highlightJsPath,
      'highlightStylePath': migrationInfo.highlightStylePath,
      'sdkVersion': _dartSdkVersion,
      'migrationAppliedStyle': hasBeenApplied ? 'applied' : 'proposed',
    };

    return substituteVariables(resources.index_html, variables);
  }
}

String substituteVariables(String content, Map<String, String> variables) {
  for (String variable in variables.keys) {
    String value = variables[variable];
    content = content.replaceAll('{{ $variable }}', value);
  }

  return content;
}

String get _dartSdkVersion {
  String version = Platform.version;

  // Remove the build date and OS.
  if (version.contains(' ')) {
    version = version.substring(0, version.indexOf(' '));
  }

  // Convert a git hash to 8 chars.
  // '2.8.0-edge.fd992e423ef69ece9f44bd3ac58fa2355b563212'
  final RegExp versionRegExp = RegExp(r'^.*\.([0123456789abcdef]+)$');
  RegExpMatch match = versionRegExp.firstMatch(version);
  if (match != null && match.group(1).length == 40) {
    String commit = match.group(1);
    version = version.replaceAll(commit, commit.substring(0, 10));
  }

  return version;
}

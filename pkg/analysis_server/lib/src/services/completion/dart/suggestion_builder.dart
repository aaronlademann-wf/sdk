// Copyright (c) 2015, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/protocol_server.dart' as protocol;
import 'package:analysis_server/src/protocol_server.dart'
    hide Element, ElementKind;
import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analysis_server/src/services/completion/dart/utilities.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/visitor.dart';
import 'package:analyzer/src/util/comment.dart';

/**
 * Return a suggestion based upon the given element or `null` if a suggestion
 * is not appropriate for the given element.
 */
CompletionSuggestion createSuggestion(Element element,
    {String completion,
    CompletionSuggestionKind kind: CompletionSuggestionKind.INVOCATION,
    int relevance: DART_RELEVANCE_DEFAULT}) {
  if (element == null) {
    return null;
  }
  if (element is ExecutableElement && element.isOperator) {
    // Do not include operators in suggestions
    return null;
  }
  if (completion == null) {
    completion = element.displayName;
  }
  bool isDeprecated = element.hasDeprecated;
  CompletionSuggestion suggestion = new CompletionSuggestion(
      kind,
      isDeprecated ? DART_RELEVANCE_LOW : relevance,
      completion,
      completion.length,
      0,
      isDeprecated,
      false);

  // Attach docs.
  String doc = getDartDocPlainText(element.documentationComment);
  suggestion.docComplete = doc;
  suggestion.docSummary = getDartDocSummary(doc);

  suggestion.element = protocol.convertElement(element);
  Element enclosingElement = element.enclosingElement;
  if (enclosingElement is ClassElement) {
    suggestion.declaringType = enclosingElement.displayName;
  }
  suggestion.returnType = getReturnTypeString(element);
  if (element is ExecutableElement && element is! PropertyAccessorElement) {
    suggestion.parameterNames = element.parameters
        .map((ParameterElement parameter) => parameter.name)
        .toList();
    suggestion.parameterTypes =
        element.parameters.map((ParameterElement parameter) {
      DartType paramType = parameter.type;
      // Gracefully degrade if type not resolved yet
      return paramType != null ? paramType.displayName : 'var';
    }).toList();

    Iterable<ParameterElement> requiredParameters = element.parameters
        .where((ParameterElement param) => param.isNotOptional);
    suggestion.requiredParameterCount = requiredParameters.length;

    Iterable<ParameterElement> namedParameters =
        element.parameters.where((ParameterElement param) => param.isNamed);
    suggestion.hasNamedParameters = namedParameters.isNotEmpty;

    addDefaultArgDetails(
        suggestion, element, requiredParameters, namedParameters);
  }
  return suggestion;
}

/**
 * Common mixin for sharing behavior.
 */
mixin ElementSuggestionBuilder {
  /**
   * A collection of completion suggestions.
   */
  final List<CompletionSuggestion> suggestions = <CompletionSuggestion>[];

  /**
   * A set of existing completions used to prevent duplicate suggestions.
   */
  final Set<String> _completions = new Set<String>();

  /**
   * A map of element names to suggestions for synthetic getters and setters.
   */
  final Map<String, CompletionSuggestion> _syntheticMap =
      <String, CompletionSuggestion>{};

  /**
   * Return the library in which the completion is requested.
   */
  LibraryElement get containingLibrary;

  /**
   * Return the kind of suggestions that should be built.
   */
  CompletionSuggestionKind get kind;

  /**
   * Add a suggestion based upon the given element.
   */
  CompletionSuggestion addSuggestion(Element element,
      {String prefix,
      int relevance: DART_RELEVANCE_DEFAULT,
      String elementCompletion}) {
    if (element.isPrivate) {
      if (element.library != containingLibrary) {
        return null;
      }
    }
    String completion = elementCompletion ?? element.displayName;
    if (prefix != null && prefix.length > 0) {
      if (completion == null || completion.length <= 0) {
        completion = prefix;
      } else {
        completion = '$prefix.$completion';
      }
    }
    if (completion == null || completion.length <= 0) {
      return null;
    }
    CompletionSuggestion suggestion = createSuggestion(element,
        completion: completion, kind: kind, relevance: relevance);
    if (suggestion != null) {
      if (element.isSynthetic && element is PropertyAccessorElement) {
        String cacheKey;
        if (element.isGetter) {
          cacheKey = element.name;
        }
        if (element.isSetter) {
          cacheKey = element.name;
          cacheKey = cacheKey.substring(0, cacheKey.length - 1);
        }
        if (cacheKey != null) {
          CompletionSuggestion existingSuggestion = _syntheticMap[cacheKey];

          // Pair getter/setter by updating the existing suggestion
          if (existingSuggestion != null) {
            CompletionSuggestion getter =
                element.isGetter ? suggestion : existingSuggestion;
            protocol.ElementKind elemKind =
                element.enclosingElement is ClassElement
                    ? protocol.ElementKind.FIELD
                    : protocol.ElementKind.TOP_LEVEL_VARIABLE;
            existingSuggestion.element = new protocol.Element(
                elemKind,
                existingSuggestion.element.name,
                existingSuggestion.element.flags,
                location: getter.element.location,
                typeParameters: getter.element.typeParameters,
                parameters: null,
                returnType: getter.returnType);
            return existingSuggestion;
          }

          // Cache lone getter/setter so that it can be paired
          _syntheticMap[cacheKey] = suggestion;
        }
      }
      if (_completions.add(suggestion.completion)) {
        suggestions.add(suggestion);
      }
    }
    return suggestion;
  }
}

/**
 * This class creates suggestions based upon top-level elements.
 */
class LibraryElementSuggestionBuilder extends SimpleElementVisitor
    with ElementSuggestionBuilder {
  final LibraryElement containingLibrary;
  final CompletionSuggestionKind kind;
  final bool typesOnly;
  final bool instCreation;

  LibraryElementSuggestionBuilder(
      this.containingLibrary, this.kind, this.typesOnly, this.instCreation);

  @override
  visitClassElement(ClassElement element) {
    if (instCreation) {
      element.visitChildren(this);
    } else {
      addSuggestion(element);
    }
  }

  @override
  visitConstructorElement(ConstructorElement element) {
    if (instCreation) {
      ClassElement classElem = element.enclosingElement;
      if (classElem != null) {
        String prefix = classElem.name;
        if (prefix != null && prefix.length > 0) {
          addSuggestion(element, prefix: prefix);
        }
      }
    }
  }

  @override
  visitFunctionElement(FunctionElement element) {
    if (!typesOnly) {
      int relevance = element.library == containingLibrary
          ? DART_RELEVANCE_LOCAL_FUNCTION
          : DART_RELEVANCE_DEFAULT;
      addSuggestion(element, relevance: relevance);
    }
  }

  @override
  visitFunctionTypeAliasElement(FunctionTypeAliasElement element) {
    if (!instCreation) {
      addSuggestion(element);
    }
  }

  @override
  visitPropertyAccessorElement(PropertyAccessorElement element) {
    if (!typesOnly) {
      PropertyInducingElement variable = element.variable;
      int relevance = variable.library == containingLibrary
          ? DART_RELEVANCE_LOCAL_TOP_LEVEL_VARIABLE
          : DART_RELEVANCE_DEFAULT;
      addSuggestion(variable, relevance: relevance);
    }
  }
}
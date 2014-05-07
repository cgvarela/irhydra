// Copyright 2014 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/** Anotates source with information derived from IR. */
library modes.v8.source_annotator;

import 'package:irhydra/src/modes/ir.dart' as IR;
import 'package:js/js.dart' as js;

class _Range {
  final start;
  final end;

  _Range(this.start, this.end);

  contains(srcPos) =>
    start <= srcPos.position && srcPos.position < end;
}

class RangedLine {
  final str;
  final range;
  final column;
  
  RangedLine(this.str, this.range, this.column);
}

class _AST {
  static const PREFIX = "(function ";
  static const SUFFIX = ")";

  static final VISIT_SKIP = js.context.estraverse.VisitorOption.Skip;
  static final VISIT_BREAK = js.context.estraverse.VisitorOption.Break;

  final body;

  _AST.withBody(this.body);

  traverse({onEnter, onLeave}) =>
    js.context.estraverse.traverse(body, js.map({
      'enter': onEnter,
      'leave': onLeave
    }));


  // Helper function that accomondates for prefix length in ranges returned by Esprima.
  rangeOf(n) => new _Range(n.range[0] - PREFIX.length, n.range[1] - PREFIX.length);

  factory _AST(lines) {
    // Source is dumped in the form (args) { body }. We prepend SUFFIX and PREFIX
    // to make it parse as FunctionExpression: (function (args) { body }).
    // Sometime V8 also includes trailing comma into the source dump. Strip it.
    lines = lines.join('\n');
    lines = lines.substring(0, lines.lastIndexOf('}') + 1);
    var ast = null;
    try {
      ast = js.context.esprima.parse(PREFIX + lines + SUFFIX, js.map({'range': true}));
    } catch (e) {
      // Failed to parse the source. Most probably hit V8's %-syntax.
      return null;
    }
    final body = ast.body[0].expression.body;

    return new _AST.withBody(body);
  }

}

// TODO(mraleph): we pass parser as [irInfo] make a real IRInfo class.
annotate(IR.Method method, Map<String, IR.Block> blocks, irInfo) {
  final sources = method.sources.map((f) => f.source.toList()).toList();

  sourceId(IR.SourcePosition srcPos) => method.inlined[srcPos.inlineId].source.id;

  /// Compute positions ranges corresponding to the for/while loops in the source.
  /// We will later use this information to detected instructions moved by LICM.
  findLoops(ast) {
    if (ast == null) {
      return [];
    }
    
    final loops = [];
    ast.traverse(onEnter: (node, parent) {
      switch (node.type) {
        case 'FunctionExpression':
        case 'FunctionDeclaration':
          return _AST.VISIT_SKIP;

        case 'ForStatement':
          // Strip range covering init-clause of the for-loop from the
          // computed range of the loop. It is executed only once.
          final loopRange = ast.rangeOf(node),
                initRange = ast.rangeOf(node.init);
          loops.add(new _Range(initRange.end, loopRange.end));
          break;

        case 'WhileStatement':
        case 'DoWhileStatement':
          loops.add(ast.rangeOf(node));
          break;
      }
    });
    return loops;
  }

  final asts = sources.map((lines) => new _AST(lines)).toList();

  final loops = asts.map(findLoops).toList();

  final ranges = new List.generate(asts.length, (_) => {});

  rangeOf(srcPos) {
    final ast = asts[sourceId(srcPos)];
    if (ast == null) {
      return null;
    }
    
    var range = null;
    ast.traverse(
      onEnter: (node, parent) {
        switch (node.type) {
          case 'FunctionExpression':
          case 'FunctionDeclaration':
            return _AST.VISIT_SKIP;
        }

        if (!ast.rangeOf(node).contains(srcPos)) {
          return _AST.VISIT_SKIP;
        }
      },
      onLeave: (node, parent) {
        if (ast.rangeOf(node).contains(srcPos)) {
          range = ast.rangeOf(node);
          return _AST.VISIT_BREAK;
        }
      });
    return range;
  }

  /// Return the innermost loop covering given source position.
  loopOf(IR.SourcePosition srcPos) {
    if (srcPos == null) {  // First couple of blocks in the grap don't have positions attached.
      return -1;
    }

    final ls = loops[sourceId(srcPos)];
    // Loop ranges are sorted according to nesting by construction.
    // Iterate backwards to hit innermost loop first.
    for (var i = ls.length - 1; i >= 0; i--) {
      final range = ls[i];
      if (range.contains(srcPos)) {
        return i;
      }
    }
    return -1;
  }

  /// Return line number for the given source position.
  lineNum(IR.SourcePosition srcPos) {
    final lines = sources[sourceId(srcPos)];

    var line = 0, ch = srcPos.position;
    while ((line < lines.length) && (ch > lines[line].length)) {
      ch -= lines[line].length + 1;
      line++;
    }
    return line;
  }

  columnNum(IR.SourcePosition srcPos) {
    final lines = sources[sourceId(srcPos)];

    var line = 0, ch = srcPos.position;
    while ((line < lines.length) && (ch > lines[line].length)) {
      ch -= lines[line].length + 1;
      line++;
    }

    return ch;
  }

  lineStr(IR.SourcePosition srcPos) {
    final lines = sources[sourceId(srcPos)];
    final n = lineNum(srcPos);
    return n < lines.length ? lines[n] : null; 
  }

  rangeStr(srcPos) {
    final lineNo = lineNum(srcPos);
    final line = lineStr(srcPos);

    final range = rangeOf(srcPos);
    if (range == null) {
      return line;
    }

    final startLn = lineNum(new IR.SourcePosition(srcPos.inlineId, range.start));
    final endLn = lineNum(new IR.SourcePosition(srcPos.inlineId, range.end));

    var chRange = null;
    if (startLn == lineNo && (endLn == lineNo || endLn == lineNo + 1)) {
      final startCh = columnNum(new IR.SourcePosition(srcPos.inlineId, range.start));
      final endCh = columnNum(new IR.SourcePosition(srcPos.inlineId, range.end));
      chRange = new _Range(startCh, endCh);
    }
    
    return new RangedLine(line, chRange, columnNum(srcPos));
  }

  // Attach annotation arrays to all inlined functions.
  final annotations = method.inlined.map((f) =>
      f.annotations = new List.filled(sources[f.source.id].length, IR.LINE_DEAD)).toList();

  final mapping = method.srcMapping = {};

  for (var block in blocks.values) {
    if (block.lir != null) {
      final blockLoop = loopOf(irInfo.hir2pos[block.hir.firstWhere((instr) => instr.op == "BlockEntry").id]);

      var previous = null;
      for (var instr in block.lir.where(_isInterestingOp)) {
        final hirId = irInfo.lir2hir[instr.id];
        if (hirId == null) continue;

        final srcPos = irInfo.hir2pos[hirId];
        if (srcPos == null || previous == srcPos) continue;

        mapping[hirId] = rangeStr(srcPos);
        previous = srcPos;
      }
    }

  }


  // Process IR and mark lines according to IR instructions that were generated from them.
  for (var block in blocks.values) {
    if (block.lir != null) {
      final blockLoop = loopOf(irInfo.hir2pos[block.hir.firstWhere((instr) => instr.op == "BlockEntry").id]);

      // When processing LIR skip all artificial instructions (gap moves,
      // labels, gotos and stack-checks). Even if they have position falling
      // into some line, that does not make that line alive.
      for (var instr in block.lir.where(_isInterestingOp)) {
        final hirId = irInfo.lir2hir[instr.id];
        if (hirId == null) continue;

        final srcPos = irInfo.hir2pos[hirId];
        if (srcPos == null) continue;

        // Before marking the line alive check if instruction was hoisted by
        // LICM from its loop.
        final instrLoop = loopOf(srcPos);
        if (instrLoop != null && blockLoop < instrLoop) {
          // Instruction was hoisted from its loop. Mark the line as LICMed.
          annotations[srcPos.inlineId][lineNum(srcPos)] |= IR.LINE_LICM;
        } else {
          annotations[srcPos.inlineId][lineNum(srcPos)] |= IR.LINE_LIVE;
        }
      }
    }
  }
}

/// Returns "true" is instruction is not one of artificial instructions
/// produced for internal reasons.
_isInterestingOp(instr) {
  switch (instr.op) {
    case "gap":  // Gap move produced by regalloc.
    case "label":  // Branch target.
    case "goto":   // Unconditional branch.
    case "stack-check":  // Interrupt check.
      return false;
    default:
      return true;
  }
}

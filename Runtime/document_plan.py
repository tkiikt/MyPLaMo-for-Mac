"""Lossless translation ranges for pasted documents. JSON stdin/stdout; no network.
Offsets crossing the Swift boundary are UTF-16 code units, never Python indices.
"""
import json
import re
import sys

MAX_SOURCE = 200_000
FORMATS = {'auto', 'text', 'markdown', 'json', 'yaml'}


def has_text(value):
    return any(c.isalpha() for c in value) and not re.match(r'^(?:[a-z][a-z0-9+.-]*://|/|\$\{|[A-Z]:\\|\S+@\S+\.\S+)', value.strip(), re.I)


def utf16_len(value):
    return len(value.encode('utf-16-le')) // 2


def strict_json(source):
    def invalid(value):
        raise ValueError('JSONに無効な数値が含まれています: ' + value)
    return json.loads(source, parse_constant=invalid)


def yaml_documents(source):
    import yaml
    return list(yaml.compose_all(source, Loader=yaml.SafeLoader))


def detect(source):
    if source.lstrip().startswith(('{', '[')):
        try:
            strict_json(source)
            return 'json'
        except ValueError:
            pass
    if re.search(r'(?m)^(?:#{1,6} |```|~~~|\s*[-*+] |\|)|\[[^\]]+\]\(|\*\*|`[^`]+`', source):
        return 'markdown'
    if re.search(r'(?m)^\s*[\w.-]+:\s+\S', source):
        return 'yaml'
    return 'text'


def json_spans(source):
    strict_json(source)
    spans = []
    i = 0
    while i < len(source):
        if source[i] != '"':
            i += 1
            continue
        value, end = json.decoder.scanstring(source, i + 1, True)
        following = source[end:].lstrip()
        if not following.startswith(':') and has_text(value):
            spans.append((i, end, value, {'kind': 'json'}))
        i = end
    return spans


def yaml_spans(source):
    import yaml
    from yaml.events import MappingStartEvent, SequenceStartEvent, MappingEndEvent, SequenceEndEvent, ScalarEvent, AliasEvent
    from yaml.nodes import ScalarNode
    yaml_documents(source)  # Validate input and resolved scalar types first.
    stack, spans = [], []
    loader = yaml.SafeLoader('')
    try:
        for event in yaml.parse(source):
            parent = stack[-1] if stack else None
            key = bool(parent and parent['mapping'] and parent['key'])
            suppressed = key or bool(parent and parent['suppressed'])
            if isinstance(event, (MappingStartEvent, SequenceStartEvent)):
                if parent and parent['mapping']:
                    parent['key'] = not parent['key']
                stack.append({'mapping': isinstance(event, MappingStartEvent), 'key': isinstance(event, MappingStartEvent), 'suppressed': suppressed or bool(event.anchor or event.tag)})
            elif isinstance(event, (MappingEndEvent, SequenceEndEvent)):
                stack.pop()
            elif isinstance(event, (ScalarEvent, AliasEvent)):
                if isinstance(event, ScalarEvent) and not suppressed and not event.anchor and not event.tag and has_text(event.value):
                    tag = loader.resolve(ScalarNode, event.value, event.implicit)
                    if tag == 'tag:yaml.org,2002:str':
                        start, end = event.start_mark.index, event.end_mark.index
                        original = source[start:end]
                        encoding = {'kind': 'yaml', 'style': event.style or ''}
                        text = event.value
                        if event.style in ('|', '>'):
                            line_end = original.find('\n')
                            if line_end < 0:
                                continue
                            body = original[line_end + 1:]
                            lines = body.splitlines(keepends=True)
                            nonblank = [len(line) - len(line.lstrip(' ')) for line in lines if line.strip()]
                            indent = ' ' * (min(nonblank) if nonblank else event.start_mark.column + 1)
                            text = ''.join(line[len(indent):] if line.startswith(indent) else line for line in lines)
                            encoding.update(header=original[:line_end + 1], indent=indent, body=body,
                                            newline='\r\n' if '\r\n' in original else '\n',
                                            trailing=original.endswith('\n'))
                        spans.append((start, end, text, encoding))
                if parent and parent['mapping']:
                    parent['key'] = not parent['key']
    finally:
        loader.dispose()
    return spans


def markdown_spans(source):
    from markdown_it import MarkdownIt
    # Front matter is deliberately excluded, including its delimiters.
    prefix = 0
    front = re.match(r'\A(?:\ufeff)?---[ \t]*\r?\n', source)
    if front:
        closing = re.search(r'(?m)^(?:---|\.\.\.)[ \t]*(?:\r?\n|$)', source[front.end():])
        if closing:
            prefix = front.end() + closing.end()
    body = source[prefix:]
    lines = body.splitlines(keepends=True)
    offsets = [prefix]
    for line in lines:
        offsets.append(offsets[-1] + len(line))
    md = MarkdownIt('commonmark', {'html': True}).enable('table').enable('strikethrough')
    environment = {}
    tokens = md.parse(body, environment)
    # Instrument the parser's literal-text rule. Links recursively tokenize their
    # labels; URL destinations, code, HTML and autolinks never pass through here.
    text_rule = next(rule for rule in md.inline.ruler.getRules('') if rule.__name__ == 'text')
    collected = []
    active_source = None
    def capture(state, silent):
        start = state.pos
        result = text_rule(state, silent)
        if result and not silent and state.src is active_source:
            collected.append((start, state.pos))
        return result
    md.inline.ruler.at('text', capture)
    spans, cursors = [], {}
    for token in tokens:
        if token.type != 'inline' or token.map is None:
            continue
        first, last = token.map
        lower, upper = offsets[first], offsets[min(last, len(lines))]
        # Inline text strips block/list indentation. Map every retained character
        # back to its original source line rather than reconstructing Markdown.
        content = token.content
        position = max(lower, cursors.get((first, last), lower))
        mapping = []
        valid = True
        for line in content.splitlines(keepends=True):
            core = line.rstrip('\r\n')
            found = source.find(core, position, upper) if core else position
            if found < 0:
                # Table parsing removes the backslash before an escaped pipe.
                # Keep its original source position protected, while mapping
                # the surrounding prose to its exact original offsets.
                normalized, indices = [], []
                scan = position
                while scan < upper:
                    if source[scan:scan + 2] == "\\|":
                        scan += 1
                    normalized.append(source[scan]); indices.append(scan); scan += 1
                match = ''.join(normalized).find(core)
                if match < 0:
                    valid = False
                    break
                line_mapping = indices[match:match + len(core)]
                mapping.extend(line_mapping)
                position = line_mapping[-1] + 1 if line_mapping else position
            else:
                mapping.extend(range(found, found + len(core)))
                position = found + len(core)
            for character in line[len(core):]:
                newline = source.find(character, position, upper)
                if newline < 0:
                    valid = False
                    break
                mapping.append(newline)
                position = newline + 1
        if not valid or len(mapping) != len(content):
            # Ambiguous source mapping is preserved rather than damaged.
            continue
        cursors[(first, last)] = position
        collected.clear()
        active_source = content
        md.inline.parse(content, md, environment, [])
        protected_ranges = [(m.start(), m.end()) for m in re.finditer(r'(?:[A-Za-z][A-Za-z0-9+.-]*://[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,})', content)]
        # Footnote identifiers and shortcut/collapsed reference labels are
        # semantic keys. Translating them would break their destinations.
        protected_ranges.extend((m.start(), m.end()) for m in re.finditer(r'\[\^[^\]\n]+\]', content))
        from markdown_it.common.utils import normalizeReference
        references = environment.get('references', {})
        for reference in re.finditer(r'\[([^\]\n]+)\](\[\])?', content):
            following = content[reference.end():reference.end() + 1]
            if following in ('(', '[') and not reference.group(2):
                continue
            if normalizeReference(reference.group(1)) in references:
                protected_ranges.append((reference.start(), reference.end()))
        checkbox = re.match(r'^\[[ xX]\](?=\s)', content)
        if checkbox:
            protected_ranges.append((0, checkbox.end()))
        protected_ranges.extend((i, i + 1) for i, char in enumerate(content) if char == '|' and mapping[i] > 0 and source[mapping[i] - 1] == '\\')
        protected_ranges.sort()
        for start, end in collected:
            text = content[start:end]
            if not text or not has_text(text):
                continue
            # Preserve bare URLs/emails even inside otherwise natural prose.
            cursor = start
            for protected_start, protected_end in protected_ranges:
                if protected_end <= start or protected_start >= end:
                    continue
                a, b = max(start, protected_start), min(end, protected_end)
                if a > cursor and has_text(content[cursor:a]):
                    spans.append((mapping[cursor], mapping[a - 1] + 1, content[cursor:a], {'kind': 'markdown'}))
                cursor = b
            if cursor < end and has_text(content[cursor:end]):
                spans.append((mapping[cursor], mapping[end - 1] + 1, content[cursor:end], {'kind': 'markdown'}))
    return spans


def plan(source, format_name):
    if not isinstance(source, str) or len(source) > MAX_SOURCE:
        raise ValueError('文書が長すぎるか、形式が正しくありません。')
    if format_name not in FORMATS:
        raise ValueError('文書形式が正しくありません。')
    if '<|plamo:' in source:
        raise ValueError('文書にモデルの制御記号が含まれています。')
    resolved = detect(source) if format_name == 'auto' else format_name
    spans = {'text': lambda s: [(0, len(s), s, {'kind': 'text'})],
             'json': json_spans, 'yaml': yaml_spans, 'markdown': markdown_spans}[resolved](source)
    result, last = [], 0
    for start, end, text, encoding in sorted(spans):
        if start < last or not 0 <= start <= end <= len(source):
            raise ValueError('翻訳範囲を安全に解析できませんでした。')
        last = end
        result.append({'start': utf16_len(source[:start]), 'end': utf16_len(source[:end]), 'text': text, 'encoding': encoding})
    return {'source': source, 'format': resolved, 'spans': result}


def encode(text, encoding):
    kind = encoding['kind']
    if kind == 'text':
        return text
    if kind == 'json':
        return json.dumps(text, ensure_ascii=False)
    if kind == 'markdown':
        # A model can return syntax punctuation even when the source was prose.
        return re.sub(r'([\\`*_{}\[\]<>#|~!+\-=.])', r'\\\1', text)
    style = encoding.get('style', '')
    if style == "'":
        return "'" + text.replace("'", "''") + "'"
    if style in ('|', '>') and 'header' in encoding:
        normalized = text.replace('\r\n', '\n').replace('\r', '\n')
        if encoding['trailing'] and not normalized.endswith('\n'):
            normalized += '\n'
        original_lines = encoding.get('body', '').replace('\r\n', '\n').split('\n')
        encoded_lines = []
        lines = normalized.split('\n')
        for index, line in enumerate(lines):
            if line:
                encoded_lines.append(encoding['indent'] + line)
            elif index < len(original_lines) and not original_lines[index].strip():
                encoded_lines.append(original_lines[index])
            else:
                encoded_lines.append('')
        return encoding['header'] + encoding['newline'].join(encoded_lines)
    if style == '"':
        return json.dumps(text, ensure_ascii=False)
    # Quote plain scalars if their translated spelling could affect YAML types
    # or structure. safe_load checks dates, booleans, numbers, null and aliases.
    import yaml
    try:
        value = yaml.safe_load(text)
    except yaml.YAMLError:
        value = None
    if not isinstance(value, str) or value != text or re.search(r'[:#\[\]{},&*!|>\'"%@`\r\n]|^[-? ]| $', text):
        return json.dumps(text, ensure_ascii=False)
    return text


def shape(value, seen=None):
    # String values may change. Keys and every other scalar type/value may not.
    seen = set() if seen is None else seen
    if isinstance(value, (dict, list)):
        if id(value) in seen:
            return ('alias',)
        seen.add(id(value))
    if isinstance(value, dict):
        return ('map', tuple((repr(k), shape(v, seen)) for k, v in value.items()))
    if isinstance(value, list):
        return ('list', tuple(shape(v, seen) for v in value))
    return ('str',) if isinstance(value, str) else (type(value).__name__, repr(value))


def yaml_shape(documents):
    from yaml.nodes import ScalarNode, MappingNode
    seen = set()
    def visit(node, key=False):
        if node is None:
            return None
        if id(node) in seen:
            return ('alias', node.tag)
        seen.add(id(node))
        if isinstance(node, ScalarNode):
            return (node.tag, node.value if key or node.tag != 'tag:yaml.org,2002:str' else '*')
        if isinstance(node, MappingNode):
            return (node.tag, tuple((visit(k, True), visit(v, key)) for k, v in node.value))
        return (node.tag, tuple(visit(v, key) for v in node.value))
    return tuple(visit(node) for node in documents)


def render(document, translations):
    source = document['source']
    spans = document['spans']
    if len(translations) != len(spans) or not all(isinstance(t, str) for t in translations):
        raise ValueError('翻訳結果の数または形式が正しくありません。')
    # Re-parse to prevent arbitrary externally constructed ranges/encodings.
    actual = plan(source, document['format'])
    if actual != document:
        raise ValueError('文書の翻訳範囲が変化しました。再度翻訳してください。')
    raw = source.encode('utf-16-le')
    pieces, position = [], 0
    for span, translation in zip(spans, translations):
        start, end = span['start'] * 2, span['end'] * 2
        pieces.append(raw[position:start].decode('utf-16-le'))
        pieces.append(encode(translation, span['encoding']))
        position = end
    pieces.append(raw[position:].decode('utf-16-le'))
    output = ''.join(pieces)
    if document['format'] == 'json':
        if shape(strict_json(source)) != shape(strict_json(output)):
            raise ValueError('翻訳結果のJSON構造が変化しました。')
    elif document['format'] == 'yaml':
        if yaml_shape(yaml_documents(source)) != yaml_shape(yaml_documents(output)):
            raise ValueError('翻訳結果のYAML構造が変化しました。')
    return output


def main():
    try:
        request = json.load(sys.stdin)
        if request.get('action') == 'plan':
            response = {'plan': plan(request['source'], request.get('format', 'auto'))}
        elif request.get('action') == 'render':
            response = {'text': render(request['plan'], request['translations'])}
        else:
            raise ValueError('不明な文書処理です。')
        json.dump(response, sys.stdout, ensure_ascii=False)
    except Exception as error:
        json.dump({'error': '文書を処理できません: ' + str(error)}, sys.stdout, ensure_ascii=False)

if __name__ == '__main__':
    main()

import importlib.util
from pathlib import Path
import unittest
import json

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('document_plan', ROOT / 'Runtime/document_plan.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

class DocumentTests(unittest.TestCase):
    def render(self, source, kind, translation='翻訳'):
        plan = d.plan(source, kind)
        output = d.render(plan, [translation if not callable(translation) else translation(s['text']) for s in plan['spans']])
        return plan, output

    def test_json_keys_types_urls_crlf_unicode(self):
        source = '{\r\n  "日本😀": "Hello 😀", "url": "https://example.test/a", "n": 3, "b": true, "empty": null, "nested": ["Welcome", false]\r\n}'
        plan, output = self.render(source, 'json', '訳"文\\\n😀')
        self.assertEqual([s['text'] for s in plan['spans']], ['Hello 😀', 'Welcome'])
        self.assertEqual(output.count('\r\n'), 2)
        result = json.loads(output)
        self.assertEqual(result['url'], 'https://example.test/a')
        self.assertEqual(result['n'], 3)
        self.assertEqual(result['日本😀'], '訳"文\\\n😀')
        first = plan['spans'][0]
        self.assertEqual(source.encode('utf-16-le')[first['start']*2:first['end']*2].decode('utf-16-le'), '"Hello 😀"')

    def test_json_invalid(self):
        for value in ['{"a":}', '{"a":NaN}', '["hello",]', '{"a":"bad\n"}']:
            with self.assertRaises(ValueError): d.plan(value, 'json')

    def test_yaml_types_comments_quotes_flow(self):
        source = '# comment\r\nname: Hello # retained\r\nitems: [World, 123, true, null, 2026-11-12]\r\nurl: https://example.test\r\nquoted: \'It\'\'s good\'\r\n'
        plan, output = self.render(source, 'yaml', 'true')
        self.assertEqual(len(plan['spans']), 3)
        self.assertIn('name: "true" # retained\r\n', output)
        self.assertIn('items: ["true", 123, true, null, 2026-11-12]', output)
        self.assertIn("quoted: 'true'", output)
        self.assertIn('url: https://example.test', output)
        self.assertEqual(source.count('\r\n'), output.count('\r\n'))

    def test_yaml_anchors_tags_aliases_and_keys_preserved(self):
        source = 'base: &anchor Hello\ncopy: *anchor\ntagged: !custom Keep me\n!!str special: World\n'
        plan, output = self.render(source, 'yaml')
        self.assertEqual([s['text'] for s in plan['spans']], ['World'])
        self.assertIn('base: &anchor Hello\ncopy: *anchor\ntagged: !custom Keep me\n!!str special: 翻訳', output)

    def test_yaml_block_literal_folded_crlf(self):
        source = 'description: |+ # header\r\n  First line\r\n  Second line\r\n\r\nfold: >-\r\n  Third line\r\n  Fourth line\r\nlast: false\r\n'
        plan, output = self.render(source, 'yaml', lambda text: text.replace('line', '行'))
        self.assertIn('|+ # header\r\n', output)
        self.assertIn('  First 行\r\n  Second 行', output)
        self.assertIn('>-\r\n  Third 行\r\n  Fourth 行', output)
        self.assertTrue(output.endswith('last: false\r\n'))
        self.assertEqual(len(plan['spans']), 2)
        self.assertEqual(output, source.replace('line', '行'))

    def test_yaml_numeric_translation_remains_string(self):
        import yaml
        for translated in ['123', 'true', 'null', '2026-11-12', '*alias', 'a: b', 'x # comment']:
            _, output = self.render('key: Hello\n', 'yaml', translated)
            self.assertEqual(yaml.safe_load(output)['key'], translated)

    def test_yaml_invalid(self):
        for value in ['x: [a,', 'a: *missing', 'a:\n  b: c\n d: e']:
            with self.assertRaises(Exception): d.plan(value, 'yaml')

    def test_markdown_preserves_syntax_and_frontmatter(self):
        source = '---\r\ntitle: Keep me\r\n---\r\n# Hello **world**\r\n\r\n- Read [the manual](https://example.test "Title")\r\n\r\n| Name | Value |\r\n| --- | --- |\r\n| Hello | World |\r\n\r\n```py\r\nprint("Keep code")\r\n```\r\n`inline code` <https://example.test>\r\n'
        plan, output = self.render(source, 'markdown', '訳|*[]')
        self.assertTrue(output.startswith('---\r\ntitle: Keep me\r\n---\r\n# '))
        self.assertIn('(https://example.test "Title")', output)
        self.assertIn('```py\r\nprint("Keep code")\r\n```', output)
        self.assertIn('`inline code` <https://example.test>', output)
        self.assertIn('| --- | --- |', output)
        self.assertIn('訳\\|\\*\\[\\]', output)
        self.assertEqual(source.count('\r\n'), output.count('\r\n'))
        self.assertNotIn('Keep code', [s['text'] for s in plan['spans']])

    def test_markdown_reference_link_and_bare_url(self):
        source = '[Read guide][manual]\n\n[manual]: https://example.test "Reference"\n\nVisit https://example.test/path now.\n'
        plan, output = self.render(source, 'markdown')
        self.assertIn('[翻訳][manual]', output)
        self.assertIn('[manual]: https://example.test "Reference"', output)
        self.assertIn('https://example.test/path', output)
        self.assertNotIn('manual', [s['text'] for s in plan['spans']])

    def test_markdown_reference_identifiers_are_preserved(self):
        source = 'See [manual] and [manual][] and [Read][manual]. Note[^first].\n\n[manual]: https://example.test\n\n[^first]: Footnote words\n'
        _, output = self.render(source, 'markdown', lambda text: '訳' + text)
        self.assertIn('[manual] and', source)
        self.assertIn('[manual]', output)
        self.assertIn('[manual][]', output)
        self.assertIn('[訳Read][manual]', output)
        self.assertIn('[^first]', output)
        self.assertIn('[manual]: https://example.test', output)
        self.assertIn('[^first]:', output)

    def test_markdown_tasks_and_escaped_table_pipe(self):
        source = '- [ ] Task name\n- [x] Done item\n\n| Header | Second |\n| --- | --- |\n| escaped \\| text | Hello |\n'
        plan, output = self.render(source, 'markdown', lambda text: text.replace('Task name', '作業').replace('Done item', '完了').replace('escaped', 'エスケープ').replace('text', '文章'))
        self.assertIn('- [ ] 作業\n- [x] 完了', output)
        self.assertIn('エスケープ \\| 文章', output)
        self.assertNotIn('x', [s['text'] for s in plan['spans']])

    def test_markdown_nested_list_unicode_ranges(self):
        source = '> 日本😀 **Hello**\n> more words\n\n1. First\n   continuation\n   - Nested\n'
        plan, output = self.render(source, 'markdown', lambda s: s.replace('Hello','こんにちは'))
        self.assertEqual(output, source.replace('Hello', 'こんにちは'))

    def test_auto_and_text(self):
        self.assertEqual(d.plan('{"a":"Hello"}', 'auto')['format'], 'json')
        self.assertEqual(d.plan('# Hello', 'auto')['format'], 'markdown')
        self.assertEqual(d.plan('key: Hello', 'auto')['format'], 'yaml')
        self.assertEqual(d.plan('Hello', 'auto')['format'], 'text')
        p = d.plan('  Hello\r\n\r\n World  ', 'text')
        self.assertEqual(len(p['spans']), 1)
        self.assertEqual(d.render(p, [p['source']]), p['source'])

    def test_rejects_changed_plan_and_control_tokens(self):
        with self.assertRaises(ValueError): d.plan('<|plamo:tag|>x', 'text')
        p = d.plan('{"a":"Hello"}', 'json'); p['spans'][0]['start'] = 0
        with self.assertRaises(ValueError): d.render(p, ['Hi'])

if __name__ == '__main__': unittest.main()

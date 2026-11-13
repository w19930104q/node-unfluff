suite 'Blocks', ->
  _ = require('lodash')
  extractor = require("../src/unfluff")

  fixtureHtml = ->
    fs.readFileSync("./fixtures/test_blocks.html").toString()

  test 'is not part of the default eager return shape', ->
    data = extractor(fixtureHtml())
    ok !('blocks' of data), 'blocks key must be absent unless explicitly enabled'

  test 'is not part of the default lazy return shape', ->
    data = extractor.lazy(fixtureHtml())
    ok !('blocks' of data), 'blocks accessor must be absent unless explicitly enabled'

  test 'returns headings with their levels including very short titles', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    headings = (block for block in data.blocks when block.type == 'heading')
    deepEq (h.text for h in headings), ['Short', 'Setup', 'Tiny', 'Code samples', 'Closing']
    deepEq (h.level for h in headings), [1, 2, 3, 2, 2]

  test 'preserves code whitespace, blank lines and the language marker', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    codeBlocks = (block for block in data.blocks when block.type == 'code')
    eq codeBlocks.length, 2

    eq codeBlocks[0].language, 'javascript'
    eq codeBlocks[0].text, "function greet(name) {\n  const message = `hello ${name}`;\n\n  return message && message.toUpperCase();\n}"

    # No language hint => null, but newlines and leading indentation survive.
    eq codeBlocks[1].language, null
    eq codeBlocks[1].text, "    indented first line\nsecond line\n\n  third line after blank"

  test 'keeps inline code inside its paragraph instead of a code block', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    inlinePara = _.find data.blocks, (b) ->
      b.type == 'paragraph' && b.text.indexOf('Inline code such as npm test') == 0
    ok inlinePara, 'the inline-code paragraph must survive as a single paragraph'

  test 'emits ordered and unordered lists with nested lists and start index', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    lists = (block for block in data.blocks when block.type == 'list')
    eq lists.length, 2

    ordered = lists[0]
    eq ordered.ordered, true
    eq ordered.start, 3
    eq ordered.items.length, 3
    eq ordered.items[0].text, 'First numbered item with enough ordinary words to look like prose.'

    nested = ordered.items[1].blocks[0]
    eq nested.type, 'list'
    eq nested.ordered, false
    eq nested.items.length, 2

    unordered = lists[1]
    eq unordered.ordered, false
    ok !('start' of unordered), 'unordered lists must not carry a start field'

  test 'keeps inline text out of nested child blocks (no duplication)', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    ordered = _.find data.blocks, (b) -> b.type == 'list' && b.ordered
    parentItem = ordered.items[1]
    eq parentItem.text, 'Second numbered item that contains a nested unordered list.'
    # The parent item text must not be repeated inside the nested list.
    nestedTexts = parentItem.blocks[0].items.map((i) -> i.text)
    ok parentItem.text not in nestedTexts

  test 'collects links with text and href in paragraphs and list items', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    paragraphWithLink = _.find data.blocks, (b) ->
      b.type == 'paragraph' && b.links.length > 0
    deepEq paragraphWithLink.links, [
      {text: 'installation guide & notes', href: 'https://example.com/docs?a=1&b=2'}
    ]

    ordered = _.find data.blocks, (b) -> b.type == 'list' && b.ordered
    nestedList = ordered.items[1].blocks[0]
    deepEq nestedList.items[0].links, [
      {text: 'a nested link', href: 'https://example.com/nested'}
    ]
    # The list-level links aggregate every link contained in the list.
    deepEq ordered.links, [
      {text: 'a nested link', href: 'https://example.com/nested'}
    ]

  test 'decodes html entities in text and href values', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    allText = JSON.stringify(data.blocks)
    ok allText.indexOf('&amp;') == -1, 'raw &amp; entities must be decoded'
    ok allText.indexOf('apples & oranges') >= 0
    ok allText.indexOf('Third numbered item — with a dash entity') >= 0
    ok allText.indexOf('a=1&b=2') >= 0

  test 'excludes navigation, scripts and footer content outside the article', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    allText = JSON.stringify(data.blocks)
    ok allText.indexOf('Archive') == -1, 'nav link text must not leak into blocks'
    ok allText.indexOf('tracker') == -1, 'script content must not leak into blocks'
    ok allText.indexOf('Footer junk') == -1, 'footer content must not leak into blocks'

  test 'emits blocks in original DOM order', ->
    data = extractor(fixtureHtml(), undefined, {blocks: true})
    types = data.blocks.map (b) ->
      if b.type == 'heading' then "heading#{b.level}" else b.type
    deepEq types, [
      'heading1', 'paragraph', 'heading2', 'paragraph', 'heading3',
      'paragraph', 'list', 'paragraph', 'list', 'heading2', 'paragraph',
      'code', 'paragraph', 'code', 'paragraph', 'heading2', 'paragraph'
    ]

  test 'lazy blocks match eager blocks regardless of access order', ->
    html = fixtureHtml()
    eager = extractor(html, undefined, {blocks: true})

    blocksFirst = extractor.lazy(html, undefined, {blocks: true})
    blocksFirstResult = blocksFirst.blocks()
    textAfterBlocks = blocksFirst.text()

    textFirst = extractor.lazy(html, undefined, {blocks: true})
    textFirstResult = textFirst.text()
    blocksAfterText = textFirst.blocks()

    deepEq blocksFirstResult, eager.blocks
    deepEq blocksAfterText, eager.blocks
    eq textAfterBlocks, eager.text
    eq textFirstResult, eager.text

  test 'repeated lazy access returns the cached blocks', ->
    lazy = extractor.lazy(fixtureHtml(), undefined, {blocks: true})
    first = lazy.blocks()
    second = lazy.blocks()
    ok first == second, 'the cached blocks array must be returned on repeat access'

  test 'honors the explicit language parameter', ->
    html = fixtureHtml()
    withLang = extractor(html, 'en', {blocks: true})
    autoDetect = extractor(html, undefined, {blocks: true})
    eq withLang.lang, 'en'
    deepEq withLang.blocks, autoDetect.blocks

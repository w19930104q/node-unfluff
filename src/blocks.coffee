# Structured content extraction for technical documents.
#
# This module walks the already-selected article root node (the same node the
# plain-text pipeline picks via extractor.calculateBestNode) in original DOM
# order and turns it into a list of typed blocks: headings, paragraphs,
# (possibly nested) lists and code blocks.
#
# Unlike the text formatter, this pipeline never removes nodes because they
# contain few stopwords, so short headings and code blocks survive. Text that
# appears inline is only collected once: when a node also contains block-level
# children, the inline portions are emitted as paragraphs and the children are
# emitted as their own blocks, never duplicated inside the parent block.
#
# Implementation note: cheerio 0.22 aborts a .each() iteration when the
# callback returns a boolean, and coffee-script-redux implicitly returns the
# last expression of every function, so all DOM walks here use index-based
# for-loops instead of .each().

HEADING_TAGS = ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']
LIST_TAGS = ['ul', 'ol']
# Elements whose contents are block-level rather than inline text. body and
# html are included because calculateBestNode can return either when the
# article markup lacks a dedicated container element.
CONTAINER_TAGS = ['body', 'html', 'div', 'section', 'article', 'header', 'footer', 'blockquote', 'td', 'th', 'tr', 'tbody', 'thead', 'table', 'figure', 'figcaption', 'main', 'aside', 'dl', 'dd', 'dt', 'address', 'details', 'fieldset']

module.exports = blocksExtractor = (doc, topNode) ->
  # Walk the root node itself (not just its contents): the selected article
  # root can be a paragraph, a list item or any other element type.
  rootBlock = walkNode(doc, topNode)
  if rootBlock?
    [].concat(rootBlock)
  else
    []

# Return a block object, an array of block objects, or null to skip the node.
walkNode = (doc, node) ->
  el = node[0]
  return null unless el
  nodeType = el.type
  tagName = el.name

  if nodeType == "text"
    text = normalizeInline(node.text())
    if text
      return paragraphBlock(text, [])
    return null

  if tagName in HEADING_TAGS
    inline = collectInline(doc, node)
    if inline.text
      return {
        type: 'heading'
        level: parseInt(tagName.charAt(1))
        text: inline.text
        links: inline.links
      }
    return null

  if tagName == 'pre' || tagName == 'code'
    return codeBlock(doc, node)

  if tagName in LIST_TAGS
    return listBlock(doc, node)

  if tagName == 'li'
    # A list item reached directly (list contents include the li children).
    return listItem(doc, node)

  if tagName == 'p'
    # A paragraph can end up wrapping block-level elements. In particular the
    # cleaner rewrites code-bearing divs into <p><pre>...</pre></p> or, when
    # the parser drops the redundant pre tag, <p><code>...</code></p>. A
    # <code> element only counts as its own code block when it is the whole
    # paragraph; inline <code> mixed with text stays part of the paragraph.
    blockDescendants = node.find(HEADING_TAGS.concat(LIST_TAGS, 'pre').join(', '))
    if blockDescendants.length > 0 || soleCodeChild(doc, node)
      return walkChildren(doc, node)
    inline = collectInline(doc, node)
    if inline.text
      return paragraphBlock(inline.text, inline.links)
    return null

  if tagName in CONTAINER_TAGS
    return walkChildren(doc, node)

  # Everything else (img, hr, br, span, inline elements at block level, ...)
  # contributes nothing as a standalone block.
  null

# Recurse over a container's children and flatten the resulting blocks.
walkChildren = (doc, node) ->
  blocks = []
  children = node.contents()
  for i in [0...children.length]
    block = walkNode(doc, children.eq(i))
    if block?
      blocks = blocks.concat(block)
  blocks

# True when the node's only element child is a <code> block (possibly wrapped
# in whitespace), i.e. the whole paragraph is code rather than prose with an
# inline code mention.
soleCodeChild = (doc, node) ->
  elementChildren = node.children('code, pre')
  if elementChildren.length != 1 || elementChildren[0].name != 'code'
    return false
  hasOtherText = false
  contents = node.contents()
  for i in [0...contents.length]
    child = contents.eq(i)
    if child[0].type == 'text' && /\S/.test(child.text())
      hasOtherText = true
  !hasOtherText

paragraphBlock = (text, links) ->
  {
    type: 'paragraph'
    text: text
    links: links
  }

# Build a code block. The raw text of <pre>/<code> nodes is kept verbatim,
# including newlines and indentation, since cheerio's text() does not collapse
# whitespace inside these elements.
codeBlock = (doc, node) ->
  text = node.text().replace(/\r\n?/g, "\n")
  return null unless /\S/.test(text)

  {
    type: 'code'
    text: text
    language: detectLanguage(doc, node)
  }

# Look for a language hint on the code element itself or any wrapping element.
# Common conventions:
#   <pre class="language-javascript">, <code class="lang-js">,
#   <pre><code class="hljs python">, <code data-language="ruby">
detectLanguage = (doc, node) ->
  candidates = node
  if node[0].name != 'pre'
    candidates = candidates.add(node.parents('pre').first())
  else
    codeChild = node.find('code').first()
    if codeChild.length > 0
      candidates = candidates.add(codeChild)

  language = null
  for i in [0...candidates.length]
    el = candidates.eq(i)
    dataLang = el.attr('data-language') || el.attr('data-lang')
    if !language && dataLang
      language = dataLang.trim()

    classNames = el.attr('class')
    if !language && classNames
      prefixMatch = classNames.match(/(?:language|lang|highlight)[-_]([A-Za-z0-9_+#.]+)/)
      hljsMatch = classNames.match(/hljs[ \t]+([A-Za-z0-9_+#.]+)/)
      match = prefixMatch || hljsMatch
      if match
        language = match[1]
  language

listBlock = (doc, node) ->
  items = []
  liNodes = node.children('li')
  for i in [0...liNodes.length]
    item = listItem(doc, liNodes.eq(i))
    if item?
      items.push(item)

  return null if items.length == 0

  block =
    type: 'list'
    ordered: node[0].name == 'ol'
    items: items
    links: collectListLinks(items)

  # Preserve an explicit starting number, e.g. <ol start="3">
  if block.ordered
    startAttr = node.attr('start')
    if startAttr?
      start = parseInt(startAttr, 10)
      block.start = start unless isNaN(start)
  block

# A list item holds its inline text (once) plus any nested blocks such as
# nested lists or code blocks.
listItem = (doc, node) ->
  blocks = []
  inlineParts = []
  links = []

  contents = node.contents()
  for i in [0...contents.length]
    child = contents.eq(i)
    el = child[0]
    if el
      if el.type == 'text'
        inlineParts.push(child.text())
      else if el.name == 'br'
        inlineParts.push(' ')
      else if el.name in LIST_TAGS
        nested = listBlock(doc, child)
        if nested?
          blocks.push(nested)
      else if el.name in HEADING_TAGS || el.name == 'pre' || el.name in CONTAINER_TAGS || el.name == 'p'
        nested = walkNode(doc, child)
        if nested?
          blocks = blocks.concat(nested)
      else
        # Inline element (a, strong, span, code used inline, ...): gather its
        # text and any links without recursing into block-level descendants.
        inline = collectInline(doc, child)
        if inline.text
          inlineParts.push(inline.text)
        links = links.concat(inline.links)

  text = normalizeInline(inlineParts.join(''))
  return null unless text || blocks.length > 0

  item = {text: text, links: links}
  if blocks.length > 0
    item.blocks = blocks
  item

collectListLinks = (items) ->
  links = []
  for item in items
    links = links.concat(item.links)
    if item.blocks
      for block in item.blocks
        if block.type == 'list'
          links = links.concat(collectListLinks(block.items))
  links

# Collect the inline text of a node along with its links. Block-level
# descendants (lists, headings, code blocks, ...) are skipped here because they
# get emitted as their own blocks, which guarantees inline text is never
# duplicated between a parent block and its child blocks.
collectInline = (doc, node) ->
  parts = []
  links = []

  # When the node passed in is itself an anchor (the common case from list
  # items which classify <a> as inline), collect its own link directly. The
  # anchor's text is captured in full here, so its descendants are not walked.
  root = node[0]
  if root && root.name == 'a'
    anchorText = normalizeInline(node.text())
    href = node.attr('href')
    if anchorText
      parts.push(node.text())
      if href
        links.push({text: anchorText, href: href})
  else
    walk = (current) ->
      contents = current.contents()
      for i in [0...contents.length]
        el = contents.eq(i)
        raw = el[0]
        if raw
          if raw.type == 'text'
            parts.push(el.text())
          else if raw.name == 'br'
            parts.push(' ')
          else if isBlockLevel(raw.name)
            # Skip: handled as a separate block by the outer walker.
            skip = true
          else if raw.name == 'a'
            text = normalizeInline(el.text())
            href = el.attr('href')
            if text
              parts.push(el.text())
              if href
                links.push({text: text, href: href})
          else
            walk(el)

    walk(node)
  {text: normalizeInline(parts.join('')), links: links}

isBlockLevel = (name) ->
  # Note: <code> is deliberately excluded here. A <code> element only becomes
  # a standalone code block via the explicit pre/code branches in walkNode
  # (including sole-code paragraphs). Inline <code> mixed into prose or list
  # items must keep contributing its text like any other inline element.
  name in HEADING_TAGS || name in LIST_TAGS || name == 'pre' || name in CONTAINER_TAGS || name == 'p'

# Collapse runs of whitespace (including newlines) into single spaces, the way
# inline text would render in a browser, and trim the ends.
normalizeInline = (text) ->
  text.replace(/\s+/g, ' ').trim()

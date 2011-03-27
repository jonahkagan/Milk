# Milk is a simple, fast way to get more Mustache into your CoffeeScript and
# Javascript.
#
# Plenty of good resources for Mustache can be found
# [here](mustache.github.com), so little will be said about the templating
# language itself here.
#
# Template rendering is broken into a couple of distinct phases: deconstructing
# a parse tree, and generating the final result.

#### Parsing

# In the simplest case, we'll simply need a template string to parse.  If we've
# parsed this template before, the cache will let us bail early.  We do need to
# remember to take the tag delimiters into account, however -- different parse
# trees can exist for the same raw template!

# Mustache templates are reasonably simple -- plain text templates are
# sprinkled with "tags", which are (by default) a pair of curly braces
# surrounding some bit of content.

TemplateCache = {}

Parse = (template, delimiters = ['{{','}}'], section = null) ->
  cache = (TemplateCache[delimiters.join(' ')] ||= {})
  return cache[template] if template of cache

  buffer = []

  # We're going to take the easy route this time, and just match away large
  # parts of the template with a regular expression.  This isn't likely the
  # fastest approach, but it is fairly simple.
  # Since the tag delimiters may change over time, we'll need to be able to
  # rebuild the regex when they change.
  [tagOpen, tagClose] = delimiters
  BuildRegex = ->
    return ///
      ([\s\S]*?)                # Capture the pre-tag content
      ([#{' '}\t]*)             # Capture the pre-tag whitespace
      (?: #{tagOpen} \s*        # Match the opening tag
      (?:
        (!)                  \s* ([\s\S]+?)       | # Comments
        (=)                  \s* ([\s\S]+?) \s* = | # Set Delimiters
        ({)                  \s* (\w[\S]*?) \s* } | # Triple Mustaches
        ([^0-9a-zA-Z._!={]?) \s* ([\w.][\S]*?)      # Everything else
      )
      \s* #{tagClose} )         # Match the closing tag
    ///gm

  tagPattern = BuildRegex()
  tagPattern.lastIndex = pos = (section || { start: 0 }).start

  # In case we run into problems, we need to be able to provide good diagnostic
  # messages for the user.  We'll build a message with the line number, the
  # template line in question, and the approximate position of the error within
  # that line.
  parseError = (pos, message) ->
    (endOfLine = /$/gm).lastIndex = pos
    endOfLine.exec(template)

    parsedLines = template.substr(0, pos).split('\n')
    lineNo      = parsedLines.length
    lastLine    = parsedLines[lineNo - 1]
    tagStart    = contentEnd + whitespace.length
    lastTag     = template.substr(tagStart + 1, pos - tagStart - 1)

    indent   = new Array(lastLine.length - lastTag.length + 1).join(' ')
    carets   = new Array(lastTag.length + 1).join('^')
    lastLine = lastLine + template.substr(pos, endOfLine.lastIndex - pos)

    error = new Error()
    error[key] = e[key] for key of e =
      message: "#{message}\n\nLine #{lineNo}:\n#{lastLine}\n#{indent}#{carets}"
      error: message, line: lineNo, char: indent.length, tag: lastTag
    return error

  # As we start matching things, we'll pull out the relevant captures, indices,
  # and deterimine whether the tag is standalone.
  while match = tagPattern.exec(template)
    [content, whitespace] = match[1..2]
    type = match[3] || match[5] || match[7] || match[9]
    tag  = match[4] || match[6] || match[8] || match[10]

    contentEnd = (pos + content.length) - 1
    pos        = tagPattern.lastIndex

    isStandalone = (contentEnd == -1 or template.charAt(contentEnd) == '\n') &&
                   template.charAt(pos) in [ undefined, '', '\r', '\n' ]

    # Append the static content to the buffer.
    buffer.push content

    # If we're dealing with a standalone non-interpolation tag, we should skip
    # over the newline immediately following the tag.  If we're not, we need
    # give back the whitespace we've been holding hostage.
    if isStandalone and type not in ['', '&', '{']
      pos += 1 if template.charAt(pos) == '\r'
      pos += 1 if template.charAt(pos) == '\n'
    else if whitespace
      buffer.push(whitespace)
      contentEnd += whitespace.length
      whitespace = ''

    # Next, we'll handle the tag itself:
    switch type

      # Comment tags should simply be ignored.
      when '!' then break

      # Interpolation tags only require the tag name.
      when '', '&', '{' then buffer.push [ type, tag ]

      # Partial will require the tag name and any leading whitespace, which
      # will be used to indent the partial.
      when '>' then buffer.push [ type, tag, whitespace ]

      # Sections and Inverted Sections make a recursive call to `Parse`,
      # starting immediately after the tag.  This call will continue to walk
      # through the template until it reaches an End Section tag, when it will
      # return the subtemplate it's parsed (and cached!) and the index after
      # the End Section tag.  We'll save the tag name, current delimiters, and
      # the subtemplate string.  We also pass an error through to the `Parse`
      # call -- sort of a "tell the wife and kids I love 'em" moment, really.
      # (It's just more convenient to build the error here since we already
      # have all the context we need.)
      when '#', '^'
        sectionInfo =
          name: tag, start: pos
          error: parseError(tagPattern.lastIndex, "Unclosed section '#{tag}'!")
        [tmpl, pos] = Parse(template, [tagOpen, tagClose], sectionInfo)
        buffer.push [ type, tag, [[tagOpen, tagClose], tmpl] ]

      when '/'
        unless section?
          error = "End Section tag '#{tag}' found, but not in section!"
        else
          if tag != (name = section.name)
            error = "End Section tag closes '#{tag}'; expected '#{name}'!"
        throw parseError(tagPattern.lastIndex, error) if error

        template = template[section.start..contentEnd]
        TemplateCache[delimiters.join(' ')][template] = buffer
        return [template, pos]

      # The Set Delimiters tag doesn't actually generate output, but instead
      # changes the tagPattern that the parser uses.  All delimiters need to be
      # regex escaped for safety.
      when '='
        delims = tag.split(/\s+/)

        unless delims.length == 2
          error = "Set Delimiters tags should have two and only two values!"
        throw parseError(tagPattern.lastIndex, error) if error

        [tagOpen, tagClose] = for delim in delims
          delim.replace(/[-[\]{}()*+?.,\\^$|#]/g, "\\$&")
        tagPattern = BuildRegex()

      else
        throw parseError(tagPattern.lastIndex, "Unknown tag type -- #{type}")

    # And finally, we'll advance the tagPattern's lastIndex (so that it resumes
    # parsing where we intend it to), and loop.
    tagPattern.lastIndex = if pos? then pos else template.length

  # We've finished parsing tags out of this template, so if we've still got a
  # `section`, someone left a section tag open.
  throw section.error if section?

  # Since we may have a little extra content after the last tag, we'll append
  # it to the buffer, cache it, and return the buffer!
  buffer.push(template[pos..])
  return TemplateCache[delimiters.join(' ')][template] = buffer

#### Generating

# Once we have a parse tree, transforming it back into a full template should
# be fairly straightforward.  We start by building a context stack, which data
# will be looked up from.
Generate = (buffer, data, partials, context = [], Escape) ->
  context.push data

  Build = (tmpl, data, delims) ->
    Generate(Parse("#{tmpl}", delims), data, partials, [context...], Escape)

  parts = for part in buffer
    switch typeof part

      # Strings in the buffer can be used literally.
      when 'string' then part

      # Parsed tags (which will be Arrays in the given buffer) will need to be
      # evaluated against the context stack.
      else
        [type, name, data] = part
        value = Find(name, context) unless type is '>'

        switch type

          # Partials will be looked up by name (in this case, from the given
          # hash) and built.  (Parsing the partial here means that we don't
          # have to worry about recursive partials.)  If the partial tag was
          # standalone and indented, the resulting content should be similarly
          # indented.
          when '>'
            partial = partials(name).toString()
            partial = partial.replace(/^(?=.)/gm, data) if data
            Build(partial)

          # Sections will render when the name specified retreives a truthy
          # value from the context stack, and should be repeated for each
          # element if the value is an array.  If the value is a function, it
          # should be called with the raw section template, and the return
          # value should be built.
          when '#'
            [delims, tmpl] = data
            switch (value ||= []).constructor
              when Array
                (Build(tmpl, v, delims) for v in value).join('')
              when Function
                Build(value(tmpl), null, delims)
              else
                Build(tmpl, value, delims)

          # Inverted Sections render under almost opposite conditions: their
          # contents will only be rendered whene the retrieved value is falsey,
          # or is an empty array.
          when '^'
            [delims, tmpl] = data
            empty = (value ||= []) instanceof Array and value.length is 0
            if empty then Build(tmpl, null, delims) else ''

          # Unescaped interpolations should be returned directly; Escaped
          # interpolations will need to be HTML escaped for safety.
          # For lambdas that we receive, we'll simply call them and compile
          # whatever they return.
          when '&', '{' 
            value = Build("#{value()}") if value instanceof Function
            "#{value}"
          when ''
            value = Build("#{value()}") if value instanceof Function
            Escape("#{value}")

          else
            throw "Unknown tag type -- #{type}"

  # The generated result is the concatenation of all these parts.
  return parts.join('')

#### Helpers

# `Find` will walk the context stack from top to bottom, looking for an element
# with the given name.  '.' is a special name, representing the element on the
# top of the stack, and dotted names perform chained resolutions.
Find = (name, stack) ->
  return stack[stack.length - 1] if name == '.'
  [name, parts...] = name.split(/\./)
  value = ''
  for i in [stack.length - 1...-1]
    continue unless stack[i]?
    continue unless typeof stack[i] == 'object' and name of (ctx = stack[i])
    value = ctx[name]
    break

  value = Find(part, [value]) for part in parts

  # If the value is a function, it will be treated like an object method;
  # we'll call it, and use its return value as the new value.  Object methods
  # being used for sections receive the raw section content, and automatically
  # render the returned values against the current context.
  # If the result is also a function, we'll treat that as an unbound lambda.
  # Lambdas are treated as object methods, except that `this` is not bound.
  if value instanceof Function
    value = do (value) ->
      (tmpl) ->
        val = value.apply(ctx, [tmpl])
        return (val instanceof Function) and val(tmpl) or val

  # Null values will be coerced to the empty string.
  return value ? ''

#### Exports

# In CommonJS-based environments, Milk will export both a `render` function
# and a function `escape` for doing basic HTML escaping.
# In browsers, and other non-CommonJS environments, the object `Milk` will be
# exported to the global namespace, containing the same methods.
#
# The `Milk` export also contains a special key, `Milk.helpers`.  Any object
# (or every object of an array) assigned to this key will be accessible on the
# bottom of the context stack, allowing for common behavior (e.g. markup,
# highlighting, or internationalization) to be made "globally" available to
# the rendering engine.
#
# All environments presently support only synchronous rendering of in-memory
# templates, partials, and data.
#
# Happy hacking!
Render = (template, data, partials = null) ->
  helpers = if @helpers instanceof Array then [@helpers...] else [@helpers]

  partials ||= @partials || {}
  unless partials instanceof Function
    partials = do (partials) -> (name) ->
      throw "Unknown partial '#{name}'!" unless name of partials
      Find(name, [partials])

  return Generate(Parse(template), data, partials, helpers, @escape)

Milk =
  VERSION: '1.1.0'
  render: -> Render.apply(exports ? Milk, arguments)
  helpers: []
  escape: (value) ->
    entities = { '&': 'amp', '"': 'quot', '<': 'lt', '>': 'gt' }
    return value.replace(/[&"<>]/g, (char) -> "&#{ entities[char] };")

if exports?
  exports[key] = Milk[key] for key of Milk
else
  this.Milk = Milk

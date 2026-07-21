#!/usr/bin/env ruby

require 'json'

text = $stdin.read.to_s
abort "No text provided" if text.strip.empty?

timestamp = ENV['CHESTNUT_TIMESTAMP'] || Time.now.iso8601
source_app = ENV['CHESTNUT_SOURCE_APP'] || ''

LANG_PATTERNS = {
  'python'     => [/^\s*(import |from .+ import |def |class |if __name__)/, /\.py\b/],
  'ruby'       => [/^\s*(require |def |end$|class |module |puts )/, /\.rb\b/],
  'javascript' => [/^\s*(const |let |var |function |=>|import .+ from)/, /\.(js|mjs)\b/],
  'typescript' => [/^\s*(const |let |interface |type |export |import .+ from).*[:<]/, /\.tsx?\b/],
  'swift'      => [/^\s*(func |let |var |import |struct |class |enum |guard |@)/, /\.swift\b/],
  'rust'       => [/^\s*(fn |let |use |mod |pub |impl |struct |enum |match )/, /\.rs\b/],
  'go'         => [/^\s*(func |package |import |type .+ struct|:=)/, /\.go\b/],
  'bash'       => [/^\s*(#!.*(?:ba)?sh|if \[|fi$|esac$|done$|echo )/, /\.sh\b/],
  'sql'        => [/^\s*(SELECT |INSERT |UPDATE |DELETE |CREATE |ALTER |DROP )/i],
  'html'       => [/^\s*<(!DOCTYPE|html|head|body|div|span|p |a )/i],
  'css'        => [/^\s*[.#@]?[\w-]+\s*\{/, /^\s*(margin|padding|display|color)\s*:/],
  'json'       => [/\A\s*[\[{]/],
  'yaml'       => [/\A---\s*$/, /^\w[\w-]*:\s/],
}

def detect_language(text)
  scores = Hash.new(0)
  lines = text.lines.first(30)

  LANG_PATTERNS.each do |lang, patterns|
    patterns.each do |pat|
      lines.each { |line| scores[lang] += 1 if line.match?(pat) }
    end
  end

  best = scores.max_by { |_, v| v }
  best && best[1] >= 2 ? best[0] : nil
end

lang = detect_language(text)
fence = lang ? "```#{lang}" : "```"

parts = []
parts << "---"
parts << "type: snippet"
parts << "language: #{lang}" if lang
parts << "source_app: \"#{source_app}\"" unless source_app.empty?
parts << "date: #{timestamp}"
parts << "tags: [snippet#{lang ? ", #{lang}" : ''}]"
parts << "---"
parts << ""
parts << "# #{lang ? lang.capitalize + ' snippet' : 'Code snippet'}"
parts << ""
parts << fence
parts << text.chomp
parts << "```"
parts << ""

content = parts.join("\n")
date_prefix = timestamp[0, 10]
safe_lang = lang || 'code'
filename = "#{date_prefix}-#{safe_lang}-snippet.md"

envelope = {
  action: 'save',
  content: content,
  filename: filename,
  vault: 'ask',
  notify: lang ? "#{lang.capitalize} snippet saved" : 'Snippet saved',
}

puts JSON.generate(envelope)

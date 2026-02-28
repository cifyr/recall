#!/usr/bin/env ruby

require 'json'
require 'set'
require 'pathname'

if ARGV.empty?
  warn 'usage: build_edge_function_payload.rb FUNCTION_NAME [verify_jwt]'
  exit 1
end

function_name = ARGV.fetch(0)
verify_jwt = ARGV.fetch(1, 'false') == 'true'
root = Pathname('/Users/caden/Desktop/watch/supabase/functions')
entrypoint = root.join(function_name, 'index.ts')
import_map = root.join('deno.json')

unless entrypoint.file?
  warn "missing entrypoint: #{entrypoint}"
  exit 1
end

visited = Set.new
ordered_files = []

walk = lambda do |path|
  relative = path.relative_path_from(root).to_s
  return if visited.include?(relative)

  visited << relative
  source = path.read

  source.scan(/from ['"](\.\.?\/[^'"]+)['"]/).flatten.each do |import_path|
    dependency = path.dirname.join(import_path).cleanpath
    dependency = Pathname("#{dependency}.ts") unless dependency.extname == '.ts'
    walk.call(dependency)
  end

  ordered_files << {
    name: relative,
    content: source,
  }
end

walk.call(entrypoint)

payload = {
  name: function_name,
  entrypoint_path: entrypoint.relative_path_from(root).to_s,
  import_map_path: import_map.relative_path_from(root).to_s,
  verify_jwt: verify_jwt,
  files: ordered_files + [{
    name: import_map.relative_path_from(root).to_s,
    content: import_map.read,
  }],
}

puts JSON.generate(payload)

# Used twice: on the first-run screen without indent, and inside
# Settings with one. Queues are NOT expanded here — only one region can
# be chosen, and twenty-six expanded lists came to 364 menu lines,
# more than everything else put together.
def region_picker(indent)
  REGIONS.each_key do |id|
    here = CONFIGURED && id == REGION
    puts "#{indent}#{here ? '✓ ' : ''}#{REGIONS.dig(id, 0)} | size=11 " \
         "bash=\"#{SELF}\" terminal=false refresh=true " \
         "param1=--set param2=#{id} param3=#{QUEUE}"
  end
end

# Queues of the chosen region only, from real data when there is any
def queue_picker(indent, known_groups)
  groups = known_groups && !known_groups.empty? ? known_groups : DEFAULT_GROUPS
  # Even Kyiv has fewer than a hundred queues; this caps bloated data
  groups.select { |g| g.match?(/\AGPV\d{1,3}\.\d{1,2}\z/) }
        .sort_by { |g| g[3..].split('.').map(&:to_i) }.first(100).each do |k|
    puts "#{indent}#{k == QUEUE ? '✓ ' : ''}черга #{k.sub('GPV', '')} | " \
         "size=11 bash=\"#{SELF}\" terminal=false refresh=true " \
         "param1=--set param2=#{REGION} param3=#{k}"
  end
end

def notify(title, message)
  # Escape backslashes and quotes, drop newlines: otherwise the text
  # could break out of the AppleScript literal
  esc = lambda do |str|
    str.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\\\"').delete("\n\r")
  end
  system('osascript', '-e',
         %(display notification "#{esc.call(message)}" with title "#{esc.call(title)}" sound name "Submarine"))
end

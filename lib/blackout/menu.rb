# frozen_string_literal: true

# Used twice: on the first-run screen without indent, and inside
# Settings with one. Queues are NOT expanded here — only one region can
# be chosen, and twenty-six expanded lists came to 364 menu lines,
# more than everything else put together.
def region_picker(indent)
  REGIONS.each_key do |id|
    here = CONFIGURED && id == REGION
    puts "#{indent}#{'✓ ' if here}#{REGIONS.dig(id, 0)} | size=11 " \
         "bash=\"#{SELF}\" terminal=false refresh=true " \
         "param1=--set param2=#{id} param3=#{QUEUE}"
  end
end

# Queues of the chosen region only, from real data when there is any
def queue_picker(indent, known_groups)
  groups = known_groups && !known_groups.empty? ? known_groups : DEFAULT_GROUPS
  # Even Kyiv has fewer than a hundred queues; this caps bloated data
  groups.grep(/\AGPV\d{1,3}\.\d{1,2}\z/)
        .sort_by { |g| g[3..].split('.').map(&:to_i) }.first(100).each do |k|
    puts "#{indent}#{'✓ ' if k == QUEUE}черга #{k.sub('GPV', '')} | " \
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
         %(display notification "#{esc.call(message)}" ) +
         %(with title "#{esc.call(title)}" sound name "Submarine"))
end

# The settings menu. Printed on EVERY screen, including the ones that
# have no schedule to show: without it a region whose source is silent
# became a dead end — no way to switch region or queue from the menu.
def settings_menu(known_groups = nil)
  puts 'Налаштування | size=11 color=gray'

  puts "--Область: #{REGIONS.dig(REGION, 0) || REGION} | size=11"
  region_picker('----')

  puts "--Черга: #{QUEUE.sub('GPV', '')} | size=11"
  queue_picker('----', known_groups)
  site = REGIONS.dig(REGION, 3)
  puts "--Не знаю свою чергу | size=11#{" href=#{site}" if site}"

  puts "--#{'✓ ' if ALERTS_ON}Показувати повітряну тривогу | size=11 bash=\"#{SELF}\" " \
       "terminal=false refresh=true param1=--alerts param2=#{ALERTS_ON ? 'off' : 'on'}"

  if ALERTS_ON && (districts = alert_districts(REGIONS.dig(REGION, 2)))
    puts '--Район для тривог | size=11'
    puts "----#{'✓ ' unless DISTRICT}Уся область | size=11 bash=\"#{SELF}\" " \
         'terminal=false refresh=true param1=--district param2=""'
    districts.first(40).each do |d|
      next unless d.match?(/\A[\p{L}\p{Zs}'’-]{3,60}\z/)

      puts "----#{'✓ ' if d == DISTRICT}#{d} | size=11 bash=\"#{SELF}\" " \
           "terminal=false refresh=true param1=--district param2=\"#{d}\""
    end
  end
  puts '--Сповіщення | size=11'
  puts "----#{'✓ ' if NOTIFY}Увімкнені | size=11 bash=\"#{SELF}\" terminal=false " \
       "refresh=true param1=--notify param2=#{NOTIFY ? 'off' : 'on'}"
  puts '----Попереджати за | size=11'
  [5, 10, 15, 30, 60].each do |m|
    puts "------#{'✓ ' if m == WARN}#{m} хв | size=11 bash=\"#{SELF}\" " \
         "terminal=false refresh=true param1=--warn param2=#{m}"
  end

  puts 'Оновити зараз | refresh=true size=11'
  puts '---'
  puts 'Дані з відкритих джерел, можливі неточності | size=10 color=gray'
  puts 'Джерела даних | size=10 color=gray href=https://alerts.energy/'
end

# Two screens say "no schedule" in the same shape: no data at all, and a
# document with no days in it. The restriction level from the grid, when
# there is one, explains the reason better than we could.
def no_schedule(alert, emergency, area, blind, headline, hint, updated = nil)
  label = area && safe(area['label'])
  # The grid tells "no outages" and "we do not know" apart, and so should
  # we: dataState 'available' at a low level is good news, not a gap. It
  # says "no planned outages in the available schedules"; the other 17
  # regions say "no confirmed current data", which is a different thing.
  settled = area && area['dataState'] == 'available' && area['level'].to_i < 2
  icon = if emergency
           '🚨'
         elsif settled
           '💡'
         else
           '❔'
         end
  colour = if emergency
             'red'
           elsif settled
             'green'
           else
             'orange'
           end

  puts "#{siren_prefix(alert)}#{icon}"
  puts '---'
  puts "#{REGIONS.dig(REGION, 0) || REGION} | size=12 color=gray"
  puts "#{label || headline} | color=#{colour} size=14"
  puts "#{hint} | size=11 color=gray" unless emergency || settled
  puts 'Статус аварійних не перевіряється — джерело закрило доступ | size=11 color=orange' if blind
  puts "Оновлено: #{fmt_updated(updated)} | size=11 color=gray" if updated
  render_alert(alert)
  settings_menu
end

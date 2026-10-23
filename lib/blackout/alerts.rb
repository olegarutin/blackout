def fetch_alerts
  ensure_dir(CACHE)
  path = File.join(CACHE, 'alerts.json')

  if File.exist?(path) && (Time.now - File.mtime(path)) < TTL_ALERT
    cached = read_cache(path)
    return cached if cached
  end

  body, etag = http_get(ALERTS, read_etag(path))

  if body.nil?
    touch_cache(path)
    return read_cache(path)
  end

  parsed = JSON.parse(body)
  raise 'unexpected schema' unless parsed.is_a?(Hash) && parsed['states'].is_a?(Hash)

  atomic_write(path, body)
  write_etag(path, etag)
  parsed
rescue StandardError
  File.exist?(path) ? read_cache(path) : nil
end

# Menu-bar prefix: red for missiles, yellow for drones, nothing if quiet
def siren_prefix(alert)
  return '' unless alert

  # The level can be missing; the published semantics say to treat such
  # an alert as red rather than hide it
  alert[:level] == 'yellow' ? '🟡 ' : '🔴 '
end

# Districts of an oblast, for the picker
def alert_districts(oblast)
  return nil unless oblast

  st = (fetch_alerts || {}).dig('states', oblast)
  names = ((st && st['districts']) || {}).keys
  names.empty? ? nil : names.sort
end

def render_alert(alert)
  unless alert
    if ALERTS_ON && REGIONS.dig(REGION, 2)
      puts '---'
      puts '🟢 Тривоги немає | color=green size=12'
    end
    return
  end

  puts '---'
  label, colour = case alert[:level]
                  when 'yellow' then ['🟡 Тривога — дрони', 'orange']
                  when 'red'    then ['🔴 Тривога — ракетна загроза', 'red']
                  else               ['🔴 Повітряна тривога (рівень не вказано)', 'red']
                  end
  puts "#{label} | color=#{colour} size=14"

  # With a district chosen, naming the whole oblast would be imprecise
  where = DISTRICT && !alert[:whole] ? safe(DISTRICT) : REGIONS.dig(REGION, 2)
  if alert[:since]
    mins = ((Time.now - alert[:since]) / 60).to_i
    puts "#{where} · триває #{mins / 60} год #{mins % 60} хв | size=12 color=gray"
  else
    puts "#{where} | size=12 color=gray"
  end

  if alert[:whole]
    puts 'Уся область | size=11 color=gray'
  elsif alert[:districts].any? && !DISTRICT
    shown = alert[:districts].first(8)
    tail = alert[:districts].size > 8 ? " та ще #{alert[:districts].size - 8}" : ''
    puts "Райони: #{safe(shown.join(', '))}#{tail} | size=11 color=gray"
  end
  puts 'Жовтий — дрони · червоний — ракети | size=11 color=gray'
end

# frozen_string_literal: true

# Everything the menu prints, from the first-run picker to the schedule
# and the settings. Called once per run by the plugin entry point.
def render
  # First run: guess nothing, ask
  unless CONFIGURED
    puts '🔌'
    puts '---'
    puts 'Регіон не вибрано | size=13'
    puts 'Обери свою область — чергу вкажеш далі | size=11 color=gray'
    puts '---'
    region_picker('')
    puts '---'
    puts 'Після вибору області чергу обереш у Налаштуваннях | size=10 color=gray'
    exit
  end

  alert = nil
  if ALERTS_ON && (oblast = REGIONS.dig(REGION, 2)) && (al = fetch_alerts)
    st = al.dig('states', oblast)
    if st
      # An alert can cover a whole oblast or only some districts; in
      # the second case the oblast flag stays false
      hot = (st['districts'] || {}).select { |_, v| v['enabled'] }
      # With a district chosen, an alert in the next one is not ours.
      # An oblast-wide announcement still counts either way.
      hot = hot.select { |name, _| name == DISTRICT } if DISTRICT && !st['enabled']
      if st['enabled'] || hot.any?
        levels = ([st['alert_level']] + hot.values.map { |v| v['alert_level'] }).compact
        # red outranks yellow; a missing level defaults to red
        level = levels.include?('red') ? 'red' : levels.first
        starts = ([st['enabled_at']] + hot.values.map { |v| v['enabled_at'] }).compact
        # The date comes from the network: a broken one must not crash us
        since = begin
          starts.min ? Time.parse(starts.min) : nil
        rescue ArgumentError, TypeError
          nil
        end
        alert = { since: since, level: level, districts: hot.keys,
                  whole: st['enabled'] }
      end
    end
  end

  # The oblast's restriction level: needed both for emergencies and to
  # explain a missing schedule. nil means we could not reach the source
  # at all, which is not the same as "no restrictions" — see blind?.
  # The transmission operator names the oblasts it has just lost power
  # in. That is not the same as the aggregator's restriction level, and
  # it is not a per-queue state — but it comes from the operator itself
  # and it answers the question the level used to: is my oblast having
  # an ordinary scheduled day, or something worse.
  grid = fetch_grid
  # The channel is reachable only now and then from some networks, so a
  # post can sit in the cache for a long time. Past half a day it is
  # history, not a warning about this morning.
  fresh_post = grid && grid['at'] &&
               (Time.now - Time.parse(grid['at'])) < (12 * 3600)
  hit = fresh_post &&
        oblasts_named(grid['text'], [REGIONS.dig(REGION, 2)].compact).any?

  levels = fetch_energy
  area = (levels || []).find { |a| a['name'] == REGIONS.dig(REGION, 2) }
  emergency = area && area['level'].to_i >= 3 ? safe(area['label']) : nil
  blind = levels.nil?

  data, status = fetch_data(REGION)

  if data.nil?
    no_schedule(alert, emergency, area, blind,
                'Графіка немає',
                'Оператор не публікує графіків для цієї області', hit: hit)
    exit
  end

  raw_days = data.dig('fact', 'data')
  # With no outages the source sometimes sends an array, not an object
  raw_days = nil unless raw_days.is_a?(Hash)
  day_keys = (raw_days&.keys || []).sort_by(&:to_i)

  # The document is there but holds no days. This used to render as a
  # green bulb — "power on" — which was the same lie as the timezone
  # one: a region with zero data and a cheerful light. No schedule is ❔.
  if day_keys.empty?
    no_schedule(alert, emergency, area, blind,
                'Актуального графіка немає',
                'Джерело віддало порожній графік — відключення можливі',
                data['lastUpdated'], hit: hit)
    exit
  end

  # Look for the day whose date is today first: fact.today lags around
  # midnight, and without this we would show yesterday's schedule while
  # today's already sits in the file.
  declared = data.dig('fact', 'today')&.to_s
  actual = day_keys.find { |k| Time.at(k.to_i).to_date == Date.today }
  today_key = actual || (day_keys.include?(declared) ? declared : day_keys.last)
  tomorrow_key = day_keys[day_keys.index(today_key) + 1]

  day_date = Time.at(today_key.to_i).to_date
  age = (Date.today - day_date).to_i
  stale = age != 0
  # No data for today, but the gap is small: not published yet, called
  # off, or the source already serves tomorrow. More than two days out
  # and the source is simply dead.
  unknown = stale && age <= 2

  today    = hours_for(data, QUEUE, today_key)
  tomorrow = tomorrow_key ? hours_for(data, QUEUE, tomorrow_key) : nil

  # During an emergency a queue often has no schedule at all; saying
  # "queue missing" would send the reader looking for a fault
  if today.nil? && emergency
    puts "#{siren_prefix(alert)}🚨"
    puts '---'
    puts "#{REGIONS.dig(REGION, 0) || REGION} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    puts "#{emergency} | color=red size=14"
    puts 'Графіка на цю чергу немає — відключають поза ним | size=11 color=gray'
    render_alert(alert)
    settings_menu((raw_days&.dig(today_key) || {}).keys)
    exit
  end

  unless today
    puts '❌ немає черги'
    puts '---'
    puts "Черга #{QUEUE.sub('GPV', '')} відсутня в даних цього регіону | color=red"
    puts "Доступні: #{safe((raw_days&.dig(today_key) || {}).keys.map do |k|
      k.sub('GPV', '')
    end.join(', '))} | size=11 color=gray"
    puts 'Обери свою нижче, у Налаштуваннях | size=11 color=gray'
    render_alert(alert)
    settings_menu((raw_days&.dig(today_key) || {}).keys)
    exit
  end

  now  = Time.now
  on   = today[now.hour]
  left = minutes_until_change(today, tomorrow, now)

  # ── Change detection and warnings ───────────────────────────────────

  state = load_state
  key = "#{REGION}/#{QUEUE}/#{today_key}"
  digest = Digest::SHA256.hexdigest(today.map { |b| b ? '1' : '0' }.join)

  if NOTIFY && !stale
    # 1. Today's schedule was rewritten
    if state['key'] == key && state['digest'] && state['digest'] != digest
      changed = segments(today).reject { |_, _, lit| lit }
                               .map { |f, t, _| format('%02d–%02d', f, t) }.join(', ')
      notify('Графік змінився', "Черга #{QUEUE.sub('GPV', '')} · без світла: #{changed}")
    end

    # 2. Emergency outages started or ended
    if state['emergency'] != emergency.to_s
      notify('Аварійні відключення', 'Графік не діє — відключають поза ним') if emergency
      if state['emergency'].to_s != '' && !emergency
        notify('Повернулись до графіка',
               'Аварійні відключення скасовано')
      end
      state['emergency'] = emergency.to_s
    end

    # 3. A change is coming up
    if left && left <= WARN
      slot = "#{key}/#{on ? 'off' : 'on'}/#{(now.to_i + (left * 60)) / 3600}"
      if state['warned'] != slot
        if on
          notify('Скоро вимкнуть', "Через #{left} хв. Черга #{QUEUE.sub('GPV', '')}")
        else
          notify('Скоро увімкнуть', "Через #{left} хв. Черга #{QUEUE.sub('GPV', '')}")
        end
        state['warned'] = slot
      end
    end
  end

  state['key'] = key
  state['digest'] = digest
  save_state(state)

  # ── Menu bar ────────────────────────────────────────────────────────

  region_name = REGIONS.dig(REGION, 0) || REGION

  if unknown
    puts '❔'
    puts '---'
    puts "#{region_name} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    puts 'Графіка на сьогодні немає | color=orange size=14'
    if age.negative?
      puts "Джерело віддає дані на #{day_date.strftime('%d.%m')} | size=12 color=gray"
    else
      puts "Останній відомий — за #{day_date.strftime('%d.%m')} | size=12 color=gray"
      puts 'Або ще не опублікували, або відключення скасували | size=11 color=gray'
    end
  elsif stale
    puts "📅 #{day_date.strftime('%d.%m')}"
    puts '---'
    puts "#{region_name} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    # Saying the source is broken was a guess, and usually the wrong
    # one: these regions mostly have no outages at all, so there is
    # nothing newer to publish. State what is known — the last schedule
    # and its date — and leave the cause alone.
    puts 'Свіжого графіка немає | color=orange size=14'
    puts "Останній — за #{day_date.strftime('%d.%m.%Y')}, #{age} дн. тому | color=orange size=12"
    puts 'Відтоді оператор нічого не публікував. Розклад нижче — той старий. | size=11 color=gray'
  else
    # During an emergency the schedule does not apply, so a countdown
    # based on it would be dishonest
    icon = if emergency
             '🚨'
           else
             (on ? '💡' : '🕯️')
           end
    urgent = left && left <= WARN ? ' ⏳' : ''
    siren = siren_prefix(alert)
    puts(if emergency then "#{siren}🚨"
         elsif left then "#{siren}#{icon} #{fmt(left)}#{urgent}"
         else "#{siren}#{icon}"
         end)
    puts '---'
    puts "#{region_name} · черга #{QUEUE.sub('GPV', '')} | size=12 color=gray"
    if emergency
      puts "#{emergency} | color=red size=14"
      puts 'Графік не діє — відключають поза ним | size=12 color=gray'
      puts "За графіком зараз #{on ? 'мало бути світло' : 'і так відключення'} | size=11 color=gray"
    elsif on
      puts(if left then "Світло є · вимкнуть через #{fmt(left)} | color=green size=14"
           elsif today.all? then 'Світло є · відключень сьогодні немає | color=green size=14'
           else 'Світло є · більше відключень сьогодні не буде | color=green size=14'
           end)
    else
      puts(if left then "Світла немає · увімкнуть через #{fmt(left)} | color=red size=14"
           else 'Світла немає | color=red size=14'
           end)
    end
  end

  # Without the restriction level we cannot tell an ordinary schedule day
  # from an emergency, when the schedule stops applying altogether. The
  # countdown above is only as good as that assumption, and saying so is
  # the whole difference between a guess and a lie.
  # The mirror lands about twice a day. When the operator has already
  # published a newer revision, saying so beats showing a stale plan as
  # if it were today's.
  # Pointless where we already read the operator's own site: nothing is
  # fresher than the source, and the aggregator's pickup time is a few
  # minutes later by definition, which would fire the warning forever.
  mine = OPERATOR_POSTS.key?(REGION) ? nil : published_at(data)
  theirs = mine && fetch_revision(REGIONS.dig(REGION, 4))
  if theirs && mine && theirs > mine
    puts "Оператор оновив графік о #{theirs.strftime('%H:%M')} — у нас ще старий | size=11 color=orange"
    site = REGIONS.dig(REGION, 3)
    puts "Перевірити в обленерго | size=11 color=gray#{" href=#{site}" if site}"
  end

  if hit
    puts 'Укренерго: у твоїй області нові знеструмлення після обстрілів | size=11 color=orange'
    puts 'Ремонтні роботи тривають — графік може не діяти | size=11 color=gray'
  elsif blind
    puts 'Аварійні відключення не перевіряються | size=11 color=orange'
  end

  render_alert(alert)

  if (news = grid)
    body = news['text'].to_s
    puts '---'
    puts "📰 #{safe(body.lines.first)} | size=12 color=gray"
    rest = safe(body.lines.drop(1).join(' '))
    unless rest.empty?
      puts "#{rest[0, 150]}#{'…' if rest.length > 150} | size=11 color=gray length=90"
    end
    link = news_url(news['link'])
    puts "Читати в Укренерго | size=11 color=gray href=#{link}" if link
  end

  puts '---'
  label = if unknown then "Останній графік · #{day_date.strftime('%d.%m')}"
          elsif stale then day_date.strftime('%d.%m.%Y')
          else 'Сьогодні'
          end
  puts "#{label} | size=12 color=gray"
  puts '● Відключень немає | color=green size=13 font=Menlo' if today.all?
  segments(today).each do |from, to, lit|
    next if today.all?

    here = !stale && (from..(to - 1)).cover?(now.hour) ? '  ←' : ''
    puts format('%s  %02d:00 – %02d:00%s | color=%s font=Menlo size=13',
                lit ? '●' : '○', from, to, here, lit ? 'green' : 'red')
  end

  puts '---'
  puts 'Завтра | size=12 color=gray'

  if tomorrow.nil?
    puts 'Графіка ще немає | size=13 color=gray'
    puts 'Зазвичай публікують увечері напередодні | size=11 color=gray'
  elsif tomorrow.all?
    puts '● Відключень немає | color=green size=13 font=Menlo'
  else
    segments(tomorrow).each do |from, to, lit|
      puts format('%s  %02d:00 – %02d:00 | color=%s font=Menlo size=13',
                  lit ? '●' : '○', from, to, lit ? 'green' : 'red')
    end
  end

  # ── Settings ────────────────────────────────────────────────────────

  puts '---'
  updated = fmt_updated(data.dig('fact', 'update') || data['lastUpdated'])
  mark = { cache: '', fresh: '', stale: '  (без мережі)' }[status]
  ago = age_phrase(published_at(data))
  puts "Оновлено: #{updated}#{" · #{ago}" if ago}#{mark} | size=11 color=gray"

  settings_menu((raw_days&.dig(today_key) || {}).keys)
rescue Errno::EPIPE
  # The reader closed the pipe (`| head`, say) — not an error
  exit 0
rescue StandardError => e
  puts '❌'
  puts '---'
  puts 'Несподівана помилка | color=red size=13'
  puts "#{e.class}: #{e.message.to_s.delete('|')[0, 120]} | size=11 color=gray"
  puts 'Оновити | refresh=true size=11'
end

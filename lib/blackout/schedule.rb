# frozen_string_literal: true

# Hour values the source documents (preset.time_type). The 'maybe*' ones
# do not appear in current data but belong to the format: without them
# the validator would reject an otherwise valid file.
HOUR_VALUES = %w[yes no first second maybe mfirst msecond].freeze

# Until a region's real queues are known, offer the usual six by two.
DEFAULT_GROUPS = (1..6).flat_map { |q| (1..2).map { |sub| "GPV#{q}.#{sub}" } }.freeze

# The data comes from someone else's repository. Accept only what we
# understand: saying "unknown" beats showing garbage as a schedule.
def valid_schedule?(doc)
  return false unless doc.is_a?(Hash)

  days = doc.dig('fact', 'data')
  return true if days.nil? || (days.respond_to?(:empty?) && days.empty?)
  return false unless days.is_a?(Hash)

  days.all? do |day, groups|
    next false unless day.to_s.match?(/\A\d{9,11}\z/) && groups.is_a?(Hash)

    groups.all? do |name, hours|
      name.match?(/\AGPV\d{1,3}\.\d{1,2}\z/) &&
        hours.is_a?(Hash) &&
        hours.keys.all? { |h| (1..24).cover?(h.to_i) } &&
        hours.values.all? { |v| HOUR_VALUES.include?(v) }
    end
  end
end

# The schema used to be checked on write only, and the cache was handed
# back as-is. A queue name from there lands in a menu item's parameters,
# so a tampered cache could slip in its own bash=. Check on read too.
def read_schedule(path)
  doc = read_cache(path)
  doc if valid_schedule?(doc)
end

# Accept a row only when its queue has the expected shape: the GPV… key
# is built from it and later becomes a parameter value
def valid_rows?(rows)
  rows.is_a?(Array) &&
    rows.all? { |r| r.is_a?(Hash) && r['queue'].to_s.match?(/\A\d{1,3}\.\d{1,2}\z/) }
end

# Reshape primary-source rows into the mirror's format, so the rest of
# the code never has to know where the data came from.
def as_schedule(rows)
  # One queue can have several suppliers with different schedules — the
  # regional utility and, say, the railway. Take the utility: it covers
  # the overwhelming majority of consumers.
  rows = rows.group_by { |r| r['queue'] }.map do |_, same|
    same.find { |r| r['initiator'].to_s.include?('oblenergo') } || same.first
  end

  days = {}
  update = nil

  %w[today tomorrow].each do |slot|
    date = rows.map { |r| r["#{slot}Date"] }.compact.first
    next unless date

    ts = Date.parse(date).to_time.to_i
    group = {}
    rows.each do |r|
      hrs = r[slot]
      next unless hrs.is_a?(Array) && hrs.size == 24

      maybe = r["#{slot}Possible"]
      maybe = [] unless maybe.is_a?(Array)
      group["GPV#{r['queue']}"] = (0..23).to_h do |i|
        v = if hrs[i].to_i == 1 then 'no'
            elsif maybe[i].to_i == 1 then 'maybe'
            else 'yes'
            end
        [(i + 1).to_s, v]
      end
    end
    # NoShutdowns: empty hours mean power all day, not missing data
    if group.empty? && rows.any? { |r| r["#{slot}Status"] == 'NoShutdowns' }
      rows.each { |r| group["GPV#{r['queue']}"] = (1..24).to_h { |h| [h.to_s, 'yes'] } }
    end
    days[ts.to_s] = group unless group.empty?
    # updated is when the schedule was published; todayCheckedAt is only
    # when we re-polled it, which is always recent and so says nothing.
    update ||= rows.map { |r| r['updated'] }.compact.max
  end

  return nil if days.empty?

  today_ts = rows.map { |r| r['todayDate'] }.compact.first
  { 'lastUpdated' => update,
    'fact' => { 'data' => days,
                'update' => update,
                'today' => today_ts ? Date.parse(today_ts).to_time.to_i : days.keys.min.to_i } }
end

# When the schedule was published. The primary source sends ISO, the
# mirrors send "18.10.2026 10:01" in Kyiv time.
def published_at(doc)
  v = doc && (doc.dig('fact', 'update') || doc['lastUpdated'])
  return nil unless v

  v.to_s.match?(/\A\d{2}\.\d{2}\.\d{4}/) ? Time.strptime(v.to_s, '%d.%m.%Y %H:%M') : Time.parse(v.to_s)
rescue StandardError
  nil
end

# One queue's row in the shape the rest of the code expects. In the
# source 1 means an outage, so invert it: here true means power is on.
def schedule_from(rows, queue)
  num = queue.sub('GPV', '')
  row = rows.find { |r| r['queue'] == num && r['initiator'].to_s.include?('oblenergo') } ||
        rows.find { |r| r['queue'] == num }
  return nil unless row

  hours = lambda do |key|
    a = row[key]
    a.is_a?(Array) && a.size == 24 ? a.map { |v| v.to_i.zero? } : nil
  end

  { today: hours.call('today'), tomorrow: hours.call('tomorrow'),
    today_status: row['todayStatus'], tomorrow_status: row['tomorrowStatus'],
    date: row['todayDate'], checked: row['todayCheckedAt'] }
end

# Hour N in the source is the interval [N-1, N)
def hours_for(data, queue, day_key)
  raw = data.dig('fact', 'data', day_key, queue)
  return nil unless raw

  # Power is on only for 'yes'. Everything else is an outage — full,
  # partial or possible — and all of those count as "no power", because
  # erring in that direction is the safer mistake.
  (1..24).map { |h| raw[h.to_s] == 'yes' }
end

def segments(hours)
  hours.each_with_index.chunk_while { |(a, _), (b, _)| a == b }
       .map { |chunk| [chunk.first[1], chunk.last[1] + 1, chunk.first[0]] }
end

def minutes_until_change(today, tomorrow, now)
  idx = now.hour
  state = today[idx]
  elapsed = (now.hour * 60) + now.min

  ((idx + 1)..23).each { |h| return (h * 60) - elapsed if today[h] != state }
  return nil unless tomorrow

  (0..23).each do |h|
    return ((24 * 60) - elapsed) + (h * 60) if tomorrow[h] != state
  end
  nil
end

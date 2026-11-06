# frozen_string_literal: true

# Hour values the source documents (preset.time_type). The 'maybe*' ones
# do not appear in current data but belong to the format: without them
# the validator would reject an otherwise valid file.
HOUR_VALUES = %w[yes no first second maybe mfirst msecond].freeze

# What each value means for the two halves of its hour, as
# [first half lit, second half lit]. 'first' is an outage in the first
# thirty minutes only. Possible outages count as no power: erring in
# that direction is the safer mistake.
HALVES = {
  'yes' => [true, true], 'no' => [false, false], 'maybe' => [false, false],
  'first' => [false, true], 'mfirst' => [false, true],
  'second' => [true, false], 'msecond' => [true, false]
}.freeze

# The schedule is kept in half hours: a queue lit from 11:00 to 12:30 was
# shown as 11:00 – 12:00, because a half-dark hour counted as dark whole.
SLOT_MINUTES = 30

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
      # 2 and 3 are half-hour outages: matched against the mirrors on
      # the same day, 2 ends a block half an hour in, 3 starts one at :30
      group["GPV#{r['queue']}"] = (0..23).to_h do |i|
        v = case hrs[i].to_i
            when 1 then 'no'
            when 2 then 'first'
            when 3 then 'second'
            else maybe[i].to_i == 1 ? 'maybe' : 'yes'
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

# Hour N in the source is the interval [N-1, N). The result has one
# entry per half hour: index i is [i * 30 min, (i + 1) * 30 min).
# A missing or unknown hour counts as no power, like a partial one.
def slots_for(data, queue, day_key)
  raw = data.dig('fact', 'data', day_key, queue)
  return nil unless raw

  (1..24).flat_map { |h| HALVES.fetch(raw[h.to_s], [false, false]) }
end

# The half hour that `time` falls into
def slot_of(time)
  ((time.hour * 60) + time.min) / SLOT_MINUTES
end

# Slot boundary as a clock time; slot 48 is the end of the day, 24:00
def slot_time(slot)
  format('%02d:%02d', slot * SLOT_MINUTES / 60, slot * SLOT_MINUTES % 60)
end

def segments(slots)
  slots.each_with_index.chunk_while { |(a, _), (b, _)| a == b }
       .map { |chunk| [chunk.first[1], chunk.last[1] + 1, chunk.first[0]] }
end

def minutes_until_change(today, tomorrow, now)
  idx = slot_of(now)
  state = today[idx]
  elapsed = (now.hour * 60) + now.min

  ((idx + 1)...today.size).each { |s| return (s * SLOT_MINUTES) - elapsed if today[s] != state }
  return nil unless tomorrow

  tomorrow.each_with_index do |lit, s|
    return ((24 * 60) - elapsed) + (s * SLOT_MINUTES) if lit != state
  end
  nil
end

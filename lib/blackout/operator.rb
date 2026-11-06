# frozen_string_literal: true

# Some operators publish their schedules through their own site API, in
# plain text. Reading those first-hand is the only way to see a revision
# made during the day: the community mirrors commit about twice a day,
# both times in the evening, so a schedule rewritten at ten in the
# morning does not reach them until night.

MONTHS = %w[січня лютого березня квітня травня червня липня серпня
            вересня жовтня листопада грудня].freeze

# "…(ГПВ) на 27 жовтня" → that date, with the year taken from today so
# the turn of a year does not read as ten months in the past.
def title_date(title, today = Date.today)
  m = title.to_s.match(/\sна\s+(\d{1,2})\s+(\p{L}+)/)
  return nil unless m

  month = MONTHS.index(m[2].downcase)
  return nil unless month

  d = Date.new(today.year, month + 1, m[1].to_i)
  if (d - today).to_i.abs > 180
    Date.new(today.year + (d < today ? 1 : -1), month + 1, m[1].to_i)
  else
    d
  end
rescue StandardError
  nil
end

# "1.1 12:00 - 14:30, 18:00 - 20:00" per line, one line per queue.
# Returns queue => the half hours it is off, as 1..48 where N means the
# half hour ending at N * 30 minutes. Minutes off the half-hour grid
# widen the outage rather than narrow it: the safer mistake.
def parse_outage_text(text)
  # Sites put a non-breaking space between the queue and its hours, and
  # \s does not match one. Normalise before matching.
  # A real post lists a dozen queues. Two megabytes of them — which the
  # response cap still allows — took over two seconds to walk, every
  # time the menu redrew.
  text.to_s.scrub('').tr("\u00A0\u2009\u202F", ' ')
      .each_line.first(500).each_with_object({}) do |line, acc|
    span = /\d{1,2}:\d{2}\s*[-–—]\s*\d{1,2}:\d{2}/
    m = line.match(/\A\s*(\d{1,2}\.\d{1,2})\s+(#{span}(?:\s*,\s*#{span})*)/)
    next unless m

    span_parts = /(\d{1,2}):(\d{2})\s*[-–—]\s*(\d{1,2}):(\d{2})/
    slots = m[2].scan(span_parts).flat_map do |fh, fm, th, tm|
      # A garbled line must cost its own interval, not the whole region:
      # out-of-range times would fail validation and void the document.
      next [] unless fm.to_i < 60 && tm.to_i < 60

      start = ((fh.to_i * 60) + fm.to_i) / SLOT_MINUTES
      finish = ((th.to_i * 60) + tm.to_i + SLOT_MINUTES - 1) / SLOT_MINUTES
      finish = 48 if finish.zero?
      next [] unless start.between?(0, 47) && finish.between?(1, 48) && finish > start

      ((start + 1)..finish).to_a
    end
    acc[m[1]] = slots.uniq.sort unless slots.empty?
  end
end

# The source format's word for an hour with these halves dark
def hour_value(first_off, second_off)
  if first_off && second_off then 'no'
  elsif first_off then 'first'
  elsif second_off then 'second'
  else 'yes'
  end
end

# The operator's text, reshaped into the document the rest of the code
# already understands, so nothing downstream needs to know the source.
def as_operator_schedule(days, published)
  data = days.map do |date, queues|
    next if queues.empty?

    groups = queues.to_h do |queue, off|
      hours = (1..24).to_h { |h| [h.to_s, hour_value(off.include?((2 * h) - 1), off.include?(2 * h))] }
      ["GPV#{queue}", hours]
    end
    [date.to_time.to_i.to_s, groups]
  end.compact.to_h
  return nil if data.empty?

  { 'lastUpdated' => published&.iso8601,
    'fact' => { 'data' => data,
                'update' => published&.strftime('%d.%m.%Y %H:%M'),
                'today' => Date.today.to_time.to_i } }
end
